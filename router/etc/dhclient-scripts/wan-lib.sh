# wan-lib.sh (installed as /etc/dhclient-scripts/wan-lib.sh)
#
# Shared by the PRIMARY (ixl0) and BACKUP (ix0) dhclient hooks. Sourced (POSIX sh)
# into /sbin/dhclient-script by the per-interface enter hook, which sets
# wan_role (pri|bak) and wan_fib (1|2) first.
#
# Invariant: FIB 0's default route belongs to /usr/local/sbin/wan-failover.
# A WAN's dhclient may touch FIB 0 only while the failover state names that
# WAN; otherwise it maintains only its own probe FIB.

: "${WAN_STATE_FILE:=/var/run/wan_state}"
: "${WAN_DB_DIR:=/var/db}"
: "${WAN_FAILOVER:=/usr/local/sbin/wan-failover}"
: "${WAN_PFCTL:=/sbin/pfctl}"
WAN_DEFAULT_ROLE=pri

wan_active_role() {
	if [ -s "$WAN_STATE_FILE" ]; then
		cat "$WAN_STATE_FILE"
	else
		echo "$WAN_DEFAULT_ROLE"
	fi
}

# Overrides dhclient-script's is_default_interface ("is the current default
# route on me?") with "does the failover state give FIB 0 to me?". The stock
# answer is also yes when there is NO default route, which is how a backup
# WAN steals FIB 0 during a primary outage.
is_default_interface() {
	[ "$(wan_active_role)" = "$wan_role" ]
}

# Overrides dhclient-script's add_new_address, which runs `ifconfig <if> inet
# <addr>` without `alias` and so REPLACES the interface's first address. After
# a lease change that first address is the rc.conf management alias
# (192.168.11.2 on ixl0 for the ONT, 192.168.12.2 on ix0 for the CPE), so
# the stock code would delete it. Adding as an alias leaves those to rc.conf;
# delete_old_address still removes only the old lease address.
add_new_address() {
	eval "$IFCONFIG $interface \
		inet $new_ip_address \
		netmask $new_subnet_mask \
		broadcast $new_broadcast_address \
		$medium alias"

	$LOGGER "New IP Address ($interface): $new_ip_address"
	$LOGGER "New Subnet Mask ($interface): $new_subnet_mask"
	$LOGGER "New Broadcast Address ($interface): $new_broadcast_address"
	$LOGGER "New Routers ($interface): $new_routers"
}

wan_first_router() {
	set -- $new_routers
	echo "${1:-}"
}

wan_fib_set_default() {
	_gw=$1
	# With net.add_addr_allfibs=0 the connected subnet exists only in FIB 0,
	# so make the gateway reachable in the probe FIB explicitly.
	route -n add -fib "$wan_fib" -host "$_gw" -interface "$interface" >/dev/null 2>&1 ||
	    route -n change -fib "$wan_fib" -host "$_gw" -interface "$interface" >/dev/null 2>&1
	route -n add -fib "$wan_fib" default "$_gw" >/dev/null 2>&1 ||
	    route -n change -fib "$wan_fib" default "$_gw" >/dev/null 2>&1
	$LOGGER "$wan_role: FIB $wan_fib default via $_gw ($interface, $reason)"
}

wan_fib_clear_default() {
	route -n delete -fib "$wan_fib" default >/dev/null 2>&1
	$LOGGER "$wan_role: FIB $wan_fib default removed ($interface, $reason)"
}

# pf.conf NATs each uplink to the table <${wan_role}_addr> rather than
# (if:0): after boot the rc.conf management alias is the interface's first
# address, so (if:0) would NAT the LAN to 192.168.11.2 / 192.168.12.2.
wan_pf_set_addr() {
	if ! "$WAN_PFCTL" -q -t "${wan_role}_addr" -T replace "$new_ip_address" >/dev/null 2>&1; then
		$LOGGER "$wan_role: pfctl -t ${wan_role}_addr -T replace $new_ip_address failed"
	fi
}

# BACKUP only (PRIMARY IPv6 belongs to dhcp6c): point FIB 2's IPv6 default at the
# CPE. ix0 is no_radr, so the kernel never records the RA's router; ask the
# all-routers group instead and take the first link-local that answers, so
# a replaced CPE is picked up on the next lease. Backgrounded: the ping can
# take a few seconds and dhclient-script waits for its hooks.
wan_fib_set_default6() {
	[ "$wan_role" = bak ] || return 0
	(
		_r6=$(ping -6 -c 2 -t 3 "ff02::2%$interface" 2>/dev/null |
			awk '/bytes from fe80:/ && !r { r = $4; sub(/,$/, "", r) } END { print r }')
		if [ -z "$_r6" ]; then
			$LOGGER "$wan_role: no IPv6 router answered on $interface; FIB $wan_fib IPv6 default unchanged"
			exit 0
		fi
		route -6 -n add -fib "$wan_fib" default "$_r6" >/dev/null 2>&1 ||
		    route -6 -n change -fib "$wan_fib" default "$_r6" >/dev/null 2>&1
		$LOGGER "$wan_role: FIB $wan_fib IPv6 default via $_r6"
	) &
}

# The active uplink's lease adds or replaces FIB 0's default through the stock
# dhclient-script code. With net.route.multipath=1 an add beside a default
# that has another gateway builds a two-path group instead of failing, so
# after a lease event on the active uplink remove every FIB 0 default that is
# not this lease's router. Only when this router is itself in FIB 0: pruning
# must never leave FIB 0 without a default. The inactive uplink never touches
# FIB 0 (wan-failover reconciles it every minute).
wan_fib0_prune() { # wan_fib0_prune <gateway>
	[ "$(wan_active_role)" = "$wan_role" ] || return 0
	_defaults=$(netstat -rn -4 -F 0 | awk '$1 == "default" { print $2 }')
	_mine=no
	for _g in $_defaults; do
		[ "$_g" = "$1" ] && _mine=yes
	done
	[ "$_mine" = yes ] || return 0
	for _g in $_defaults; do
		[ "$_g" = "$1" ] && continue
		route -n delete -fib 0 default "$_g" >/dev/null 2>&1
		$LOGGER "$wan_role: FIB 0 extra default via $_g removed ($interface, $reason)"
	done
}

# Called from the per-interface exit hook.
wan_exit() {
	case $reason in
	BOUND|RENEW|REBIND|REBOOT)
		_gw=$(wan_first_router)
		if [ -z "$_gw" ]; then
			$LOGGER "$wan_role: lease on $interface has no router"
			return 0
		fi
		_old_ip=$(cat "$WAN_DB_DIR/${wan_role}_ip" 2>/dev/null)
		echo "$_gw" > "$WAN_DB_DIR/${wan_role}_router"
		echo "$new_ip_address" > "$WAN_DB_DIR/${wan_role}_ip"
		wan_fib_set_default "$_gw"
		wan_fib0_prune "$_gw"
		wan_pf_set_addr
		wan_fib_set_default6
		# Probes bind to the WAN address; restart them when it changes (P3).
		if [ "$_old_ip" != "$new_ip_address" ] && [ -x "$WAN_FAILOVER" ]; then
			"$WAN_FAILOVER" probe-restart "$wan_role" >/dev/null 2>&1 &
		fi
		;;
	EXPIRE|FAIL|RELEASE|STOP)
		wan_fib_clear_default
		;;
	esac
}
