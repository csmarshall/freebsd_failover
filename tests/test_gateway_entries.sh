#!/bin/sh
# Unprivileged tests for set_gateway_entries.sh against a scratch hosts file:
# every name updated in one atomic replace, unrelated lines untouched, no
# write when nothing changes, and the old file intact when the update fails.
#
# Usage: tests/test_gateway_entries.sh [script-path]
unset TMOUT
set -u

REPO=$(cd "$(dirname "$0")/.." && pwd)
SGE=${1:-$REPO/router/etc/dhclient-scripts/set_gateway_entries.sh}
fails=0
passes=0
ok()  { passes=$((passes + 1)); echo "ok   - $1"; }
bad() { fails=$((fails + 1)); echo "FAIL - $1"; }
check() { _d=$1; shift; if "$@"; then ok "$_d"; else bad "$_d"; fi; }
count() { grep -c -e "$1" "$2"; }   # prints the number of matching lines

T=$(mktemp -d)
trap 'chmod -R u+w "$T" 2>/dev/null; rm -rf "$T"' EXIT
H="$T/etc/hosts"
fixture() {
	rm -rf "$T/etc"; mkdir "$T/etc"
	cat > "$H" <<'EOF'
# header comment mentioning gw-one.test in a comment only
::1			localhost localhost.example.test
127.0.0.1		localhost localhost.example.test

192.0.2.10 nas
203.0.113.9 gw-one.test # 2026-01-01T00:00:00-06:00
203.0.113.9 gw-three.test # 2026-01-01T00:00:00-06:00
192.0.2.20 printer gw-two.test scanner # shared line
192.0.2.30 gw-one.test2
EOF
	chmod 0600 "$H"   # the script must set 0644 itself
}
run() { SGE_HOSTS="$H" SGE_LOCK="$T/lock" SGE_LOGGER=true /usr/local/bin/bash "$SGE" "$@"; }
NAMES="gw-one.test gw-two.test gw-three.test"   # neutral names: the public export's map rewrites uplink names
NAME_COUNT=$(echo $NAMES | wc -w | tr -d ' ')

fixture
run 198.51.100.1 "$NAMES"; rc=$?
check "update exits 0" [ "$rc" -eq 0 ]
for n in $NAMES; do
	check "$n points at the new gateway" [ "$(count "^198.51.100.1 $n # " "$H")" -eq 1 ]
done
check "old gateway address is gone" [ "$(count '^203\.0\.113\.9 ' "$H")" -eq 0 ]
check "unrelated host kept" [ "$(count '^192.0.2.10 nas$' "$H")" -eq 1 ]
check "localhost lines kept byte for byte" [ "$(grep -c 'localhost localhost.example.test' "$H")" -eq 2 ]
check "comment-only mention kept" [ "$(count '^# header comment' "$H")" -eq 1 ]
check "blank line kept" [ "$(grep -c '^$' "$H")" -eq 1 ]
check "shared line keeps its other names" [ "$(count '^192.0.2.20 printer scanner # shared line$' "$H")" -eq 1 ]
check "a longer name with the same prefix survives (old grep deleted it)" [ "$(count '^192.0.2.30 gw-one.test2$' "$H")" -eq 1 ]
check "mode is 0644" [ "$(stat -f %Lp "$H")" = 644 ]
check "no temp or .new file left beside hosts" [ "$(ls "$T/etc" | grep -c .)" -eq 1 ]

# Nothing to change: the file must not be replaced (same inode, same mtime).
ino=$(stat -f %i "$H"); mt=$(stat -f %m "$H"); sum=$(cksum < "$H")
sleep 1
run 198.51.100.1 "$NAMES"; rc=$?
check "second identical run exits 0" [ "$rc" -eq 0 ]
check "second identical run does not replace the file" [ "$(stat -f %i "$H")" = "$ino" ]
check "second identical run does not touch mtime" [ "$(stat -f %m "$H")" = "$mt" ]
# Known-bad for the "unchanged" detector: a different gateway MUST replace it.
run 198.51.100.2 "$NAMES"
check "a changed gateway does replace the file" [ "$(stat -f %i "$H")" != "$ino" ]
check "a changed gateway updates every name" [ "$(count '^198.51.100.2 gw-' "$H")" -eq "$NAME_COUNT" ]

# Refusals leave the file alone.
fixture; sum=$(cksum < "$H")
run 192.168.12.1 "$NAMES"; rc=$?
check "private gateway without allow-private: exit 0, unchanged" [ "$rc" -eq 0 -a "$(cksum < "$H")" = "$sum" ]
run 192.168.12.1 "$NAMES" allow-private
check "private gateway with allow-private is written" [ "$(count '^192.168.12.1 gw-' "$H")" -eq "$NAME_COUNT" ]
fixture; sum=$(cksum < "$H")
run "not-an-ip; rm -rf /" "$NAMES" >/dev/null 2>&1; rc=$?
check "garbage gateway: exit 1, unchanged" [ "$rc" -eq 1 -a "$(cksum < "$H")" = "$sum" ]
run "" "$NAMES"; rc=$?
check "empty gateway: exit 0, unchanged" [ "$rc" -eq 0 -a "$(cksum < "$H")" = "$sum" ]

# A failed update (no temp file can be created) leaves the old file intact.
fixture; sum=$(cksum < "$H")
chmod 0555 "$T/etc"
run 198.51.100.1 "$NAMES" >/dev/null 2>&1; rc=$?
chmod 0755 "$T/etc"
if [ "$(id -u)" -eq 0 ]; then echo "skip - read-only directory case (running as root)"
else
	check "unwritable directory: exit 1" [ "$rc" -eq 1 ]
	check "unwritable directory: hosts unchanged" [ "$(cksum < "$H")" = "$sum" ]
fi

# Two uplinks' hooks at once: both sets of names must land.
fixture
run 198.51.100.1 "$NAMES" &
run 192.0.2.1 "gw-four.test gw-five.test" &
wait
check "concurrent runs: first set present" [ "$(count '^198.51.100.1 gw-' "$H")" -eq "$NAME_COUNT" ]
check "concurrent runs: second set present" [ "$(count '^192.0.2.1 gw-' "$H")" -eq 2 ]
check "concurrent runs: unrelated host kept" [ "$(count '^192.0.2.10 nas$' "$H")" -eq 1 ]

echo "passed=$passes failed=$fails"
[ "$fails" -eq 0 ]
