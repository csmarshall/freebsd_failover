#!/usr/bin/env python3
"""Fail if a directory tree contains private network details.

Two layers:
  1. Deny-list from the private sanitise map (one home per fact: the
     export's substitutions and this scanner share it): every real value
     on the left of a substitution line (case-sensitive), plus "!word"
     deny-only lines (case-insensitive, never substituted). Optional; the
     public repo's CI runs without the map.
  2. Generic patterns, which catch values the map has never heard of:
     MAC addresses outside the documentation range, public IPv4/IPv6
     addresses outside documentation/private/special ranges and a short
     allow-list of public anycast resolvers, and home directories.

Usage: leak_scan.py [--map private/sanitise.map] DIR [DIR ...]
Exit 0 = clean, 1 = leaks found (each printed as path:line: reason), 2 = usage.
"""

from __future__ import annotations

import argparse
import ipaddress
import logging
import os
import re
import sys
from pathlib import Path

LOG = logging.getLogger("leak_scan")

# Public anycast resolvers / probe targets that are fine to name in public.
ALLOWED_PUBLIC_V4 = {
    "1.1.1.1", "1.0.0.1", "8.8.8.8", "8.8.4.4", "4.2.2.1",
    "9.9.9.9", "9.9.9.10", "149.112.112.112", "208.67.222.222",
}
ALLOWED_PUBLIC_V6 = {
    "2001:4860:4860::8888", "2001:4860:4860::8844",
    "2606:4700:4700::1111", "2606:4700:4700::1001",
    "2620:fe::fe", "2620:fe::9",
}
# Provider-wide allocations named in code/docs (not anyone's own prefix).
ALLOWED_V6_PREFIX_TOKENS = {"2600:1700:", "2607:fb90::"}

DOC_V4 = [ipaddress.ip_network(n) for n in ("192.0.2.0/24", "198.51.100.0/24", "203.0.113.0/24")]
SPECIAL_V4 = [ipaddress.ip_network(n) for n in ("192.0.0.0/24", "0.0.0.0/8", "100.64.0.0/10")]
DOC_V6 = ipaddress.ip_network("2001:db8::/32")
DOC_MAC_PREFIX = "00:00:5e:00:53:"

HOME_DIR_RE = re.compile(r"/home/(?!admin\b)[a-z]")
MAC_RE = re.compile(r"(?<![0-9a-f:])(?:[0-9a-f]{2}:){5}[0-9a-f]{2}(?![0-9a-f:])", re.I)
V4_RE = re.compile(r"(?<![\d.])(?:\d{1,3}\.){3}\d{1,3}(?![\d.])")
# Candidate IPv6 tokens: hex groups with at least two colons.
V6_RE = re.compile(r"(?<![0-9a-f:])[0-9a-f]{0,4}(?::[0-9a-f]{0,4}){2,7}(?![0-9a-f:])", re.I)

SKIP_DIRS = {".git"}
MAX_BYTES = 2_000_000


def load_map(path: Path) -> tuple[list[str], re.Pattern[str] | None]:
    """Return (substituted real values longest first, deny-only word pattern)."""
    reals: list[str] = []
    words: list[str] = []
    for raw in path.read_text().splitlines():
        if not raw.strip() or raw.lstrip().startswith("#"):
            continue
        if raw.startswith("!"):
            words.append(re.escape(raw[1:].strip()))
            continue
        real, _, _public = raw.partition("\t")
        if real:
            reals.append(real)
    pattern = re.compile("|".join(words), re.I) if words else None
    return sorted(reals, key=len, reverse=True), pattern


def v4_reason(token: str) -> str | None:
    """Return why an IPv4-looking token is private data, or None if it is fine."""
    try:
        addr = ipaddress.IPv4Address(token)
    except ValueError:
        return None  # e.g. a version string like 999.1.2.3
    if token in ALLOWED_PUBLIC_V4 or addr.is_private or addr.is_loopback or addr.is_multicast \
            or addr.is_link_local or addr.is_reserved or addr.is_unspecified:
        return None
    if any(addr in n for n in DOC_V4 + SPECIAL_V4):
        return None
    if token.startswith("255."):
        return None  # netmask
    return f"public IPv4 {token}"


