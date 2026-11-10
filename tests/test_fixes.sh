#!/bin/sh
# Unprivileged tests for the 2026-11-10 fixes: FIB 0 must end with exactly one
# default (no multipath group), and a notification that cannot be sent must
# leave a record. Runs against any controller build (nat64 or clat4 probes),
# so the installer can run it on the exact file it is about to install.
#
# What this cannot show: that the kernel does what the printed `route`
# commands intend. The gateway list here is a stub (WF_FAKE_GWS).
# tests/test_route_live.sh (root) runs the same function against the real
# routing table.
#
# Usage: tests/test_fixes.sh [controller-path [notifier-path]]
unset TMOUT
set -u

REPO=$(cd "$(dirname "$0")/.." && pwd)
CTL=${1:-$REPO/router/usr/local/sbin/wan-failover}
NOTIFIER=${2:-$REPO/router/usr/local/libexec/wan-notify}
PRIMARY_GW=192.0.2.1
BACKUP_GW=198.51.100.1
fails=0
passes=0
check() { # check <description> <expected-substring> <actual>
	case $3 in
	*"$2"*) passes=$((passes + 1)); echo "ok   - $1" ;;
	*) fails=$((fails + 1)); echo "FAIL - $1 (want '$2', got '$3')" ;;
	esac
}
check_not() { # check_not <description> <unwanted-substring> <actual>
	case $3 in
	*"$2"*) fails=$((fails + 1)); echo "FAIL - $1 (did not want '$2', got '$3')" ;;
	*) passes=$((passes + 1)); echo "ok   - $1" ;;
	esac
}

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir "$T/run" "$T/db" "$T/fake"
echo "$PRIMARY_GW" > "$T/db/pri_router"; echo 192.0.2.50 > "$T/db/pri_ip"
echo "$BACKUP_GW" > "$T/db/bak_router"; echo 198.51.100.50 > "$T/db/bak_ip"
for p in pri_cf pri_gg bak_cf bak_gg; do touch "$T/run/dpinger_$p.pid"; done

# ev <state|-> <pri-loss> <bak-loss> <FIB 0 gateways> : one dry-run evaluate
ev() {
	rm -f "$T/run/wan_state"
	[ "$1" != - ] && echo "$1" > "$T/run/wan_state"
	echo "$2" > "$T/fake/pri_cf"; echo "$2" > "$T/fake/pri_gg"
	echo "$3" > "$T/fake/bak_cf"; echo "$3" > "$T/fake/bak_gg"
	_now=$(( $(date +%s) + 1000 ))
	echo "$(( _now - 500 ))" > "$T/run/wan_pri_ok_since"
	WF_SOURCE_ONLY=1 WF_RUN="$T/run" WF_DB="$T/db" WF_FAKE_PROBES="$T/fake" WF_FAKE_GWS="$4" \
	WF_MINIUPNPD=no WF_BACKUP_CLAT=/nonexistent WF_DRYRUN=1 WF_NOW=$_now \
		/usr/local/bin/bash -c ". '$CTL'; evaluate_locked" 2>&1
}

# --- one default in FIB 0 -------------------------------------------------------
o=$(ev - 100 0 "$PRIMARY_GW")
check "failover: adds the BACKUP default"                     "DRYRUN: route -n add -fib 0 default $BACKUP_GW" "$o"
check "failover: removes the PRIMARY default by gateway"       "DRYRUN: route -n delete -fib 0 default $PRIMARY_GW" "$o"
case $o in *"add -fib 0 default $BACKUP_GW"*"delete -fib 0 default $PRIMARY_GW"*) ok=yes ;; *) ok=no ;; esac
check "failover: add before delete (never without a default)" "yes" "$ok"

o=$(ev bak 0 0 "$BACKUP_GW")
check "failback: adds the PRIMARY default"                     "DRYRUN: route -n add -fib 0 default $PRIMARY_GW" "$o"
check "failback: removes the BACKUP default by gateway"       "DRYRUN: route -n delete -fib 0 default $BACKUP_GW" "$o"

