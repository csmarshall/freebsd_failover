#!/usr/bin/env python3
"""Fail if a directory tree contains private network details.

Two layers:
  1. Deny-list from the private sanitise map (one home per fact: the
     export's substitutions and this scanner share it): every real value on
     the left of a substitution line (plain lines case-sensitively, "re:"
     lines as regexes), plus "!word" deny-only lines (case-insensitive,
     never substituted). Optional; the public repo's CI runs without it.
  2. Generic patterns, which catch values the map has never heard of:
     MAC addresses (colon, dash, Cisco-dot and zero-stripped forms) outside
     the documentation range; public IPv4 and global/unique-local IPv6
     outside documentation/private/special ranges and a short allow-list
     of public anycast resolvers; EUI-64 link-local addresses (they encode a
     MAC); home directories; e-mail addresses outside example.com.

Files the scanner can't read as UTF-8, that are too large, or that are
broken symlinks FAIL the scan rather than being skipped, so nothing passes
by not being looked at. `--self-test` checks the generic rules against
known-leaky and known-clean strings.

Usage: leak_scan.py [--map MAP] DIR [DIR ...]
       leak_scan.py --self-test
Exit 0 = clean, 1 = leaks found (each printed as path:line: reason), 2 = usage/error.
"""

from __future__ import annotations

import argparse
import ipaddress
import logging
import os
import re
import sys
from collections.abc import Iterator
from pathlib import Path

LOG = logging.getLogger("leak_scan")

# Public anycast resolvers / probe targets that are fine to name in public.
ALLOWED_PUBLIC_V4 = {
    "1.1.1.1", "1.0.0.1", "8.8.8.8", "8.8.4.4", "4.2.2.1", "4.2.2.2",
    "9.9.9.9", "9.9.9.10", "149.112.112.112", "208.67.222.222",
}
ALLOWED_PUBLIC_V6 = {
    "2001:4860:4860::8888", "2001:4860:4860::8844",
    "2606:4700:4700::1111", "2606:4700:4700::1001",
    "2620:fe::fe", "2620:fe::9",
}
# Protocol-defined prefixes named whole, as they appear in FreeBSD's stock
# address-selection table (6to4, Teredo, 6bone). Only the bare root is fine:
# an address inside one of them can embed a real IPv4 address.
WELLKNOWN_V6_ROOTS = {"2002::", "2001::", "3ffe::"}
DOC_V4 = [ipaddress.ip_network(n) for n in ("192.0.2.0/24", "198.51.100.0/24", "203.0.113.0/24")]
SPECIAL_V4 = [ipaddress.ip_network(n) for n in ("192.0.0.0/24", "0.0.0.0/8", "100.64.0.0/10")]
DOC_V6 = [ipaddress.ip_network(n) for n in ("2001:db8::/32", "3fff::/20")]  # RFC 3849, RFC 9637
ULA_V6 = ipaddress.ip_network("fc00::/7")
# Unique-local prefixes that are fine to publish: the documentation-style
# placeholder and the owner's house ULA (owner decision, 2026-10-31).
ALLOWED_ULA = [ipaddress.ip_network(n) for n in ("fd00:db8::/32", "fd00:1234:5678::/48")]
DOC_MAC_PREFIX = "00:00:5e:00:53:"

HEX = "0-9A-Fa-f"
# MACs: colon or dash pairs, Cisco dotted quads-of-hex, and FreeBSD arp's zero-stripped form.
MAC_RES = [
    re.compile(rf"(?<![{HEX}:-])[{HEX}]{{2}}([:-])(?:[{HEX}]{{2}}\1){{4}}[{HEX}]{{2}}(?![{HEX}:-])"),
    re.compile(rf"(?<![{HEX}.])[{HEX}]{{4}}\.[{HEX}]{{4}}\.[{HEX}]{{4}}(?![{HEX}.])"),
    re.compile(rf"(?<![{HEX}:])(?:[{HEX}]{{1,2}}:){{5}}[{HEX}]{{1,2}}(?![{HEX}:])"),
]
# IPv4: a trailing sentence period and a leading label or dot are allowed.
V4_RE = re.compile(r"(?<!\d)(?<!\d\.)(?:\d{1,3}\.){3}\d{1,3}(?!\d)(?!\.\d)")
# IPv6-ish runs of hex and colons (at least two colons); labels are stripped in v6_reason.
V6_RE = re.compile(rf"[{HEX}:]*:[{HEX}]*:[{HEX}:]*")
# Where a v6 address can start inside such a run: global (2/3xxx), ULA (fc/fd), link-local.
V6_START_RE = re.compile(r"(?:[23][0-9a-f]{3}|f[cd][0-9a-f]{2}|fe80):")
HOME_DIR_RE = re.compile(r"(?:/home/|/Users/|/usr/home/)(?!admin\b)[A-Za-z]|~(?!admin\b)[a-z][a-z0-9_-]*/")
EMAIL_RE = re.compile(
    r"[A-Za-z0-9._%+-]+@(?!example\.(?:com|net|org)\b)[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}")

SKIP_NAMES = {".git"}
MAX_BYTES = 2_000_000

