#!/usr/local/bin/bash
# Test BACKUP IPv4 with a static ix0 address instead of DHCP. Adds
# 192.168.12.2/24 to ix0, points probe FIB 2 at 192.168.12.1, tests the
# 5G CPE and the internet through FIB 2 only. FIB 0 (real traffic) is
# never touched; the script checks that. Needs root.
unset TMOUT
set -uo pipefail   # no -e: report every check
. "$(dirname "$0")/lib.sh"

BACKUP_ADDR="192.168.12.2/24"
BACKUP_GW="192.168.12.1"

usage() {
	cat <<EOF
Usage: sudo $0 [--cleanup]
  (no args)   add $BACKUP_ADDR to ix0, FIB 2 default via $BACKUP_GW, run tests (left in place)
  --cleanup   remove the alias and the FIB 2 routes again
EOF
}
case "${1:-}" in -h|--help) usage; exit 0 ;; esac
[[ $(id -u) -eq 0 ]] || die "needs root: sudo $0"

if [[ ${1:-} == --cleanup ]]; then
	route -n delete -fib 2 default >/dev/null 2>&1 && say "removed FIB 2 default"
	route -n delete -fib 2 -host "$BACKUP_GW" >/dev/null 2>&1 && say "removed FIB 2 host $BACKUP_GW"
	ifconfig ix0 inet "${BACKUP_ADDR%/*}" -alias 2>/dev/null && say "removed alias $BACKUP_ADDR"
	exit 0
fi

FIB0_BEFORE="$(route -n get default | grep -E 'gateway|interface' | tr -s ' ')"

case "$(ifconfig ix0 inet)" in
*"inet ${BACKUP_ADDR%/*} "*) say "alias $BACKUP_ADDR already present" ;;
*) ifconfig ix0 inet "$BACKUP_ADDR" alias && say "added alias $BACKUP_ADDR" ;;
esac
route -n add -fib 2 -host "$BACKUP_GW" -interface ix0 >/dev/null 2>&1 ||
	route -n change -fib 2 -host "$BACKUP_GW" -interface ix0
route -n add -fib 2 default "$BACKUP_GW" >/dev/null 2>&1 ||
	route -n change -fib 2 default "$BACKUP_GW"

hr "5G CPE on IPv4 (FIB 0 connected route)"
ping -c 3 -t 5 "$BACKUP_GW"
arp -an -i ix0
curl -sk -m 8 -o /dev/null -w "https://$BACKUP_GW/ -> %{http_code}\n" "https://$BACKUP_GW/"
hr "FIB 2 routes"
netstat -rn -F 2 -f inet
hr "internet via BACKUP (FIB 2)"
setfib 2 ping -c 5 -t 10 -S "${BACKUP_ADDR%/*}" 1.1.1.1
setfib 2 ping -c 5 -t 10 -S "${BACKUP_ADDR%/*}" 8.8.8.8
setfib 2 traceroute -n -w 2 -m 8 -s "${BACKUP_ADDR%/*}" 1.1.1.1
echo -n "public IPv4 via BACKUP: "; setfib 2 curl -4 -s -m 10 --interface "${BACKUP_ADDR%/*}" https://ifconfig.me; echo
hr "BACKUP path MTU (DF set)"
for s in 1472 1452 1444 1432 1412 1372; do
	if setfib 2 ping -D -c 1 -t 3 -S "${BACKUP_ADDR%/*}" -s "$s" 1.1.1.1 >/dev/null 2>&1; then
		echo "payload $s ok (MTU $((s + 28)))"; break
	else echo "payload $s too big"; fi
done

hr "verify"
FIB0_AFTER="$(route -n get default | grep -E 'gateway|interface' | tr -s ' ')"
if [[ $FIB0_BEFORE == "$FIB0_AFTER" ]]; then say "PASS FIB 0 default unchanged"; else say "FAIL FIB 0 default changed"; fi
echo "$FIB0_AFTER"
say "left in place; undo with: sudo $0 --cleanup"
