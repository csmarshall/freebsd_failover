#!/usr/local/bin/bash
# P1: add probe FIBs (1 = PRIMARY, 2 = BACKUP) and install the WAN dhclient hooks,
# which keep each WAN's FIB current and give FIB 0 only to the WAN that
# /var/run/wan_state names (absent = pri). Seeds FIB 1 from the live PRIMARY lease.
# FIB 0 (real traffic) is not changed; the script checks that.
unset TMOUT
set -euo pipefail
. "$(dirname "$0")/lib.sh"

usage() {
	cat <<EOF
Usage: $0 [--apply]
  (no args)  dry run: run the hook tests, show diffs for every file; touches nothing
  --apply    back up to $BACKUP_DIR, then install (needs root)
EOF
}
parse_mode "${1:-}"

NFIBS=3
SRC="$REPO/router/etc"
# live path -> mode
declare -A FILES=(
	[/etc/dhclient.conf]=0644
	[/etc/dhclient-enter-hooks]=0644
	[/etc/dhclient-exit-hooks]=0644
	[/etc/dhclient-scripts/wan-lib.sh]=0644
	[/etc/dhclient-scripts/dhclient-ixl0-enter-hooks]=0644
	[/etc/dhclient-scripts/dhclient-ixl0-exit-hooks]=0644
	[/etc/dhclient-scripts/dhclient-ix0-enter-hooks]=0644
	[/etc/dhclient-scripts/dhclient-ix0-exit-hooks]=0644
	[/etc/dhclient-scripts/set_gateway_entries.sh]=0755
)
OBSOLETE=(/etc/dhclient-scripts/dhclient-ix0-entry-hooks)

hr "hook tests"
sh "$REPO/tests/test_hooks.sh" || die "hook tests failed; not installing"

STAGE="$(mktemp -d -t p1)"
trap 'rm -rf "$STAGE"' EXIT
cp /boot/loader.conf "$STAGE/loader.conf"
if ! grep -c '^net.fibs=' "$STAGE/loader.conf" >/dev/null; then
	printf '\n# Probe FIBs for WAN failover: 1 = PRIMARY (ixl0), 2 = BACKUP (ix0)\nnet.fibs="%s"\n' "$NFIBS" >> "$STAGE/loader.conf"
fi
hr "/boot/loader.conf"; show_diff /boot/loader.conf "$STAGE/loader.conf"

# CPE management alias: owned by rc.conf (like the ONT one on ixl0); the
# hooks add lease addresses as aliases so DHCP never removes it.
CPE_MGMT="192.168.12.2/24"
cp /etc/rc.conf "$STAGE/rc.conf"
sysrc -q -f "$STAGE/rc.conf" ifconfig_ix0_alias0="inet $CPE_MGMT" >/dev/null
hr "/etc/rc.conf"; show_diff /etc/rc.conf "$STAGE/rc.conf"

for live in "${!FILES[@]}"; do
	hr "$live"; show_diff "$live" "$SRC/${live#/etc/}"
done
for f in "${OBSOLETE[@]}"; do
	if [[ -e $f ]]; then hr "$f"; say "will be removed (kept in backup)"; fi
done

# Prefer what the new hooks record; fall back to the legacy files on first run.
PRIMARY_IP="$(cat /var/db/pri_ip 2>/dev/null || cat /var/db/ixl0_ip)"
PRIMARY_GW="$(cat /var/db/pri_router 2>/dev/null || cat /tmp/ixl0_router)"
hr "runtime steps"
cat <<EOF
- sysctl net.fibs=$NFIBS (now $(sysctl -n net.fibs))
- seed /var/db/pri_ip=$PRIMARY_IP /var/db/pri_router=$PRIMARY_GW
- FIB 1: host $PRIMARY_GW -interface ixl0, default $PRIMARY_GW
- ix0: add alias $CPE_MGMT (CPE UI at 192.168.12.1 from LAN via existing pf NAT)
EOF

