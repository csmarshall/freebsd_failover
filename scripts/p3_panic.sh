#!/usr/local/bin/bash
# P3 panic button: stop the WAN failover controller and put router back on ATT
# by hand. Uses nothing from the controller itself, so it works even if
# wan-failover is broken. Leaves pf, the dhclient hooks and FIBs 1/2 alone
# (P1/P2, which are verified). Safe to run more than once.
#
#   sudo ./scripts/p3_panic.sh              stop + disable, force ATT
#   sudo ./scripts/p3_panic.sh --uninstall  also delete the P3 files
unset TMOUT
set -uo pipefail   # no -e: do every step even if one fails
PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/sbin:/usr/local/bin
say() { printf '[%s] %s\n' "$(date +%T)" "$*"; }
[[ $(id -u) -eq 0 ]] || { echo "needs root: sudo $0 $*" >&2; exit 1; }
case "${1:-}" in ""|--uninstall) ;; *) echo "usage: sudo $0 [--uninstall]" >&2; exit 2 ;; esac

# 1. Nothing may switch routes behind our back: cron first, then the probes.
rm -f /etc/cron.d/wan-failover && say "removed cron entry"
sysrc -q wan_failover_enable=NO >/dev/null && say "rc.conf: wan_failover_enable=NO (stays off after reboot)"
service wan_failover onestop >/dev/null 2>&1
pkill -f 'dpinger .*-i (att|tmo)_' && say "killed dpinger probes"
pkill -f 'wan-failover' 2>/dev/null
rm -f /var/run/dpinger_{att,tmo}_*.{sock,pid}

# 2. Back to ATT: state file gone (= att) so the ATT dhclient owns FIB 0 again.
rm -f /var/run/wan_state /var/run/wan_att_ok_since /var/run/wan_last_change
att_gw="$(cat /var/db/att_router 2>/dev/null)"
att_gw="${att_gw:-203.0.113.1}"
route -n add -fib 0 default "$att_gw" >/dev/null 2>&1 ||
	route -n change -fib 0 default "$att_gw" >/dev/null 2>&1
say "FIB 0 default -> $att_gw (ixl0)"

# 3. Drop LAN states NATed via TMO; restore the ATT-only extras.
for net in $(pfctl -q -t nat_approved_wide -T show 2>/dev/null | /usr/bin/grep -v '^ *!'); do
	pfctl -q -k nat -k "$net" >/dev/null 2>&1
done
for neg in $(pfctl -q -t nat_approved_wide -T show 2>/dev/null | /usr/bin/grep '^ *!'); do
	pfctl -q -t nat_approved_wide -T delete "$neg" >/dev/null 2>&1 && say "unblocked $neg"
done
if service miniupnpd enabled 2>/dev/null; then service miniupnpd start >/dev/null 2>&1; fi
unbound-control flush_infra all >/dev/null 2>&1
blink1-tool -q --off >/dev/null 2>&1

if [[ ${1:-} == --uninstall ]]; then
	rm -f /usr/local/sbin/wan-failover /usr/local/etc/rc.d/wan_failover
	sysrc -q -x wan_failover_enable >/dev/null 2>&1
	say "deleted wan-failover, its rc.d script and rc.conf line"
fi

# 4. Show where we ended up.
echo "----- result -----"
route -n get default | /usr/bin/grep -E 'gateway|interface'
pgrep -lf dpinger || echo "no dpinger running"
if ping -c 3 -t 5 1.1.1.1 >/dev/null 2>&1; then say "OK: internet via ATT"
else say "STILL NO INTERNET via ATT: check the fiber/WAS-110 (ping 192.168.11.1), not the controller"; fi
