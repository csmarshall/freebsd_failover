#!/usr/local/bin/bash
# Restore every file from a phase backup tarball. Runtime state (aliases,
# routes, dpinger) is not reverted automatically; the steps are printed.
unset TMOUT
set -euo pipefail
. "$(dirname "$0")/lib.sh"

usage() {
	cat <<EOF
Usage: $0 <backup.tgz> [--apply]
  lists what would be restored; --apply restores it (needs root)
EOF
}
[[ $# -ge 1 && -f $1 ]] || { usage >&2; exit 2; }
TGZ="$1"; shift
parse_mode "${1:-}"

hr "contents of $TGZ"
tar -tzvf "$TGZ"
if [[ $MODE != apply ]]; then
	say "dry run complete; re-run with --apply"
	exit 0
fi

tar -xzpf "$TGZ" -C /
# Files a later phase added that the backup does not contain.
for f in /etc/dhclient-scripts/wan-lib.sh /etc/dhclient-scripts/dhclient-ixl0-enter-hooks \
         /etc/dhclient-scripts/dhclient-ix0-enter-hooks; do
	if [[ -e $f ]] && ! tar -tzf "$TGZ" "${f#/}" >/dev/null 2>&1; then rm -v "$f"; fi
done
say "files restored from $TGZ"
cat <<EOF
Runtime steps NOT done automatically (only if you need the old behaviour back now):
  ifconfig ix0 inet 192.168.12.2/24 alias      # old static ix0 alias
  ifconfig ix0 inet6 -no_radr
  /etc/dpinger/start_dpinger.sh                 # old (non-functional) dpinger
FIBs: net.fibs cannot be lowered at runtime; extra empty FIBs are harmless.
EOF
