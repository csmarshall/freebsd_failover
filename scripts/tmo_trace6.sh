#!/usr/local/bin/bash
# Find TMO's first hops past the TRB. IPv4 can't show them (the TRB's CLAT
# hides T-Mobile's IPv6-only network), so trace over IPv6 from ix0's current
# SLAAC address through FIB 2. Adds an IPv6 default to FIB 2 via the TRB's
# link-local address (FIB 2 is router's TMO probe table only: LAN traffic
# never uses it) and leaves it in place. Needs root.
unset TMOUT
set -uo pipefail   # no -e: report every trace
. "$(dirname "$0")/lib.sh"
[[ $(id -u) -eq 0 ]] || die "needs root: sudo $0"

TRB_LL="fe80::200:5eff:fe00:5301%ix0"
TARGETS=(2001:4860:4860::8888 2606:4700:4700::1111 2620:fe::fe)

# Newest non-deprecated global address on ix0 (T-Mobile rotates the /64).
src="$(ifconfig ix0 inet6 | awk '$1 == "inet6" && $2 ~ /^2/ && !/deprecated/ { a = $2 } END { print a }')"
[[ -n $src ]] || die "ix0 has no usable global IPv6 address"
say "source $src"

route -6 -n add -fib 2 default "$TRB_LL" >/dev/null 2>&1 ||
	route -6 -n change -fib 2 default "$TRB_LL" >/dev/null 2>&1
netstat -rn -F 2 -f inet6

hr "FIB 2 IPv6 reachability"
for t in "${TARGETS[@]}"; do
	setfib 2 ping -6 -c 3 -S "$src" "$t" | tail -2
done

for t in "${TARGETS[@]}"; do
	hr "traceroute6 $t (FIB 2)"
	setfib 2 traceroute6 -n -w 2 -q 2 -m 12 -s "$src" "$t"
done
