#!/usr/local/bin/bash
# P3: install the WAN failover controller (/usr/local/sbin/wan-failover), its
# rc.d service and the every-minute cron safety net; start the four dpinger
# probes and check the controller sees both uplinks healthy and stays on PRIMARY.
# Does NOT exercise a failover: that is the P6 test with you at the box.
unset TMOUT
set -euo pipefail
. "$(dirname "$0")/lib.sh"

usage() {
	cat <<EOF
Usage: $0 [--apply]
  (no args)  dry run: tests, diffs, the dpinger commands it would run; touches nothing
  --apply    back up to $BACKUP_DIR, install, start, verify (needs root)
EOF
}
parse_mode "${1:-}"

CTL=/usr/local/sbin/wan-failover
declare -A FILES=(
	[$CTL]=0755
	[/usr/local/etc/rc.d/wan_failover]=0555
	[/etc/cron.d/wan-failover]=0644
)
SOCKS=(pri_cf pri_gg bak_cf bak_gg)

hr "tests"
sh "$REPO/tests/test_hooks.sh" >/dev/null || die "hook tests failed"
sh "$REPO/tests/test_failover.sh" || die "controller tests failed; not installing"

STAGE="$(mktemp -d -t p3)"
trap 'rm -rf "$STAGE"' EXIT
cp /etc/rc.conf "$STAGE/rc.conf"
sysrc -q -f "$STAGE/rc.conf" wan_failover_enable=YES >/dev/null
hr "/etc/rc.conf"; show_diff /etc/rc.conf "$STAGE/rc.conf"
for live in "${!FILES[@]}"; do
	hr "$live"; show_diff "$live" "$REPO/router${live}"
done

for f in /var/db/pri_ip /var/db/bak_ip /var/db/pri_router /var/db/bak_router; do
	[[ -s $f ]] || die "$f missing or empty; the controller needs it"
done
hr "commands 'service wan_failover start' will run"
WF_DRYRUN=1 WF_RUN="$STAGE" "$REPO/router$CTL" start

if [[ $MODE != apply ]]; then
	say "dry run complete; re-run with --apply"
	exit 0
fi

FIB0_BEFORE="$(route -n get default | grep -E 'gateway|interface' | tr -s ' ')"
backup p3
if [[ $(pgrep -f 'dpinger .*-i (pri|bak)_' | wc -l) -gt 0 ]]; then
	say "stopping the running wan_failover probes (re-apply)"
	service wan_failover onestop
fi
if [[ $(pgrep -f dpinger | wc -l) -gt 0 ]]; then die "a non-wan_failover dpinger is running; stop it first"; fi
install -m 0644 -o root -g wheel "$STAGE/rc.conf" /etc/rc.conf
for live in "${!FILES[@]}"; do
	install -m "${FILES[$live]}" -o root -g wheel "$REPO/router${live}" "$live"
	say "installed $live"
done
service wan_failover start

hr "verify"
fails=0
pass() { say "PASS $*"; }
fail() { say "FAIL $*"; fails=$((fails + 1)); }

ready=0
for _ in $(seq 1 30); do
	ready=0
	for s in "${SOCKS[@]}"; do
		[[ -S /var/run/dpinger_$s.sock ]] && ready=$((ready + 1))
	done
	(( ready == ${#SOCKS[@]} )) && break
	sleep 1
done
if (( ready == ${#SOCKS[@]} )); then pass "all 4 dpinger sockets up"; else fail "$ready/4 dpinger sockets up"; fi
pgrep -lf dpinger || true
for s in "${SOCKS[@]}"; do
	line="$(nc -U -w 2 /var/run/dpinger_$s.sock 2>/dev/null || true)"
	echo "  $s: ${line:-<no reply>}"
done

# Wait out the startup grace, then the controller must see both WANs and stay.
say "waiting ~60s for the probes' startup grace and averaging window"
verdict=""
for _ in $(seq 1 90); do
	verdict="$($CTL evaluate 2>&1 | tail -1)"
	[[ $verdict != *startup-grace* ]] && break
	sleep 1
done
echo "  evaluate: $verdict"
case $verdict in
*"pri=up bak=up -> stay pri-up"*) pass "controller: both uplinks up, staying on PRIMARY" ;;
*"-> stay"*) fail "controller stays but not both up: $verdict" ;;
*) fail "controller did not decide to stay: $verdict" ;;
esac
$CTL status

state="$(cat /var/run/wan_state 2>/dev/null || echo pri)"
if [[ $state == pri ]]; then pass "wan_state = pri"; else fail "wan_state = $state"; fi
FIB0_AFTER="$(route -n get default | grep -E 'gateway|interface' | tr -s ' ')"
if [[ $FIB0_BEFORE == "$FIB0_AFTER" ]]; then pass "FIB 0 default unchanged"; else fail "FIB 0 default changed"; fi
echo "$FIB0_AFTER"

# The transition kills NAT states with this form; check pfctl accepts it,
# using TEST-NET-1 so nothing real matches.
if pfctl -q -k nat -k 192.0.2.99 >/dev/null 2>&1; then pass "pfctl -k nat syntax accepted"; else fail "pfctl -k nat -k <net> rejected"; fi
if command -v blink1-tool >/dev/null; then pass "blink1-tool present"; else say "INFO no blink1-tool (LED skipped)"; fi
if [[ $(/usr/bin/grep -c 'wan-failover evaluate' /etc/cron.d/wan-failover) -eq 1 ]]; then pass "cron entry installed"; else fail "cron entry missing"; fi

say "P3 applied with $fails failure(s). Failover is now LIVE (no test failover was done)."
say "Watch: tail -f /var/log/messages | grep wan-failover ; status: $CTL status"
say "Disable quickly: sudo service wan_failover stop && sudo rm /etc/cron.d/wan-failover"
say "Rollback: sudo $REPO/scripts/rollback.sh $(cat "$BACKUP_DIR/LATEST-p3") --apply"
