#!/usr/local/bin/bash
# Test TMO IPv4 with a static ix0 address instead of DHCP. Adds
# 192.168.12.2/24 to ix0, points probe FIB 2 at 192.168.12.1, tests the
# Teltonika and the internet through FIB 2 only. FIB 0 (real traffic) is
# never touched; the script checks that. Needs root.
unset TMOUT
set -uo pipefail   # no -e: report every check
. "$(dirname "$0")/lib.sh"

TMO_ADDR="192.168.12.2/24"
TMO_GW="192.168.12.1"

usage() {
	cat <<EOF
Usage: sudo $0 [--cleanup]
  (no args)   add $TMO_ADDR to ix0, FIB 2 default via $TMO_GW, run tests (left in place)
  --cleanup   remove the alias and the FIB 2 routes again
EOF
}
case "${1:-}" in -h|--help) usage; exit 0 ;; esac
[[ $(id -u) -eq 0 ]] || die "needs root: sudo $0"

if [[ ${1:-} == --cleanup ]]; then
	route -n delete -fib 2 default >/dev/null 2>&1 && say "removed FIB 2 default"
	route -n delete -fib 2 -host "$TMO_GW" >/dev/null 2>&1 && say "removed FIB 2 host $TMO_GW"
	ifconfig ix0 inet "${TMO_ADDR%/*}" -alias 2>/dev/null && say "removed alias $TMO_ADDR"
	exit 0
fi

FIB0_BEFORE="$(route -n get default | grep -E 'gateway|interface' | tr -s ' ')"

case "$(ifconfig ix0 inet)" in
*"inet ${TMO_ADDR%/*} "*) say "alias $TMO_ADDR already present" ;;
*) ifconfig ix0 inet "$TMO_ADDR" alias && say "added alias $TMO_ADDR" ;;
esac
route -n add -fib 2 -host "$TMO_GW" -interface ix0 >/dev/null 2>&1 ||
	route -n change -fib 2 -host "$TMO_GW" -interface ix0
route -n add -fib 2 default "$TMO_GW" >/dev/null 2>&1 ||
	route -n change -fib 2 default "$TMO_GW"

hr "Teltonika on IPv4 (FIB 0 connected route)"
ping -c 3 -t 5 "$TMO_GW"
arp -an -i ix0
curl -sk -m 8 -o /dev/null -w "https://$TMO_GW/ -> %{http_code}\n" "https://$TMO_GW/"
hr "FIB 2 routes"
netstat -rn -F 2 -f inet
hr "internet via TMO (FIB 2)"
setfib 2 ping -c 5 -t 10 -S "${TMO_ADDR%/*}" 1.1.1.1
setfib 2 ping -c 5 -t 10 -S "${TMO_ADDR%/*}" 8.8.8.8
setfib 2 traceroute -n -w 2 -m 8 -s "${TMO_ADDR%/*}" 1.1.1.1
echo -n "public IPv4 via TMO: "; setfib 2 curl -4 -s -m 10 --interface "${TMO_ADDR%/*}" https://ifconfig.me; echo
hr "TMO path MTU (DF set)"
for s in 1472 1452 1444 1432 1412 1372; do
	if setfib 2 ping -D -c 1 -t 3 -S "${TMO_ADDR%/*}" -s "$s" 1.1.1.1 >/dev/null 2>&1; then
		echo "payload $s ok (MTU $((s + 28)))"; break
	else echo "payload $s too big"; fi
done

hr "verify"
FIB0_AFTER="$(route -n get default | grep -E 'gateway|interface' | tr -s ' ')"
if [[ $FIB0_BEFORE == "$FIB0_AFTER" ]]; then say "PASS FIB 0 default unchanged"; else say "FAIL FIB 0 default changed"; fi
echo "$FIB0_AFTER"
say "left in place; undo with: sudo $0 --cleanup"
