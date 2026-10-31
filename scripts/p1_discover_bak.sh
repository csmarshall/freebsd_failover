#!/usr/local/bin/bash
# P1 discovery, run AFTER the 5G CPE is plugged into ix0. Read-only except
# one thing: it adds an IPv6 default route to probe FIB 2 (never FIB 0) so it
# can test BACKUP IPv6. Needs root (lease file, tcpdump, rtsol).
unset TMOUT
set -uo pipefail   # no -e: keep going and report every check
. "$(dirname "$0")/lib.sh"

if [[ ${1:-} == -h || ${1:-} == --help ]]; then echo "Usage: sudo $0"; exit 0; fi
[[ $(id -u) -eq 0 ]] || die "needs root: sudo $0"

hr "ix0 link"
ifconfig ix0
hr "ix0 lease (last)"
awk '/^lease/{buf=""} {buf=buf $0 "\n"} END{printf "%s", buf}' /var/db/dhclient.leases.ix0
hr "recorded by hooks"
for f in bak_ip bak_router pri_ip pri_router; do printf '%-12s %s\n' "$f" "$(cat /var/db/$f 2>/dev/null || echo '(none)')"; done
hr "FIB 0 defaults (must still be PRIMARY for both families)"
route -n get -inet default | grep -E 'gateway|interface'
route -n get -inet6 default | grep -E 'gateway|interface'
hr "FIB 0 IPv6 default routers (ix0 must NOT appear)"
ndp -rn
hr "FIB 2 IPv4"
netstat -rn -F 2 -f inet
hr "BACKUP IPv4 reachability via FIB 2"
setfib 2 ping -c 5 -t 10 1.1.1.1
setfib 2 ping -c 5 -t 10 8.8.8.8
setfib 2 traceroute -n -w 2 -m 8 1.1.1.1
hr "BACKUP public (CGNAT) address"
setfib 2 curl -4 -s -m 10 https://ifconfig.me; echo
hr "BACKUP path MTU (DF set, payload sizes)"
for s in 1472 1452 1432 1412 1372; do
	if setfib 2 ping -D -c 1 -t 3 -s "$s" 1.1.1.1 >/dev/null 2>&1; then echo "payload $s ok (MTU $((s + 28)))"; break; else echo "payload $s too big"; fi
done
hr "ix0 IPv6 addresses"
ifconfig ix0 inet6
hr "Router Advertisement from 5G CPE (flags M/O = DHCPv6 managed/other, prefixes)"
RA_LOG="$(mktemp)"
timeout 12 tcpdump -n -v -l -i ix0 'icmp6 and ip6[40] == 134' -c 2 > "$RA_LOG" 2>&1 &
sleep 1; rtsol ix0 2>&1; wait
cat "$RA_LOG"
# RAs may be multicast (> ff02::1) or a unicast reply to our RS (> fe80::...);
# take the source of any line tcpdump labels as a router advertisement.
BACKUP_V6_GW="$(grep -B1 'router advertisement' "$RA_LOG" | grep -Eo 'fe80::[0-9a-f:]+ > ' | awk '{print $1}' | sort -u | sed -n 1p)"
rm -f "$RA_LOG"
hr "BACKUP IPv6 via FIB 2"
if [[ -n $BACKUP_V6_GW ]]; then
	echo "BACKUP IPv6 router: $BACKUP_V6_GW%ix0"
	route -6 -n add -fib 2 default "$BACKUP_V6_GW%ix0" >/dev/null 2>&1 ||
		route -6 -n change -fib 2 default "$BACKUP_V6_GW%ix0"
	setfib 2 ping -6 -c 5 2001:4860:4860::8888
	setfib 2 curl -6 -s -m 10 https://ifconfig.me; echo
else
	echo "no RA seen from the 5G CPE: BACKUP IPv6 is off or not offered on LAN side"
fi
hr "resolv.conf (BACKUP DNS must not have leaked in)"
cat /etc/resolv.conf
hr "pf state of ix0 rules"
pfctl -sr 2>/dev/null | grep -E 'ix0|192\.168\.12'
say "discovery done"