o=$(ev - 0 0 "$PRIMARY_GW $BACKUP_GW")
check     "2026-11-10 state (two defaults, on PRIMARY): stray BACKUP path removed" "DRYRUN: route -n delete -fib 0 default $BACKUP_GW" "$o"
check_not "2026-11-10 state: the PRIMARY default is not deleted" "delete -fib 0 default $PRIMARY_GW" "$o"
check_not "2026-11-10 state: nothing is added"               "route -n add" "$o"

o=$(ev bak 100 0 "$PRIMARY_GW $BACKUP_GW")
check     "two defaults while on BACKUP: stray PRIMARY path removed" "DRYRUN: route -n delete -fib 0 default $PRIMARY_GW" "$o"
check_not "two defaults while on BACKUP: the BACKUP default stays"  "delete -fib 0 default $BACKUP_GW" "$o"

o=$(ev - 0 0 "$PRIMARY_GW")
check_not "steady state, one correct default: no route command" "DRYRUN: route" "$o"

o=$(ev - 0 0 "")
check     "no default at all: PRIMARY default added"            "DRYRUN: route -n add -fib 0 default $PRIMARY_GW" "$o"
check_not "no default at all: nothing deleted"              "route -n delete" "$o"

o=$(ev - 0 0 "$BACKUP_GW")
check "only the wrong default: PRIMARY added"                   "DRYRUN: route -n add -fib 0 default $PRIMARY_GW" "$o"
check "only the wrong default: BACKUP removed"                 "DRYRUN: route -n delete -fib 0 default $BACKUP_GW" "$o"

st() { WF_SOURCE_ONLY=1 WF_RUN="$T/run" WF_DB="$T/db" WF_FAKE_PROBES="$T/fake" WF_FAKE_GWS="$1" \
	/usr/local/bin/bash -c ". '$CTL'; status" 2>&1; }
check     "status flags two defaults"            "MULTIPATH" "$(st "$PRIMARY_GW $BACKUP_GW")"
check     "status lists both gateways"           "$PRIMARY_GW $BACKUP_GW" "$(st "$PRIMARY_GW $BACKUP_GW")"
check_not "status is quiet about one default"    "MULTIPATH" "$(st "$PRIMARY_GW")"
check     "status reports a missing default"     "FIB 0 default: none" "$(st "")"

# --- notifications -----------------------------------------------------------------
o=$(ev - 100 0 "$PRIMARY_GW")
check "transition notifies"                      "DRYRUN: notify WAN pri -> bak (pri-down)" "$o"
if [ "$(grep -c 'pushover_message.sh' "$CTL")" -eq 0 ]; then passes=$((passes + 1)); echo "ok   - controller no longer calls the IPv6-first sender"
else fails=$((fails + 1)); echo "FAIL - controller still calls pushover_message.sh"; fi

# ns <sender> <timeout-s> : synchronous notify_send; prints rc and the event log
ns() {
	: > "$T/events"
	WF_SOURCE_ONLY=1 WF_RUN="$T/run" WF_DB="$T/db" WF_EVENT_LOG="$T/events" WF_NOTIFY_CMD="$1" WF_LOGGER=true \
		/usr/local/bin/bash -c ". '$CTL'; NOTIFY_TIMEOUT_S=$2; notify_send 'hello there'; echo rc=\$?" 2>&1
	echo "log=$(cat "$T/events")"
}
o=$(ns /usr/bin/true 5)
check     "sender succeeds: rc 0"                           "rc=0" "$o"
check_not "sender succeeds: nothing logged as failed"       "notify failed" "$o"
o=$(ns /usr/bin/false 5)
check "known-bad sender (fails): rc 1"                      "rc=1" "$o"
check "known-bad sender (fails): recorded in the event log" "notify failed: hello there" "$o"
printf '#!/bin/sh\ncat >/dev/null\nsleep 4\nexit 0\n' > "$T/slow"; chmod +x "$T/slow"
o=$(ns "$T/slow" 1)
check "known-bad sender (hangs past the limit): recorded"   "notify failed: hello there" "$o"

