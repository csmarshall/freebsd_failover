#!/usr/bin/env python3
"""Export a sanitised copy of this project into the public repo checkout.

This project dir is the private, deployable source (the phase scripts
install router/ verbatim, so it holds real addresses). The public repo gets:

  router/            -> router/      (the files installed on the router)
  scripts/, tests/  -> scripts/, tests/
  PLAN.md           -> docs/DESIGN.md
  public/           -> repo root    (README, CLAUDE.md, CI, .gitignore)
  smokeping config  -> examples/smokeping-uplinks.conf (probes + Uplinks only;
                       the full config has private targets)

Every text file is passed through private/sanitise.map (real -> public,
longest first). Then the leak scanner must pass on the result and both test
suites must pass inside it; otherwise the export is reported as failed.

Usage: export_public.py DEST     (DEST: a checkout/worktree of the public repo)
"""

from __future__ import annotations

import logging
import os
import shutil
import subprocess
import sys
from pathlib import Path

PROJECT = Path(__file__).resolve().parent.parent
MAP = PROJECT / "private" / "sanitise.map"
SMOKEPING_CONF = PROJECT / "router" / "usr" / "local" / "etc" / "smokeping" / "config"
LOG = logging.getLogger("export_public")

# (source relative to PROJECT, destination relative to DEST)
TREES = [("router", "router"), ("scripts", "scripts"), ("tests", "tests"), ("public", ".")]
FILES = [("PLAN.md", "docs/DESIGN.md")]
# Never exported, wherever they sit inside an exported tree.
EXCLUDE_NAMES = {"__pycache__", ".DS_Store"}
EXCLUDE_REL = {"router/usr/local/etc/smokeping/config"}
# Paths in DEST this export owns (removed and rewritten every run).
OWNED = ["router", "scripts", "tests", "docs/DESIGN.md", "examples/smokeping-uplinks.conf"]


def load_map() -> list[tuple[str, str]]:
    """Return (real, public) pairs from the sanitise map, longest real first."""
    pairs = []
    for raw in MAP.read_text().splitlines():
        if not raw.strip() or raw.lstrip().startswith("#") or raw.startswith("!"):
            continue  # "!word" lines are deny-only (leak_scan.py), never substituted
        real, sep, public = raw.partition("\t")
        if not sep:
            raise ValueError(f"{MAP}: line without a TAB: {raw!r}")
        pairs.append((real, public))
    return sorted(pairs, key=lambda p: len(p[0]), reverse=True)


def sanitise(text: str, pairs: list[tuple[str, str]]) -> str:
    """Apply every substitution, longest real value first, as plain strings."""
    for real, public in pairs:
        text = text.replace(real, public)
    return text


def copy_file(src: Path, dst: Path, pairs: list[tuple[str, str]]) -> None:
    """Copy one file, sanitising text and keeping the mode bits."""
    dst.parent.mkdir(parents=True, exist_ok=True)
    try:
        text = src.read_text(errors="strict")
    except UnicodeDecodeError:
        shutil.copyfile(src, dst)
    else:
        dst.write_text(sanitise(text, pairs))
    shutil.copymode(src, dst)
    LOG.debug("copied %s -> %s", src, dst)


def smokeping_example() -> str:
    """Return the public part of the smokeping config: probes and the Uplinks tree."""
    lines = SMOKEPING_CONF.read_text().splitlines()

    def section(start: str, stop: str) -> list[str]:
        i = next(n for n, line in enumerate(lines) if line.strip() == start)
        j = next(n for n in range(i + 1, len(lines)) if lines[n].strip() == stop)
        return lines[i:j]

    probes = section("+ FPing", "+Curl")
    uplinks = section("+++ Uplinks", "+++ Family")
    header = [
        "# Excerpt of a working smokeping config: per-uplink probes and targets.",
        "# Merge into your own config. FPingDefault replaces plain FPing for your",
        "# existing targets (a probe with instances can't be used directly).",
        "# The Uplinks tree sits under '+ FPings' / '++ Network' in the original.",
        "",
        "*** Probes ***",
        "",
    ]
    return "\n".join(header + probes + ["", "*** Targets ***", "", "# ... + FPings / ++ Network ..."] + uplinks) + "\n"


def export(dest: Path) -> None:
    """Rewrite the owned paths in dest from this project, sanitised."""
    pairs = load_map()
    for rel in OWNED:
        target = dest / rel
        if target.is_dir():
            shutil.rmtree(target)
        elif target.exists():
            target.unlink()
    count = 0
    for src_rel, dst_rel in TREES:
        src_root = PROJECT / src_rel
        for dirpath, dirnames, filenames in os.walk(src_root):
            dirnames[:] = [d for d in dirnames if d not in EXCLUDE_NAMES]
            for name in filenames:
                src = Path(dirpath) / name
                rel = src.relative_to(PROJECT).as_posix()
                if name in EXCLUDE_NAMES or rel in EXCLUDE_REL:
                    continue
                copy_file(src, dest / dst_rel / src.relative_to(src_root), pairs)
                count += 1
    for src_rel, dst_rel in FILES:
        copy_file(PROJECT / src_rel, dest / dst_rel, pairs)
        count += 1
    example = dest / "examples" / "smokeping-uplinks.conf"
    example.parent.mkdir(parents=True, exist_ok=True)
    example.write_text(sanitise(smokeping_example(), pairs))
    LOG.info("exported %d files + smokeping example into %s", count + 1, dest)


def verify(dest: Path) -> bool:
    """Leak scan and both test suites must pass inside the exported tree."""
    ok = True
    scan = subprocess.run([sys.executable, str(PROJECT / "scripts" / "leak_scan.py"),
                           "--map", str(MAP), str(dest)])
    if scan.returncode != 0:
        LOG.error("leak scan FAILED on the export")
        ok = False
    for suite in ("tests/test_hooks.sh", "tests/test_failover.sh"):
        run = subprocess.run(["sh", str(dest / suite)], capture_output=True, text=True)
        tail = run.stdout.strip().splitlines()[-1:] or ["(no output)"]
        if run.returncode != 0:
            LOG.error("%s FAILED in the export: %s", suite, tail[0])
            print(run.stdout[-3000:], file=sys.stderr)
            ok = False
        else:
            LOG.info("%s passed in the export: %s", suite, tail[0])
    return ok


def main(argv: list[str]) -> int:
    """Export into DEST and verify; return the exit status."""
    logging.basicConfig(level=os.environ.get("EXPORT_LOG", "INFO"),
                        format="%(asctime)s %(levelname)s %(name)s: %(message)s")
    if len(argv) != 1:
        print(__doc__, file=sys.stderr)
        return 2
    dest = Path(argv[0]).resolve()
    if not (dest / ".git").exists():
        LOG.error("%s is not a git checkout/worktree of the public repo", dest)
        return 2
    if dest == PROJECT or PROJECT in dest.parents:
        LOG.error("refusing to export into the private project itself")
        return 2
    export(dest)
    if not verify(dest):
        LOG.error("export NOT clean; do not commit")
        return 1
    LOG.info("export clean")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
