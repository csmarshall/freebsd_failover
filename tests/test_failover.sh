#!/bin/sh
# Unprivileged tests for /usr/local/sbin/wan-failover: the pure decide()
# table, then evaluate end to end with fake probe readings and WF_DRYRUN=1
# (commands are printed, not run). Finally a mutation pass: deliberately
# broken copies of the controller must FAIL this suite.
#
# Usage: tests/test_failover.sh [controller-path]
unset TMOUT
set -u

REPO=$(cd "$(dirname "$0")/.." && pwd)
CTL=${1:-$REPO/router/usr/local/sbin/wan-failover}
fails=0
passes=0
check() { # check <description> <expected-substring> <actual>
	case $3 in
	*"$2"*) passes=$((passes + 1)); echo "ok   - $1" ;;
	*) fails=$((fails + 1)); echo "FAIL - $1 (want '$2', got '$3')" ;;
	esac
}

d() { WF_SOURCE_ONLY=1 /usr/local/bin/bash -c ". '$CTL'; decide $*"; }
T=100000
# decide <state> <pri> <bak> <now> <pri_ok_since> <last_change> <probe_age>
check "grace: no action while probes are young"      "stay startup-grace" "$(d pri down up $T - - 10)"
check "pri down + bak up -> failover"                "failover"           "$(d pri down up $T - - 600)"
check "pri down + bak partial -> failover"           "failover"           "$(d pri down partial $T - - 600)"
check "pri down + bak down -> stay"                  "stay"               "$(d pri down down $T - - 600)"
check "pri down + bak unknown -> stay"               "stay"               "$(d pri down unknown $T - - 600)"
check "pri partial (one probe ok) -> stay"           "stay"               "$(d pri partial up $T - - 600)"
check "pri unknown (probes dead) -> stay"            "stay"               "$(d pri unknown up $T - - 600)"
check "anti-flap: recent transition blocks failover" "stay anti-flap"     "$(d pri down up $T - $((T - 30)) 600)"
check "on bak, pri clear 60s -> stay (hold)"         "stay"               "$(d bak up up $T $((T - 60)) - 600)"
check "on bak, pri clear 120s -> failback"           "failback"           "$(d bak up up $T $((T - 120)) - 600)"
check "on bak, pri partial -> stay"                  "stay"               "$(d bak partial up $T - - 600)"
check "on bak, bak dies, pri partial -> failback"    "failback bak-down"  "$(d bak partial down $T - - 600)"
check "on bak, both down -> stay"                    "stay"               "$(d bak down down $T - - 600)"

# evaluate end to end (dry run)
e() { # e <state|-> <pri_cf> <pri_gg> <bak_cf> <bak_gg> [ok_since]
	_t=$(mktemp -d)
	mkdir "$_t/run" "$_t/db" "$_t/fake"
	[ "$1" != - ] && echo "$1" > "$_t/run/wan_state"
	echo 203.0.113.1 > "$_t/db/pri_router"; echo 203.0.113.32 > "$_t/db/pri_ip"
	echo 192.0.0.1 > "$_t/db/bak_router";    echo 192.0.0.2 > "$_t/db/bak_ip"
	for p in pri_cf pri_gg bak_cf bak_gg; do touch "$_t/run/dpinger_$p.pid"; done
	echo "$2" > "$_t/fake/pri_cf"; echo "$3" > "$_t/fake/pri_gg"
	echo "$4" > "$_t/fake/bak_cf"; echo "$5" > "$_t/fake/bak_gg"
	[ -n "${6:-}" ] && echo "$6" > "$_t/run/wan_pri_ok_since"
	_now=$(( $(date +%s) + 1000 ))
	[ -n "${6:-}" ] && echo "$(( _now - $6 ))" > "$_t/run/wan_pri_ok_since"
	_gw=203.0.113.1; [ "$1" = bak ] && _gw=192.0.0.1
	WF_SOURCE_ONLY=1 WF_RUN="$_t/run" WF_DB="$_t/db" WF_FAKE_PROBES="$_t/fake" \
	WF_FIB0_GW=$_gw WF_MINIUPNPD=yes WF_DRYRUN=1 WF_NOW=$_now /usr/local/bin/bash -c ". '$CTL'; evaluate_locked" 2>&1
	rm -rf "$_t"
}
o=$(e - 100 100 0 0)
check "evaluate: PRIMARY dead -> FIB 0 default via CPE" "DRYRUN: route -n add -fib 0 default 192.0.0.1" "$o"
check "evaluate: PRIMARY dead -> state bak"             "DRYRUN: state bak" "$o"
check "evaluate: PRIMARY dead -> miniupnpd stopped"     "DRYRUN: service miniupnpd stop" "$o"
o=$(e - 100 0 0 0)
check "evaluate: one PRIMARY probe ok -> no transition" "-> stay pri-partial" "$o"
o=$(e - 0 0 100 100)
check "evaluate: BACKUP dead, PRIMARY fine -> stay"        "-> stay pri-up" "$o"
o=$(e bak 0 0 0 0 130)
check "evaluate: on BACKUP, PRIMARY clear 130s -> failback" "DRYRUN: state pri" "$o"
check "evaluate: failback restores PRIMARY gateway"     "default 203.0.113.1" "$o"
o=$(e bak 0 0 0 0 30)
check "evaluate: on BACKUP, PRIMARY clear 30s -> hold"     "-> stay on-bak-pri-up" "$o"
o=$(e - '?' '?' 0 0)
check "evaluate: PRIMARY probes unreadable -> stay"     "-> stay pri-unknown" "$o"

# probe command line: payload size (0-byte echoes are lost over BACKUP) and FIB 0 alert
_t=$(mktemp -d); mkdir "$_t/db"; echo 192.0.0.2 > "$_t/db/bak_ip"
o=$(WF_DRYRUN=1 WF_RUN="$_t" WF_DB="$_t/db" /usr/local/bin/bash -c "WF_SOURCE_ONLY=1 . '$CTL'; probe_start bak" 2>&1)
rm -rf "$_t"
check "probes send a 16-byte payload"              "-d 16 " "$o"
check "probe alerts run in FIB 0"                  "-C /usr/sbin/setfib 0 " "$o"
check "BACKUP probes bind the lease address in FIB 2" "setfib 2 dpinger -S -B 192.0.0.2 " "$o"

echo "passed=$passes failed=$fails"
[ "$fails" -eq 0 ] || exit 1

# Mutation pass (only for the real controller, not when testing a mutant).
if [ $# -eq 0 ]; then
	m=$(mktemp)
	for mut in 's/^FAILBACK_HOLD_S=120/FAILBACK_HOLD_S=0/' \
	           's/if \[\[ \$pri == down \]\]; then/if [[ $pri != up ]]; then/' \
	           's/if (( age < STARTUP_GRACE_S ))/if false/' \
	           's/-fib 0 default/default/g' \
	           's/^PROBE_DATA_BYTES=16/PROBE_DATA_BYTES=0/'; do
		sed "$mut" "$CTL" > "$m"
		if cmp -s "$m" "$CTL"; then echo "FAIL - mutation did not apply: $mut"; exit 1; fi
		if sh "$0" "$m" >/dev/null 2>&1; then
			echo "FAIL - suite passes a broken controller: $mut"; rm -f "$m"; exit 1
		fi
		echo "ok   - mutant caught: $mut"
	done
	rm -f "$m"
fi
