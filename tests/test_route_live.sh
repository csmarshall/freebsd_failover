#!/usr/local/bin/bash
# Root-only test of the controller's set_single_route against the REAL
# routing table. tests/test_fixes.sh only checks the commands the controller
# prints against a stubbed gateway list; this checks what the kernel does
# with them, which is where the 2026-11-10 fault lived (`route add` building
# a multipath group instead of failing).
#
# It works on 198.51.100.0/24 (TEST-NET-2, RFC 5737: never routed, nothing on
# this network uses it) in FIB 0, with the two real uplink gateways as next
# hops, and removes it again on exit. FIB 0's default route is not touched.
#
# The pass/fail reading is NOT the controller's own: paths are counted from
# the kernel's nexthop-group table (netstat -O), which the controller never
# reads. What it cannot show: behaviour for the `default` destination
# specifically, or under a real uplink failure.
#
# Usage: sudo tests/test_route_live.sh [controller-path]
# Exit: 0 = all passed, 1 = a check failed, 2 = cannot run.
unset TMOUT
set -uo pipefail
PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/sbin:/usr/local/bin

REPO=$(cd "$(dirname "$0")/.." && pwd)
CTL=${1:-$REPO/router/usr/local/sbin/wan-failover}
TEST_PREFIX=198.51.100.0/24
TEST_FIB=0
DB=/var/db

[[ $(id -u) -eq 0 ]] || { echo "needs root: sudo $0" >&2; exit 2; }
GW_A=$(cat "$DB/pri_router" 2>/dev/null)
GW_B=$(cat "$DB/bak_router" 2>/dev/null)
[[ -n $GW_A && -n $GW_B && $GW_A != "$GW_B" ]] || { echo "need two different gateways in $DB/pri_router and $DB/bak_router" >&2; exit 2; }

fails=0
pass() { echo "ok   - $*"; }
fail() { echo "FAIL - $*"; fails=$((fails + 1)); }

# Independent readings (neither is the controller's fib_route_gws).
table_paths() { netstat -rn -4 -F "$TEST_FIB" | grep -c "^${TEST_PREFIX}[[:space:]]"; }
group_count() { netstat -4 -OnW -F "$TEST_FIB" | awk '$1 ~ /^[0-9]+$/ && $2 ~ /^-+$/' | grep -c .; }
# The kernel frees a nexthop group a moment after the last route stops using
# it (first run, 2026-11-10: the count read 1, then 0 within the same line),
# so "no group" is judged after a short settle. A group that a route still
# uses never goes away, so a real fault still fails after the wait.
GROUP_SETTLE_TRIES=25
GROUP_SETTLE_SLEEP_S=0.2
groups_settle_to() { # groups_settle_to <count>
	local _i
	for _i in $(seq "$GROUP_SETTLE_TRIES"); do
		if (( $(group_count) == $1 )); then return 0; fi
		sleep "$GROUP_SETTLE_SLEEP_S"
	done
	return 1
}
first_gw() { route -n get -fib "$TEST_FIB" 198.51.100.1 2>/dev/null | awk '$1 == "gateway:" { print $2 }'; }
cleanup() {
	route -n delete -fib "$TEST_FIB" "$TEST_PREFIX" "$GW_A" >/dev/null 2>&1
	route -n delete -fib "$TEST_FIB" "$TEST_PREFIX" "$GW_B" >/dev/null 2>&1
	route -n delete -fib "$TEST_FIB" "$TEST_PREFIX" >/dev/null 2>&1
}
trap cleanup EXIT

if (( $(table_paths) != 0 )); then echo "$TEST_PREFIX already has a route in FIB $TEST_FIB; refusing to touch it" >&2; trap - EXIT; exit 2; fi
BASE_GROUPS=$(group_count)
MULTIPATH=$(sysctl -n net.route.multipath 2>/dev/null || echo 0)
echo "net.route.multipath=$MULTIPATH  gateways: $GW_A, $GW_B  nexthop groups before: $BASE_GROUPS"

