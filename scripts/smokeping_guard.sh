#!/usr/local/bin/bash
# Install the daily periodic(8) check that alerts when a `pkg upgrade
# smokeping` reverts smokeping_fixes.sh's version-compare patch (or any page
# render shows an rrdtool ERROR). It reports by daily mail and Pushover and
# never re-patches anything.
unset TMOUT
set -euo pipefail
. "$(dirname "$0")/lib.sh"

usage() {
	cat <<EOF
Usage: $0 [--apply]
  (no args)  dry run: show what would be installed; touches nothing
  --apply    back up, install the check, enable it, run it once (needs root)
EOF
}
parse_mode "${1:-}"

SRC="$REPO/router/usr/local/etc/periodic/daily/480.status-smokeping"
DST=/usr/local/etc/periodic/daily/480.status-smokeping
CONF=/etc/periodic.conf
ENABLE_LINE='daily_status_smokeping_enable="YES"'

hr "$DST"
sh -n "$SRC" || die "$SRC has a syntax error"
show_diff "$DST" "$SRC"

hr "$CONF"
if [[ -e $CONF ]] && (( $(/usr/bin/grep -cxF "$ENABLE_LINE" "$CONF" || true) > 0 )); then
	say "already enabled in $CONF"
	need_conf=0
else
	say "would append: $ENABLE_LINE"
	need_conf=1
fi

if [[ $MODE != apply ]]; then
	say "dry run complete; re-run with --apply"
	exit 0
fi

backup smokeping-guard
install -m 555 -o root -g wheel "$SRC" "$DST"
say "installed $DST"
if (( need_conf )); then
	printf '%s\n' "$ENABLE_LINE" >> "$CONF"
	say "enabled in $CONF"
fi

hr "run once"
rc=0
"$DST" || rc=$?
if (( rc == 0 )); then say "PASS check reports ok"; else say "FAIL check exited $rc (see above; a Pushover alert was sent)"; fi
say "Rollback: rm $DST and remove '$ENABLE_LINE' from $CONF"