DenyRules = tuple[list[str], list[re.Pattern[str]], re.Pattern[str] | None]
NO_RULES: DenyRules = ([], [], None)


def load_map(path: Path) -> DenyRules:
    """Return (plain real values longest first, regex reals, deny-only word pattern)."""
    plain: list[str] = []
    regex: list[re.Pattern[str]] = []
    words: list[str] = []
    for raw in path.read_text().splitlines():
        if not raw.strip() or raw.lstrip().startswith("#"):
            continue
        if raw.startswith("!"):
            words.append(re.escape(raw[1:].strip()))
            continue
        real, _, _public = raw.partition("\t")
        if real.startswith("re:"):
            regex.append(re.compile(real[3:]))
        elif real:
            plain.append(real)
    pattern = re.compile("|".join(words), re.I) if words else None
    return sorted(plain, key=len, reverse=True), regex, pattern


def v4_reason(token: str) -> str | None:
    """Return why an IPv4-looking token is private data, or None if it is fine."""
    octets = token.split(".")
    if any(len(o) > 1 and o.startswith("0") for o in octets):
        token = ".".join(str(int(o)) for o in octets)  # 024.013.x -> 24.13.x
    try:
        addr = ipaddress.IPv4Address(token)
    except ValueError:
        return None  # e.g. a version string like 999.1.2.3
    if token in ALLOWED_PUBLIC_V4 or token.startswith("255.") or addr.is_private or addr.is_loopback \
            or addr.is_multicast or addr.is_link_local or addr.is_reserved or addr.is_unspecified:
        return None
    if any(addr in n for n in DOC_V4 + SPECIAL_V4):
        return None
    return f"public IPv4 {token}"


def parse_v6(text: str) -> ipaddress.IPv6Address | None:
    """Parse an address, a prefix, or a partial prefix like 2001:db8:12:34."""
    core = text.split("%")[0].split("/")[0]
    stripped = core.rstrip(":")
    for candidate in (core, stripped + "::", stripped):
        try:
            return ipaddress.IPv6Address(candidate)
        except ValueError:
            continue
    groups = [g for g in stripped.split(":") if g]
    if not 2 <= len(groups) <= 8 or any(len(g) > 4 for g in groups):
        return None
    return ipaddress.IPv6Address(":".join(groups + ["0"] * (8 - len(groups))))


def v6_reason(token: str) -> str | None:
    """Return why an IPv6-looking token is private data, or None if it is fine."""
    low = token.lower()
    start = V6_START_RE.search(low)
    if not start:
        return None
    low = low[start.start():]  # drop label prefixes like "ip6:", "via:", "gua"
    if low.rstrip(":") in ALLOWED_PUBLIC_V6 or low in ALLOWED_PUBLIC_V6:
        return None
    if low.split("/")[0] in WELLKNOWN_V6_ROOTS:
        return None
    addr = parse_v6(low)
    if addr is None:
        return None
    groups = addr.exploded.split(":")
    if low.startswith("fe80"):
        eui64 = groups[5].endswith("ff") and groups[6].startswith("fe")
        doc_mac = groups[4:7] == ["0200", "5eff", "fe00"] and groups[7].startswith("53")
        return f"EUI-64 link-local (encodes a MAC) {token}" if eui64 and not doc_mac else None
    if any(addr in n for n in DOC_V6):
        return None
    if addr in ULA_V6:
        generic = not any(addr.packed[2:])  # "fc00::/7", "fd00::/8": the range itself
        allowed = generic or any(addr in n for n in ALLOWED_ULA)
        return None if allowed else f"unique-local IPv6 {token}"
    return f"global IPv6 {token}"


def scan_text(text: str, rules: DenyRules) -> list[tuple[int, str]]:
    """Return (line number, reason) for every leak in text."""
    plain, regex, words = rules
    hits: list[tuple[int, str]] = []
    for lineno, line in enumerate(text.splitlines(), 1):
        hits += [(lineno, f"private value from map: {real}") for real in plain if real in line]
        hits += [(lineno, f"private pattern from map: {p.pattern}") for p in regex if p.search(line)]
        if words:
            hits += [(lineno, f"private word from map: {m.group(0)}") for m in words.finditer(line)]
        hits += [(lineno, f"home directory {m.group(0)}") for m in HOME_DIR_RE.finditer(line)]
        hits += [(lineno, f"e-mail address {m.group(0)}") for m in EMAIL_RE.finditer(line)]
        for mac_re in MAC_RES:
            for m in mac_re.finditer(line):
                octets = re.split(r"[:.-]", m.group(0).lower())
                if len(octets) == 3:  # Cisco dotted form
                    octets = [o[i:i + 2] for o in octets for i in (0, 2)]
                mac = ":".join(o.zfill(2) for o in octets)
                if not mac.startswith(DOC_MAC_PREFIX) and mac != "00:00:00:00:00:00":
                    hits.append((lineno, f"MAC address {m.group(0)}"))
        hits += [(lineno, r) for m in V4_RE.finditer(line) if (r := v4_reason(m.group(0)))]
        hits += [(lineno, r) for m in V6_RE.finditer(line) if (r := v6_reason(m.group(0)))]
    return hits