# shellcheck disable=SC1090
WF_SOURCE_ONLY=1 WF_LOGGER=true . "$CTL" || { echo "cannot source $CTL" >&2; exit 2; }
ssr() { set_single_route "$TEST_FIB" "$TEST_PREFIX" "$1" >/dev/null; echo $?; }

# 1. Reproduce the fault with plain `route add`, so the readings below are
#    known to see it (a detector that has never failed proves nothing).
route -n add -fib "$TEST_FIB" "$TEST_PREFIX" "$GW_A" >/dev/null 2>&1
route -n add -fib "$TEST_FIB" "$TEST_PREFIX" "$GW_B" >/dev/null 2>&1
if [[ $MULTIPATH == 1 ]]; then
	if (( $(table_paths) == 2 )); then pass "known-bad reproduced: plain route add left 2 paths in the table"
	else fail "expected 2 paths after two plain adds, table shows $(table_paths)"; fi
	if (( $(group_count) == BASE_GROUPS + 1 )); then pass "known-bad reproduced: kernel built a nexthop group"
	else fail "expected $((BASE_GROUPS + 1)) nexthop groups, have $(group_count)"; fi
	if [[ $(fib_route_gws "$TEST_FIB" "$TEST_PREFIX" | grep -c .) -eq 2 ]]; then pass "controller's reading sees both paths"
	else fail "controller's fib_route_gws does not see both paths"; fi
else
	echo "skip - multipath is off: the second add fails, the fault cannot be built here"
fi

# 2. From two paths to exactly one.
rc=$(ssr "$GW_A")
if [[ $rc == 1 ]]; then pass "set_single_route reports changed+verified (rc 1)"; else fail "set_single_route rc=$rc, want 1"; fi
if (( $(table_paths) == 1 )); then pass "one path left in the table"; else fail "table shows $(table_paths) paths, want 1"; fi
if groups_settle_to "$BASE_GROUPS"; then pass "nexthop group is gone"; else fail "nexthop groups: $(group_count), want $BASE_GROUPS"; fi
if [[ $(first_gw) == "$GW_A" ]]; then pass "the path left is via $GW_A"; else fail "route get says $(first_gw), want $GW_A"; fi

# 3. Idempotent.
rc=$(ssr "$GW_A")
if [[ $rc == 0 ]]; then pass "second call changes nothing (rc 0)"; else fail "second call rc=$rc, want 0"; fi

# 4. Switch gateway (a failover): one path, the new one, no group left behind.
rc=$(ssr "$GW_B")
if [[ $rc == 1 && $(table_paths) -eq 1 && $(first_gw) == "$GW_B" ]]; then pass "switch to $GW_B leaves exactly that path"
else fail "after switch: rc=$rc paths=$(table_paths) gw=$(first_gw)"; fi
if groups_settle_to "$BASE_GROUPS"; then pass "no nexthop group after the switch"; else fail "nexthop groups after switch: $(group_count), want $BASE_GROUPS"; fi

# 5. And back (a failback), which is where 2026-11-10 ended with two.
rc=$(ssr "$GW_A")
if [[ $rc == 1 && $(table_paths) -eq 1 && $(first_gw) == "$GW_A" ]] && groups_settle_to "$BASE_GROUPS"; then pass "switch back to $GW_A leaves exactly that path"
else fail "after switch back: rc=$rc paths=$(table_paths) gw=$(first_gw) groups=$(group_count)"; fi

# 6. From nothing.
cleanup
rc=$(ssr "$GW_A")
if [[ $rc == 1 && $(table_paths) -eq 1 && $(first_gw) == "$GW_A" ]]; then pass "from no route: exactly one path via $GW_A"
else fail "from no route: rc=$rc paths=$(table_paths) gw=$(first_gw)"; fi

cleanup
if (( $(table_paths) == 0 )) && groups_settle_to "$BASE_GROUPS"; then pass "test prefix removed, nexthop groups back to $BASE_GROUPS"
else fail "cleanup left paths=$(table_paths) groups=$(group_count)"; fi

echo "live route test: $fails failure(s)"
(( fails == 0 ))
