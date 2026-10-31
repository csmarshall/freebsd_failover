#!/bin/sh
# Unprivileged tests for the WAN dhclient hooks. Loads the stock function
# definitions from /sbin/dhclient-script (everything above "Start of active
# code"), then our hooks on top, with route/ifconfig stubbed to a call log.
#
# The only transform applied to the files under test: the absolute
# /etc/dhclient-scripts/ path inside the enter hooks is rewritten to this
# repo's copy, so the repo version (not the live one) is what gets sourced.
#
# Usage: tests/test_hooks.sh
unset TMOUT
set -u

REPO=$(cd "$(dirname "$0")/.." && pwd)
SRC="$REPO/router/etc/dhclient-scripts"
STOCK=/sbin/dhclient-script
fails=0
passes=0

check() { # check <description> <command...>
	_d=$1; shift
	if "$@"; then passes=$((passes + 1)); echo "ok   - $_d"
	else fails=$((fails + 1)); echo "FAIL - $_d"; fi
}

# run_case <role-iface> <state|-> <fake-default-if|-> <reason> <use-our-hooks:yes|no> <snippet>
# Runs <snippet> in a fresh sh with stubs; prints the route call log.
run_case() {
	_if=$1 _state=$2 _defif=$3 _reason=$4 _ours=$5 _snippet=$6
	_t=$(mktemp -d)
	[ "$_state" != "-" ] && echo "$_state" > "$_t/wan_state"
	sed "s|/etc/dhclient-scripts/|$SRC/|" "$SRC/dhclient-${_if}-enter-hooks" > "$_t/enter"
	# Exit hook: also neutralise set_gateway_entries.sh (it writes /etc/hosts;
	# these tests are about routes and addresses only).
	sed -e "s|/etc/dhclient-scripts/set_gateway_entries.sh|true|" \
	    -e "s|/etc/dhclient-scripts/|$SRC/|" "${EXIT_HOOK:-$SRC/dhclient-${_if}-exit-hooks}" > "$_t/exit"
	sed -n '1,/^# Start of active code/p' "$STOCK" > "$_t/stock_funcs"
	cat > "$_t/run" <<EOF
route() {
	echo "route \$*" >> "$_t/calls"
	case "\$*" in
	*"get -inet default"*) [ "$_defif" != "-" ] && echo "  interface: $_defif" ;;
	esac
	return 0
}
ifconfig() { echo "ifconfig \$*" >> "$_t/calls"; }
pfctl() { echo "pfctl \$*" >> "$_t/calls"; }
ping() { # all-routers probe: \${PING_REPLY:-} is the router that answers
	echo "ping \$*" >> "$_t/calls"
	[ -n "\${PING_REPLY:-}" ] && echo "16 bytes from \$PING_REPLY, icmp_seq=0 hlim=64 time=0.5 ms"
	return 0
}
arp() { :; }
. "$_t/stock_funcs"
IFCONFIG=ifconfig   # stock sets /sbin/ifconfig -n; use the stub
LOGGER=:
interface=$_if
reason=$_reason
new_routers="192.0.2.1"
new_ip_address="192.0.2.50"
new_subnet_mask="255.255.255.0"
WAN_STATE_FILE="$_t/wan_state"
WAN_DB_DIR="$_t"
WAN_FAILOVER=/nonexistent
WAN_PFCTL=pfctl
[ "$_ours" = yes ] && . "$_t/enter"
$_snippet
EOF
	sh "$_t/run" > "$_t/out" 2>&1
	cat "$_t/out"
	cat "$_t/calls" 2>/dev/null
	[ -f "$_t/bak_router" ] && echo "db bak_router=$(cat "$_t/bak_router")"
	[ -f "$_t/pri_router" ] && echo "db pri_router=$(cat "$_t/pri_router")"
	rm -rf "$_t"
}

has() { printf '%s\n' "$1" | grep -c -e "$2" | grep -qv '^0$'; }
lacks() { ! has "$1" "$2"; }

# is_default_interface ownership
o=$(run_case ixl0 - - BOUND yes 'is_default_interface && echo OWNER || echo NOT')
check "pri owns FIB 0 when no state file" has "$o" '^OWNER$'
o=$(run_case ix0 - - BOUND yes 'is_default_interface && echo OWNER || echo NOT')
check "bak does not own FIB 0 when no state file" has "$o" '^NOT$'
o=$(run_case ixl0 bak ix0 BOUND yes 'is_default_interface && echo OWNER || echo NOT')
check "pri does not own FIB 0 when state=bak" has "$o" '^NOT$'
o=$(run_case ix0 bak ix0 BOUND yes 'is_default_interface && echo OWNER || echo NOT')
check "bak owns FIB 0 when state=bak" has "$o" '^OWNER$'