# --- the sender itself (curl stubbed: records argv and stdin) --------------------------
printf '#!/bin/sh\nprintf "%%s\\n" "$@" > "%s/curl.argv"\ncat > "%s/curl.stdin"\nexit ${CURL_RC:-0}\n' "$T" "$T" > "$T/curl"
chmod +x "$T/curl"
printf 'PUSHOVER_USER=uuuSECRETuuu\nPUSHOVER_TOKEN=tttSECRETttt\n' > "$T/conf"
wn() { WN_CONF="${WN_CONF_OVERRIDE:-$T/conf}" WN_CURL="$T/curl" sh "$NOTIFIER" "$@"; }
rm -f "$T/curl.argv"; echo "uplink moved" | wn high; rc=$?
argv=$(cat "$T/curl.argv" 2>/dev/null); stdin=$(cat "$T/curl.stdin" 2>/dev/null)
check     "wan-notify: accepted send exits 0"               "0" "$rc"
check     "wan-notify: forces IPv4"                         "
-4
" "
$argv
"
check     "wan-notify: bounded attempt time"                "--max-time" "$argv"
check     "wan-notify: high = Pushover priority 1"          "priority=1" "$argv"
check     "wan-notify: message passed"                      "message=uplink moved" "$argv"
check_not "wan-notify: token is not on curl's command line" "tttSECRETttt" "$argv"
check_not "wan-notify: user is not on curl's command line"  "uuuSECRETuuu" "$argv"
check     "wan-notify: token goes to curl on stdin"         "token=tttSECRETttt" "$stdin"
( export CURL_RC=7; echo "uplink moved" | wn high >/dev/null 2>&1 ); check "wan-notify: failed send exits 1" "1" "$?"
echo "uplink moved" | WN_CONF_OVERRIDE=/nonexistent wn high >/dev/null 2>&1; check "wan-notify: missing config exits 2" "2" "$?"
printf '' | wn high >/dev/null 2>&1; check "wan-notify: empty message exits 2" "2" "$?"

echo "passed=$passes failed=$fails"
[ "$fails" -eq 0 ] || exit 1

# Mutation pass (only for the real files, not when testing a mutant).
if [ $# -eq 0 ]; then
	m=$(mktemp)
	for mut in 's/run route -n delete -fib "\$fib"/: route -n delete -fib "$fib"/' \
	           's/if \[\[ \$g == "\$gw" \]\]; then have=1; fi/:/' \
	           's/run route -n add -fib "\$fib" "\$dest" "\$gw" >\/dev\/null 2>&1 ||/true ||/' \
	           's/notify failed: \$1" >> "\$EVENT_LOG"/notify failed: $1" >> \/dev\/null/' \
	           's/timeout "\$NOTIFY_TIMEOUT_S" //' \
	           's/^	notify "WAN /	: "WAN /'; do
		sed "$mut" "$CTL" > "$m"
		if cmp -s "$m" "$CTL"; then echo "FAIL - mutation did not apply: $mut"; exit 1; fi
		if sh "$0" "$m" "$NOTIFIER" >/dev/null 2>&1; then
			echo "FAIL - suite passes a broken controller: $mut"; rm -f "$m"; exit 1
		fi
		echo "ok   - mutant caught: $mut"
	done
	for mut in 's/"\$CURL" -4 /"$CURL" /' \
	           's/--config - \\/--form-string "token=$PUSHOVER_TOKEN" \\/'; do
		sed "$mut" "$NOTIFIER" > "$m"
		if cmp -s "$m" "$NOTIFIER"; then echo "FAIL - mutation did not apply: $mut"; exit 1; fi
		if sh "$0" "$CTL" "$m" >/dev/null 2>&1; then
			echo "FAIL - suite passes a broken notifier: $mut"; rm -f "$m"; exit 1
		fi
		echo "ok   - mutant caught: $mut"
	done
	rm -f "$m"
fi