if [[ $MODE != apply ]]; then
	say "dry run complete; re-run with --apply"
	exit 0
fi

FIB0_BEFORE="$(route -n get default | grep -E 'gateway|interface' | tr -s ' ')"
backup p1

install -m 0644 -o root -g wheel "$STAGE/loader.conf" /boot/loader.conf
install -m 0644 -o root -g wheel "$STAGE/rc.conf" /etc/rc.conf
for live in "${!FILES[@]}"; do
	install -m "${FILES[$live]}" -o root -g wheel "$SRC/${live#/etc/}" "$live"
	say "installed $live"
done
for f in "${OBSOLETE[@]}"; do
	if [[ -e $f ]]; then rm -v "$f"; fi
done

if ! sysctl net.fibs="$NFIBS" >/dev/null 2>&1 || [[ $(sysctl -n net.fibs) -lt $NFIBS ]]; then
	say "WARNING: runtime net.fibs increase failed; REBOOT before plugging in the 5G CPE"
else
	say "net.fibs=$(sysctl -n net.fibs)"
fi

echo "$PRIMARY_IP" > /var/db/pri_ip
echo "$PRIMARY_GW" > /var/db/pri_router
route -n add -fib 1 -host "$PRIMARY_GW" -interface ixl0 >/dev/null 2>&1 ||
	route -n change -fib 1 -host "$PRIMARY_GW" -interface ixl0
route -n add -fib 1 default "$PRIMARY_GW" >/dev/null 2>&1 ||
	route -n change -fib 1 default "$PRIMARY_GW"

case "$(ifconfig ix0 inet)" in
*"inet ${CPE_MGMT%/*} "*) say "ix0 already has $CPE_MGMT" ;;
*) ifconfig ix0 inet "$CPE_MGMT" alias && say "added ix0 alias $CPE_MGMT" ;;
esac

hr "verify"
for chk in "ixl0 192.168.11.2" "ix0 ${CPE_MGMT%/*}"; do
	set -- $chk
	if [[ $(ifconfig "$1" inet | grep -c "inet $2 ") -ge 1 ]]; then say "PASS $1 has mgmt alias $2"; else say "FAIL $1 missing mgmt alias $2"; fi
done
if ping -c 2 -t 4 192.168.12.1 >/dev/null 2>&1; then say "PASS CPE 192.168.12.1 reachable"; else say "FAIL CPE 192.168.12.1 unreachable"; fi
netstat -rn -F 1 -f inet
FIB0_AFTER="$(route -n get default | grep -E 'gateway|interface' | tr -s ' ')"
if [[ $FIB0_BEFORE == "$FIB0_AFTER" ]]; then say "PASS FIB 0 default unchanged:"; else say "FAIL FIB 0 default changed:"; fi
echo "$FIB0_AFTER"
if setfib 1 ping -c 3 -t 5 -S "$PRIMARY_IP" 1.1.1.1; then say "PASS FIB 1 reaches 1.1.1.1 via PRIMARY"; else say "FAIL FIB 1 cannot reach 1.1.1.1"; fi
if [[ -s /var/db/bak_ip ]]; then
	if setfib 2 ping -c 3 -t 8 -S "$(cat /var/db/bak_ip)" 1.1.1.1 >/dev/null 2>&1; then
		say "PASS FIB 2 reaches 1.1.1.1 via BACKUP"
	else
		say "FAIL FIB 2 cannot reach 1.1.1.1 via BACKUP"
	fi
elif setfib 2 ping -c 1 -t 2 1.1.1.1 >/dev/null 2>&1; then
	say "FAIL FIB 2 reached 1.1.1.1 with no BACKUP lease (leak from FIB 0?)"
else
	say "PASS FIB 2 has no route (no BACKUP lease yet)"
fi
say "P1 applied. Next PRIMARY renewal should log 'pri: FIB 1 default via' in /var/log/messages."
say "Rollback: sudo $REPO/scripts/rollback.sh $(cat "$BACKUP_DIR/LATEST-p1")"