# Stock add_new_routes during a primary outage (no default route anywhere)
o=$(run_case ix0 - - BOUND yes 'add_new_routes')
check "with our hooks: bak lease during outage adds NO FIB 0 default" lacks "$o" '^route add default'
o=$(run_case ix0 - - BOUND no 'add_new_routes')
check "known-bad (stock, no hooks): bak lease during outage DOES add FIB 0 default" has "$o" '^route add default 192.0.2.1'
o=$(run_case ixl0 - ixl0 BOUND yes 'add_new_routes')
check "pri in normal state still installs FIB 0 default" has "$o" '^route add default 192.0.2.1'

# wan_exit: probe FIB maintenance
o=$(run_case ix0 - - BOUND yes 'wan_exit')
check "bak BOUND sets FIB 2 gateway host route" has "$o" 'add -fib 2 -host 192.0.2.1 -interface ix0'
check "bak BOUND sets FIB 2 default" has "$o" 'add -fib 2 default 192.0.2.1'
check "bak BOUND records router" has "$o" '^db bak_router=192.0.2.1$'
check "bak BOUND never touches a route without -fib" lacks "$o" '^route -n add default'
o=$(run_case ixl0 - ixl0 RENEW yes 'wan_exit')
check "pri RENEW sets FIB 1 default" has "$o" 'add -fib 1 default 192.0.2.1'
o=$(run_case ix0 - - EXPIRE yes 'wan_exit')
check "bak EXPIRE removes FIB 2 default" has "$o" 'delete -fib 2 default'

# pf NAT tables follow the lease (pf.conf NATs to <pri_addr>/<bak_addr>, not
# (if:0), because the rc.conf mgmt alias can be the first address after boot).
o=$(run_case ix0 - - BOUND yes 'wan_exit')
check "bak BOUND sets pf table bak_addr to the lease address" has "$o" '^pfctl -q -t bak_addr -T replace 192.0.2.50$'
o=$(run_case ixl0 - ixl0 REBOOT yes 'wan_exit')
check "pri REBOOT sets pf table pri_addr to the lease address" has "$o" '^pfctl -q -t pri_addr -T replace 192.0.2.50$'
o=$(run_case ix0 - - EXPIRE yes 'wan_exit')
check "bak EXPIRE leaves the pf table alone" lacks "$o" '^pfctl'

# BACKUP's IPv6 default in FIB 2 follows the CPE's router address, found by
# pinging all-routers (ff02::2) on ix0; the hooks never hard-code it.
o=$(export PING_REPLY="fe80::1:2%ix0"; run_case ix0 - - BOUND yes 'wan_exit; wait')
check "bak BOUND sets FIB 2 IPv6 default via the discovered router" has "$o" '^route -6 -n add -fib 2 default fe80::1:2%ix0$'
o=$(run_case ix0 - - BOUND yes 'wan_exit; wait')
check "bak BOUND with no router reply leaves FIB 2 IPv6 alone" lacks "$o" '^route -6'
o=$(export PING_REPLY="fe80::1:2%ixl0"; run_case ixl0 - ixl0 BOUND yes 'wan_exit; wait')
check "pri BOUND never touches IPv6 routes (dhcp6c owns PRIMARY IPv6)" lacks "$o" '^route -6'

# Lease addresses are added as aliases so rc.conf management aliases survive.
for i in ixl0 ix0; do
	o=$(run_case "$i" - - BOUND yes 'add_new_address')
	check "$i lease address is added with alias (keeps mgmt alias)" has "$o" "^ifconfig $i.*inet 192.0.2.50 .* alias\$"
done
o=$(run_case ix0 - - BOUND no 'add_new_address')
stock_replaces() { has "$1" '^ifconfig ix0.*inet 192.0.2.50 ' && lacks "$1" ' alias$'; }
check "known-bad (stock): lease address replaces first address (no alias)" stock_replaces "$o"
o=$(run_case ix0 - - BOUND yes 'old_ip_address=192.0.2.40; delete_old_address')
check "delete_old_address removes only the old lease address" has "$o" '^ifconfig ix0 inet -alias 192.0.2.40'

# ONT management path is rc.conf-owned; no DHCP event may touch it.
for r in BOUND RENEW REBOOT EXPIRE FAIL; do
	o=$(run_case ixl0 - ixl0 "$r" yes '. "$(dirname "$WAN_STATE_FILE")/exit"')
	check "pri $r leaves 192.168.11.x routes/aliases alone" lacks "$o" '192\.168\.11\.'
done

echo "passed=$passes failed=$fails"
[ "$fails" -eq 0 ]
