#!/usr/local/bin/bash
# Smokeping fixes found by the 2026-10-30 review:
#  1. Graphs: smokeping 2.9.0 decides whether to escape colons in rrdtool
#     COMMENTs with `$RRDs::VERSION >= 1.199908`. rrdtool 1.11.0's RRDs
#     reports 1.011, so smokeping thinks it's pre-1.2, doesn't escape, and
#     every graph fails ("Unused Arguments ... COMMENT:..."). Patch the four
#     comparisons to true. A `pkg upgrade smokeping` undoes this: re-run.
#  2. /var/log/smokeping.log (522 MB, never rotated): add a newsyslog entry
#     and rotate it once now (the old log is kept, compressed).
unset TMOUT
set -euo pipefail
. "$(dirname "$0")/lib.sh"

usage() {
	cat <<EOF
Usage: $0 [--apply]
  (no args)  dry run: show the patch and the newsyslog entry; touches nothing
  --apply    back up, patch, rotate, verify a graph renders (needs root)
EOF
}
parse_mode "${1:-}"

LIB=/usr/local/smokeping/lib
PATCH_FILES=("$LIB/Smokeping.pm" "$LIB/Smokeping/Graphs.pm")
OLD_TEST='$RRDs::VERSION >= 1.199908'
SED_EXPR='s/\$RRDs::VERSION >= 1\.199908/1/'
NEWSYSLOG=/etc/newsyslog.conf.d/smokeping.conf
NEWSYSLOG_LINE='/var/log/smokeping.log	www:www	644	7	10240	*	JC'
GRAPH_URL='https://router.example.com/smokeping/smokeping.fcgi?target=FPings.Network.Uplinks.Compare'
IMG_DIR=/usr/local/smokeping/htdocs/img

STAGE="$(mktemp -d -t smokepingfix)"
trap 'rm -rf "$STAGE"' EXIT

hr "patch"
total=0
for f in "${PATCH_FILES[@]}"; do
	n=$(/usr/bin/grep -cF "$OLD_TEST" "$f" || true)
	total=$((total + n))
	sed "$SED_EXPR" "$f" > "$STAGE/$(basename "$f")"
	show_diff "$f" "$STAGE/$(basename "$f")"
	[[ $(/usr/bin/grep -cF "$OLD_TEST" "$STAGE/$(basename "$f")" || true) -eq 0 ]] || die "sed left a comparison in $f"
done
if (( total == 0 )); then say "already patched (0 comparisons left)"; fi
perl -c -I"$STAGE" "$STAGE/Graphs.pm" >/dev/null 2>&1 || say "NOTE: standalone perl -c of Graphs.pm can't resolve its deps; checked after install instead"

hr "$NEWSYSLOG"
echo "$NEWSYSLOG_LINE"
ls -la /var/log/smokeping.log

if [[ $MODE != apply ]]; then
	say "dry run complete; re-run with --apply"
	exit 0
fi

mkdir -p "$BACKUP_DIR"
tar -czpf "$BACKUP_DIR/${TS}-smokeping-lib.tgz" -C / "${PATCH_FILES[@]#/}"
say "backup: $BACKUP_DIR/${TS}-smokeping-lib.tgz (restore: tar -xzpf it -C /)"
for f in "${PATCH_FILES[@]}"; do
	install -m "$(stat -f %Lp "$f")" -o "$(stat -f %Su "$f")" -g "$(stat -f %Sg "$f")" "$STAGE/$(basename "$f")" "$f"
	say "patched $f"
done
perl -I"$LIB" -c "$LIB/Smokeping.pm" || die "patched Smokeping.pm doesn't compile; restore the backup"

printf '%s\n' "$NEWSYSLOG_LINE" > "$NEWSYSLOG"
newsyslog -F /var/log/smokeping.log && say "rotated /var/log/smokeping.log"
ls -la /var/log/smokeping.log*
service smokeping restart
# The CGI is FastCGI (smokeping_cgi stays resident with the old code loaded):
# end it so mod_fcgid starts a fresh one on the next request.
pkill -f '/usr/local/bin/smokeping_cgi' && say "stopped resident smokeping_cgi (respawns on next request)" || true

hr "verify"
touch "$STAGE/before"
page="$(curl -sk -m 90 "$GRAPH_URL")"
errs=$(printf '%s\n' "$page" | /usr/bin/grep -c 'ERROR' || true)
new=$(find "$IMG_DIR" -name '*.png' -newer "$STAGE/before" | wc -l | tr -d ' ')
if (( errs == 0 )); then say "PASS Compare page has no rrdtool ERROR"; else say "FAIL Compare page still shows $errs ERROR line(s)"; fi
if (( new > 0 )); then say "PASS $new graph PNG(s) rendered just now"; else say "FAIL no new graph PNGs rendered"; fi
say "Look: $GRAPH_URL"
