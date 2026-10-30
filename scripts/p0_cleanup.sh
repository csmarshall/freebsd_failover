#!/usr/local/bin/bash
# P0: back up, stop the non-functional dpinger, strip legacy ix0 config,
# and stop ix0 from ever installing an IPv6 default router.
# Safe while ix0 is unplugged; no change to ATT (ixl0) traffic.
unset TMOUT
set -euo pipefail
. "$(dirname "$0")/lib.sh"

usage() {
	cat <<EOF
Usage: $0 [--apply]
  (no args)  dry run: show the rc.conf / rc.local diffs and the runtime steps; touches nothing
  --apply    back up to $BACKUP_DIR, then apply (needs root)
EOF
}
parse_mode "${1:-}"

STAGE="$(mktemp -d -t p0)"
trap 'rm -rf "$STAGE"' EXIT

# rc.conf candidate (sysrc on a copy, never the live file in dry run)
cp /etc/rc.conf "$STAGE/rc.conf"
# media autoselect: the Teltonika port is not 10GBASE-T; the old forced
# "media 10Gbase-T" would give no link at 1G/2.5G.
sysrc -q -f "$STAGE/rc.conf" ifconfig_ix0="DHCP -lro -tso -tso4 -tso6 -vlanhwtso" >/dev/null
# no_radr: take a SLAAC address from TMO but never a default router into
# FIB 0 (net.inet6.ip6.rfc6204w3=1 is global, so RAs are honoured on ix0).
sysrc -q -f "$STAGE/rc.conf" ifconfig_ix0_ipv6="inet6 accept_rtadv no_radr" >/dev/null
sysrc -q -f "$STAGE/rc.conf" static_routes="was110admin" >/dev/null
sysrc -q -f "$STAGE/rc.conf" -x ifconfig_ix0_alias0 route_ltemodem >/dev/null 2>&1 || true
sed -i '' \
	-e 's|^# BACKUP WAN: ix0 (10G RJ45) - T-Mobile$|# BACKUP WAN: ix0 (10G RJ45) - TMO: Teltonika 5G, NAT mode 192.168.12.0/24, carrier CGNAT|' \
	-e 's|^# Add to egress group only when implementing proper failover with gateway monitor$|# Failover: FIB 0 default is owned by wan-failover; ix0 dhclient maintains FIB 2 only|' \
	-e '/^# Modem management aliases (for backup WAN access)$/d' \
	-e '/^# T-Mobile modem management (backup WAN)$/d' \
	"$STAGE/rc.conf"

sed 's|^/etc/dpinger/start_dpinger.sh|# P0 '"$TS"': disabled, replaced by wan_failover (P3): &|' \
	/etc/rc.local > "$STAGE/rc.local"

hr "rc.conf"; show_diff /etc/rc.conf "$STAGE/rc.conf"
hr "rc.local"; show_diff /etc/rc.local "$STAGE/rc.local"

ARCHIVE=(failover failover_comcast start_dpinger.sh start_dpinger_backup.sh startup_script)
hr "runtime steps"
cat <<EOF
- stop dpinger (pid $(cat /var/run/dpinger_ixl0.pid 2>/dev/null || echo none))
- move /etc/dpinger/{$(IFS=,; echo "${ARCHIVE[*]}")} -> /etc/dpinger/attic/
- ix0: remove aliases 192.168.12.2 and 192.168.5.2, routes 192.168.12.1/32 and 192.168.5.1
- ix0: media autoselect, inet6 no_radr
EOF

if [[ $MODE != apply ]]; then
	say "dry run complete; re-run with --apply"
	exit 0
fi

backup p0

install -m 0644 -o root -g wheel "$STAGE/rc.conf" /etc/rc.conf
install -m 0755 -o root -g wheel "$STAGE/rc.local" /etc/rc.local
say "installed rc.conf, rc.local"

if [[ -s /var/run/dpinger_ixl0.pid ]]; then
	kill "$(cat /var/run/dpinger_ixl0.pid)" 2>/dev/null || true
	rm -f /var/run/dpinger_ixl0.pid
	say "stopped dpinger"
fi

mkdir -p /etc/dpinger/attic
for f in "${ARCHIVE[@]}"; do
	if [[ -e /etc/dpinger/$f ]]; then mv -v "/etc/dpinger/$f" /etc/dpinger/attic/; fi
done

ifconfig ix0 inet 192.168.12.2 -alias 2>/dev/null && say "removed alias 192.168.12.2" || true
ifconfig ix0 inet 192.168.5.2 -alias 2>/dev/null && say "removed alias 192.168.5.2" || true
route -n delete -net 192.168.12.1/32 >/dev/null 2>&1 && say "removed route 192.168.12.1/32" || true
route -n delete -host 192.168.5.1 >/dev/null 2>&1 && say "removed route 192.168.5.1" || true
ifconfig ix0 media autoselect
ifconfig ix0 inet6 no_radr

hr "verify"
ifconfig ix0
nd6="$(ifconfig ix0 | grep -c 'nd6 options=.*NO_RADR' || true)"
[[ $nd6 -ge 1 ]] && say "PASS ix0 has NO_RADR" || say "FAIL ix0 missing NO_RADR"
pgrep -lf 'dpinger' || say "no dpinger running (expected until P3)"
route -n get default | grep -E 'gateway|interface'
say "P0 applied. Rollback: sudo $REPO/scripts/rollback.sh $(cat "$BACKUP_DIR/LATEST-p0")"
