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
# decide <state> <att> <tmo> <now> <att_ok_since> <last_change> <probe_age>
check "grace: no action while probes are young"      "stay startup-grace" "$(d att down up $T - - 10)"
check "att down + tmo up -> failover"                "failover"           "$(d att down up $T - - 600)"
check "att down + tmo partial -> failover"           "failover"           "$(d att down partial $T - - 600)"
check "att down + tmo down -> stay"                  "stay"               "$(d att down down $T - - 600)"
check "att down + tmo unknown -> stay"               "stay"               "$(d att down unknown $T - - 600)"
check "att partial (one probe ok) -> stay"           "stay"               "$(d att partial up $T - - 600)"
check "att unknown (probes dead) -> stay"            "stay"               "$(d att unknown up $T - - 600)"
check "anti-flap: recent transition blocks failover" "stay anti-flap"     "$(d att down up $T - $((T - 30)) 600)"
check "on tmo, att clear 60s -> stay (hold)"         "stay"               "$(d tmo up up $T $((T - 60)) - 600)"
check "on tmo, att clear 120s -> failback"           "failback"           "$(d tmo up up $T $((T - 120)) - 600)"
check "on tmo, att partial -> stay"                  "stay"               "$(d tmo partial up $T - - 600)"
check "on tmo, tmo dies, att partial -> failback"    "failback tmo-down"  "$(d tmo partial down $T - - 600)"
check "on tmo, both down -> stay"                    "stay"               "$(d tmo down down $T - - 600)"

# evaluate end to end (dry run)
e() { # e <state|-> <att_cf> <att_gg> <tmo_cf> <tmo_gg> [ok_since]
	_t=$(mktemp -d)
	mkdir "$_t/run" "$_t/db" "$_t/fake"
	[ "$1" != - ] && echo "$1" > "$_t/run/wan_state"
	echo 203.0.113.1 > "$_t/db/att_router"; echo 203.0.113.32 > "$_t/db/att_ip"
	echo 192.0.0.1 > "$_t/db/tmo_router";    echo 192.0.0.2 > "$_t/db/tmo_ip"
	for p in att_cf att_gg tmo_cf tmo_gg; do touch "$_t/run/dpinger_$p.pid"; done
	echo "$2" > "$_t/fake/att_cf"; echo "$3" > "$_t/fake/att_gg"
	echo "$4" > "$_t/fake/tmo_cf"; echo "$5" > "$_t/fake/tmo_gg"
	[ -n "${6:-}" ] && echo "$6" > "$_t/run/wan_att_ok_since"
	_now=$(( $(date +%s) + 1000 ))
	[ -n "${6:-}" ] && echo "$(( _now - $6 ))" > "$_t/run/wan_att_ok_since"
	_gw=203.0.113.1; [ "$1" = tmo ] && _gw=192.0.0.1
	WF_SOURCE_ONLY=1 WF_RUN="$_t/run" WF_DB="$_t/db" WF_FAKE_PROBES="$_t/fake" \
	WF_FIB0_GW=$_gw WF_MINIUPNPD=yes WF_DRYRUN=1 WF_NOW=$_now /usr/local/bin/bash -c ". '$CTL'; evaluate_locked" 2>&1
	rm -rf "$_t"
}
o=$(e - 100 100 0 0)
check "evaluate: ATT dead -> FIB 0 default via TRB" "DRYRUN: route -n add -fib 0 default 192.0.0.1" "$o"
check "evaluate: ATT dead -> state tmo"             "DRYRUN: state tmo" "$o"
check "evaluate: ATT dead -> miniupnpd stopped"     "DRYRUN: service miniupnpd stop" "$o"
o=$(e - 100 0 0 0)
check "evaluate: one ATT probe ok -> no transition" "-> stay att-partial" "$o"
o=$(e - 0 0 100 100)
check "evaluate: TMO dead, ATT fine -> stay"        "-> stay att-up" "$o"
o=$(e tmo 0 0 0 0 130)
check "evaluate: on TMO, ATT clear 130s -> failback" "DRYRUN: state att" "$o"
check "evaluate: failback restores ATT gateway"     "default 203.0.113.1" "$o"
o=$(e tmo 0 0 0 0 30)
check "evaluate: on TMO, ATT clear 30s -> hold"     "-> stay on-tmo-att-up" "$o"
o=$(e - '?' '?' 0 0)
check "evaluate: ATT probes unreadable -> stay"     "-> stay att-unknown" "$o"

# probe command line: payload size (0-byte echoes are lost over TMO) and FIB 0 alert
_t=$(mktemp -d); mkdir "$_t/db"; echo 192.0.0.2 > "$_t/db/tmo_ip"
o=$(WF_DRYRUN=1 WF_RUN="$_t" WF_DB="$_t/db" /usr/local/bin/bash -c "WF_SOURCE_ONLY=1 . '$CTL'; probe_start tmo" 2>&1)
rm -rf "$_t"
check "probes send a 16-byte payload"              "-d 16 " "$o"
check "probe alerts run in FIB 0"                  "-C /usr/sbin/setfib 0 " "$o"
check "TMO probes bind the lease address in FIB 2" "setfib 2 dpinger -S -B 192.0.0.2 " "$o"

echo "passed=$passes failed=$fails"
[ "$fails" -eq 0 ] || exit 1

# Mutation pass (only for the real controller, not when testing a mutant).
if [ $# -eq 0 ]; then
	m=$(mktemp)
	for mut in 's/^FAILBACK_HOLD_S=120/FAILBACK_HOLD_S=0/' \
	           's/if \[\[ \$att == down \]\]; then/if [[ $att != up ]]; then/' \
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
