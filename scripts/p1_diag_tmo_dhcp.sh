#!/usr/local/bin/bash
# Read-only: why is the Teltonika not answering DHCPv4 on ix0?
# Captures DHCP traffic on ix0 while dhclient is retrying, and lists pf blocks
# logged on ix0. Needs root (bpf, /var/log/pflog).
unset TMOUT
set -uo pipefail
. "$(dirname "$0")/lib.sh"
[[ $(id -u) -eq 0 ]] || die "needs root: sudo $0"

hr "DHCP on ix0 for 40s (expect our DISCOVER; any OFFER from 192.168.12.1?)"
timeout 40 tcpdump -n -e -v -l -i ix0 'udp port 67 or udp port 68' 2>&1
hr "all non-IPv6 frames from the Teltonika MAC for 10s (is it speaking IPv4/ARP at all?)"
timeout 10 tcpdump -n -e -l -i ix0 'ether src 00:00:5e:00:53:01 and not ip6' 2>&1
hr "pf blocks logged on ix0 (last 30)"
tcpdump -n -e -r /var/log/pflog 2>/dev/null | grep -E 'on ix0' | tail -30
hr "pf live counters for ix0 block rule"
pfctl -vsr 2>/dev/null | grep -A2 'block return in quick on ix0 all'
say "diag done"