def iter_files(root: Path) -> Iterator[Path]:
    """Yield every file under root, skipping .git (a dir, or a worktree's pointer file)."""
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d not in SKIP_NAMES]
        for name in filenames:
            if name not in SKIP_NAMES:
                yield Path(dirpath) / name


def scan_tree(root: Path, rules: DenyRules) -> int:
    """Print every leak under root; return how many (unscannable files count as leaks)."""
    leaks = 0
    for path in iter_files(root):
        for _lineno, reason in scan_text(str(path.relative_to(root)), rules):
            print(f"{path}: (path) {reason}")
            leaks += 1
        if not path.exists():
            print(f"{path}: broken symlink (can't be scanned)")
            leaks += 1
            continue
        if path.stat().st_size > MAX_BYTES:
            print(f"{path}: larger than {MAX_BYTES} bytes (can't be scanned; don't ship it)")
            leaks += 1
            continue
        try:
            text = path.read_text(errors="strict")
        except UnicodeDecodeError:
            print(f"{path}: not UTF-8 text (can't be scanned; don't ship it)")
            leaks += 1
            continue
        for lineno, reason in scan_text(text, rules):
            print(f"{path}:{lineno}: {reason}")
            leaks += 1
    return leaks


# Synthetic values only (never a real one), each split so this file doesn't
# trip its own scan: "a" "b" is the same string as "ab" to Python.
MUST_FLAG = [
    "wan 8.20" ".247.5", "gateway 8.20" ".247.5.", "wan.8.20" ".247.5", "008.020" ".247.005",
    "2600:12" "34:abcd:1::1", "ip6:26" "00:1234:abcd:1::1", "via:26" "07:abcd:1:2::1",
    "gua2600:12" "34:abcd:1::1", "prefix 2600:12" "34:abcd:12", "fd12:3456" ":789a::1",
    "fe80::a2b:c3" "ff:fed4:e5f6%ix0", "3a:5b:7c" ":1d:2e:4f", "3a-5b-7c" "-1d-2e-4f",
    "3a5b.7c1d" ".2e4f", "0:25:90" ":a:b:c", "/home/" "bob/x", "/Users/" "bob/work", "~" "bob/bin",
    "mail ops" "@realdomain.net",
    "2002:c6" "33:6401::1", "2001:0" ":53aa:64c::1", "3ffe:12" "34::1",
]
MUST_PASS = [
    "203.0.113.32", "198.51.100.1 192.0.2.50", "1.1.1.1 8.8.8.8", "192.168.100.10",
    "192.0.0.2/27", "255.255.255.0", "2001:db8:5130::/60", "2001:4860:4860::8888",
    "fd00:1234:5678:1::1", "fd00:db8:1::/48", "fe80::200:5eff:fe00:5301%ix0", "fe80::1:2%ix0",
    "00:00:5e:00:53:01", "admin@example.com", "/home/admin", "~admin/bin", "time 18:53:05",
    "s/::/x/", "ff02::2", "version 15.1.0", "a::b", "TMOUT", "${foo:-bar}", "fc00::/7", "fd00::/8",
    "2002::/16", "2001::/32", "3ffe::/16",
]


def self_test() -> int:
    """Every MUST_FLAG string must be flagged and every MUST_PASS string must not."""
    missed = [s for s in MUST_FLAG if not scan_text(s, NO_RULES)]
    false_pos = [s for s in MUST_PASS if scan_text(s, NO_RULES)]
    for s in missed:
        print(f"self-test: MISSED {s!r}")
    for s in false_pos:
        print(f"self-test: FALSE POSITIVE {s!r}: {scan_text(s, NO_RULES)}")
    print(f"self-test: {len(MUST_FLAG)} must-flag, {len(MUST_PASS)} must-pass, "
          f"{len(missed) + len(false_pos)} wrong")
    return 1 if missed or false_pos else 0


def main(argv: list[str]) -> int:
    """Scan the given trees (or run the self-test); return the exit status."""
    parser = argparse.ArgumentParser(description=(__doc__ or "").splitlines()[0])
    parser.add_argument("--map", type=Path, help="sanitise map whose real values are denied")
    parser.add_argument("--self-test", action="store_true", help="check the detector against known inputs")
    parser.add_argument("dirs", nargs="*", type=Path)
    args = parser.parse_args(argv)
    logging.basicConfig(level=os.environ.get("LEAK_SCAN_LOG", "WARNING"),
                        format="%(asctime)s %(levelname)s %(name)s: %(message)s")
    if args.self_test:
        return self_test()
    if not args.dirs:
        parser.error("give at least one DIR, or --self-test")
    rules = load_map(args.map) if args.map else NO_RULES
    LOG.info("deny-list: %d plain, %d regex", len(rules[0]), len(rules[1]))
    leaks = 0
    for root in args.dirs:
        if not root.is_dir():
            LOG.error("not a directory: %s", root)
            return 2
        leaks += scan_tree(root, rules)
    if leaks:
        print(f"leak_scan: {leaks} leak(s) found", file=sys.stderr)
        return 1
    LOG.info("clean")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