def v6_reason(token: str) -> str | None:
    """Return why an IPv6-looking token is private data, or None if it is fine."""
    low = token.lower()
    if low in ALLOWED_V6_PREFIX_TOKENS or low in ALLOWED_PUBLIC_V6:
        return None
    if not re.match(r"[23][0-9a-f]{3}:", low):
        return None  # only global-unicast-looking tokens matter
    probe = low.rstrip(":")
    for candidate in (low, probe + "::", probe):
        try:
            addr = ipaddress.IPv6Address(candidate)
            break
        except ValueError:
            continue
    else:
        # Partial prefix like "2001:db8:5130:": judge by its leading groups.
        groups = probe.split(":")
        try:
            addr = ipaddress.IPv6Address(":".join(groups[:4] + ["0"] * (8 - len(groups[:4]))))
        except ValueError:
            return None
    if addr in DOC_V6:
        return None
    return f"global IPv6 {token}"


def scan_text(text: str, deny: list[str], words: re.Pattern[str] | None) -> list[tuple[int, str]]:
    """Return (line number, reason) for every leak in text."""
    hits: list[tuple[int, str]] = []
    for lineno, line in enumerate(text.splitlines(), 1):
        for real in deny:
            if real in line:
                hits.append((lineno, f"private value from map: {real}"))
        if words:
            for m in words.finditer(line):
                hits.append((lineno, f"private word from map: {m.group(0)}"))
        for m in HOME_DIR_RE.finditer(line):
            hits.append((lineno, f"home directory {m.group(0)}"))
        for m in MAC_RE.finditer(line):
            if not m.group(0).lower().startswith(DOC_MAC_PREFIX):
                hits.append((lineno, f"MAC address {m.group(0)}"))
        for m in V4_RE.finditer(line):
            reason = v4_reason(m.group(0))
            if reason:
                hits.append((lineno, reason))
        for m in V6_RE.finditer(line):
            reason = v6_reason(m.group(0))
            if reason:
                hits.append((lineno, reason))
    return hits


def iter_files(root: Path):
    """Yield every regular file under root, skipping .git."""
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
        for name in filenames:
            if name in SKIP_DIRS:
                continue  # a worktree's .git is a pointer file, not a dir
            yield Path(dirpath) / name


def main(argv: list[str]) -> int:
    """Scan the given trees; print leaks; return the exit status."""
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--map", type=Path, help="sanitise map whose real values are denied")
    parser.add_argument("dirs", nargs="+", type=Path)
    args = parser.parse_args(argv)
    logging.basicConfig(level=os.environ.get("LEAK_SCAN_LOG", "WARNING"),
                        format="%(asctime)s %(levelname)s %(name)s: %(message)s")

    deny, words = load_map(args.map) if args.map else ([], None)
    LOG.info("deny-list has %d values", len(deny))
    leaks = 0
    for root in args.dirs:
        if not root.is_dir():
            LOG.error("not a directory: %s", root)
            return 2
        for path in iter_files(root):
            # Path names leak too (e.g. a file called router-notes.md).
            for _lineno, reason in scan_text(str(path.relative_to(root)), deny, words):
                print(f"{path}: (path) {reason}")
                leaks += 1
            if path.stat().st_size > MAX_BYTES:
                LOG.warning("skipping large file %s", path)
                continue
            try:
                text = path.read_text(errors="strict")
            except UnicodeDecodeError:
                LOG.info("skipping binary %s", path)
                continue
            for lineno, reason in scan_text(text, deny, words):
                print(f"{path}:{lineno}: {reason}")
                leaks += 1
    if leaks:
        print(f"leak_scan: {leaks} leak(s) found", file=sys.stderr)
        return 1
    LOG.info("clean")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
