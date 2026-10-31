#!/bin/sh
# Runs p2_pf.sh's own LAN-IPv6 leak detector (radvd_leaks / radvd_selftest)
# outside of P2, unprivileged. Exists because sanitising the public copy once
# rewrote the detector's sample prefixes but not its allow-list, so the
# public self-test failed and nothing noticed (only P2 itself ran it).
#
# Usage: tests/test_radvd_detector.sh
unset TMOUT
set -u

REPO=$(cd "$(dirname "$0")/.." && pwd)
P2="$REPO/scripts/p2_pf.sh"
t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT

# The allow-list and the two detector functions, verbatim from P2.
{
	echo 'STAGE="$1"'
	sed -n '/^LAN_V6_ALLOWED=/p' "$P2"
	sed -n '/^radvd_leaks() {/,/^}/p; /^radvd_selftest() {/,/^}/p' "$P2"
	echo 'radvd_selftest && echo SELFTEST_PASS || echo SELFTEST_FAIL'
	echo 'printf "prefix %s::/64 {\n" "$(printf %s "$LAN_V6_ALLOWED" | sed "s/^^(//; s/|.*//; s/:\$//")" > "$STAGE/derived"'
	echo 'radvd_leaks "$STAGE/derived" | wc -l | tr -d " " | sed "s/^/DERIVED_LEAKS=/"'
} > "$t/run.sh"

if [ "$(/usr/bin/grep -c '^radvd_selftest() {' "$t/run.sh")" -ne 1 ]; then
	echo "FAIL - could not extract radvd_selftest from $P2"; exit 1
fi
out=$(bash "$t/run.sh" "$t" 2>&1)
fails=0
case $out in *SELFTEST_PASS*) echo "ok   - P2 radvd leak detector self-test passes" ;;
*) echo "FAIL - P2 radvd leak detector self-test: $out"; fails=1 ;; esac
case $out in *DERIVED_LEAKS=0*) echo "ok   - a prefix built from LAN_V6_ALLOWED is not reported as a leak" ;;
*) echo "FAIL - allow-list rejects its own prefix: $out"; fails=1 ;; esac
echo "passed=$((2 - fails)) failed=$fails"
[ "$fails" -eq 0 ]
