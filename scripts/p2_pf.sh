#!/usr/local/bin/bash
# P2: pf for two uplinks. Installs router/etc/pf/pf.conf (PRIMARY/BACKUP macros,
# static NAT per uplink to the <pri_addr>/<bak_addr> tables, no inbound on
# BACKUP, ICMPv6 + DHCPv6 client on BACKUP, BACKUP MSS clamp) and the wan-lib.sh that
# keeps those tables current. Loads with `pfctl -f` (never -F), keeps the
# fail2ban and ip6_gua tables, checks the LAN IPv6 isolation invariant, and
# reverts pf.conf automatically if FIB 0 internet or PRIMARY NAT breaks.
#
# Dry run needs root too (pfctl -n and radvd.conf are root-only), but only
# reads: candidates are built in a temp dir.
unset TMOUT
set -euo pipefail
. "$(dirname "$0")/lib.sh"

usage() {
	cat <<EOF
Usage: sudo $0 [--apply]
  (no args)  dry run: tests, diffs, pfctl -n, isolation + MTU checks; touches nothing
  --apply    back up to $BACKUP_DIR, install, load, verify (auto-revert on failure)
EOF
}
parse_mode "${1:-}"
[[ $(id -u) -eq 0 ]] || die "needs root even for the dry run (pfctl -n, radvd.conf): sudo $0"

PF_CONF=/etc/pf/pf.conf
WANLIB=/etc/dhclient-scripts/wan-lib.sh
RADVD_CONF=/usr/local/etc/radvd.conf
# LAN IPv6 isolation: radvd may only ever advertise PRIMARY PD and the house ULA.
LAN_V6_ALLOWED='^(2001:db8:|fd00:1234:5678:)'
KEEP_TABLES=(fail2ban ip6_gua_lan ip6_gua_iot ip6_gua_guest ip6_gua_all)
BACKUP_MSS=$(sed -n 's/^bak_mss="\([0-9]*\)".*/\1/p' "$REPO/router/etc/pf/pf.conf")
[[ -n $BACKUP_MSS ]] || die "bak_mss macro not found in repo pf.conf"

hr "hook tests"
sh "$REPO/tests/test_hooks.sh" || die "hook tests failed; not installing"

STAGE="$(mktemp -d -t p2)"
trap 'rm -rf "$STAGE"' EXIT

for f in /var/db/pri_ip /var/db/bak_ip; do
	[[ -e $f ]] || die "$f missing: pf.conf loads <..._addr> from it and would fail to load"
	[[ -s $f ]] || say "WARNING: $f is empty; that uplink's NAT table starts empty"
done

# rc.conf: move the CPE alias (sysrc appended it in P1) next to the ix0 lines.
cp /etc/rc.conf "$STAGE/rc.conf"
alias_line="$(/usr/bin/grep '^ifconfig_ix0_alias0=' /etc/rc.conf || true)"
if [[ -n $alias_line ]]; then
	awk -v a="$alias_line" '$0 == a { next } { print } /^ifconfig_ix0_ipv6=/ { print a }' \
		/etc/rc.conf > "$STAGE/rc.conf"
	[[ $(/usr/bin/grep -c '^ifconfig_ix0_alias0=' "$STAGE/rc.conf") -eq 1 ]] ||
		die "rc.conf alias move went wrong; not continuing"
fi

hr "/etc/rc.conf"; show_diff /etc/rc.conf "$STAGE/rc.conf"
hr "$WANLIB"; show_diff "$WANLIB" "$REPO/router/etc/dhclient-scripts/wan-lib.sh"
hr "$PF_CONF"; show_diff "$PF_CONF" "$REPO/router/etc/pf/pf.conf"

hr "pfctl -n (parse only)"
pfctl -nf "$REPO/router/etc/pf/pf.conf" || die "new pf.conf does not parse"
say "PASS new pf.conf parses"

# --- LAN IPv6 isolation -------------------------------------------------------
# Prints every prefix/route/RDNSS address radvd would advertise that is not
# allowed; empty output = clean.
radvd_leaks() {
	awk '$1 == "prefix" || $1 == "route" { print $2 }
	     $1 == "RDNSS" { for (i = 2; i <= NF && $i != "{"; i++) print $i }' "$1" |
		/usr/bin/grep -Ev "$LAN_V6_ALLOWED" || true
}
radvd_selftest() { # the detector must flag a BACKUP prefix and pass a clean file
	local bad="$STAGE/radvd.bad" good="$STAGE/radvd.good"
	printf 'interface ix2 {\n prefix 2001:db8:5130:0::/64 { };\n prefix 3fff:b0:0:1::/64 { };\n RDNSS fd00:db8:1::1 { };\n};\n' > "$bad"
	printf 'interface ix2 {\n prefix 2001:db8:5130:0::/64 { };\n prefix fd00:1234:5678:1::/64 { };\n RDNSS fd00:1234:5678:1::1 2001:db8:5130:0::1 { };\n};\n' > "$good"
	[[ $(radvd_leaks "$bad" | wc -l) -eq 2 && -z $(radvd_leaks "$good") ]]
}
isolation_checks() {
	local ok=0 leaks bridges v6if
	if radvd_selftest; then say "PASS radvd leak detector self-test (flags a BACKUP prefix + RDNSS, passes clean)"
	else say "FAIL radvd leak detector self-test"; ok=1; fi
	leaks="$(radvd_leaks "$RADVD_CONF")"
	if [[ -z $leaks ]]; then say "PASS $RADVD_CONF advertises only PRIMARY PD + house ULA"
	else say "FAIL $RADVD_CONF advertises non-LAN IPv6: $(echo $leaks)"; ok=1; fi
	bridges=0
	for b in $(ifconfig -l); do
		case $b in bridge*) [[ $(ifconfig "$b" | /usr/bin/grep -c 'member: ix0 ') -gt 0 ]] && bridges=1 ;; esac
	done
	if [[ $bridges -eq 0 ]]; then say "PASS ix0 is in no bridge"; else say "FAIL ix0 is a bridge member"; ok=1; fi
	v6if="$(route -6 -n get default 2>/dev/null | awk '$1 == "interface:" { print $2 }')"
	if [[ $v6if != ix0 ]]; then say "PASS FIB 0 IPv6 default is not via ix0 (${v6if:-none})"
	else say "FAIL FIB 0 IPv6 default is via ix0"; ok=1; fi
	return $ok
}
hr "LAN IPv6 isolation (before)"
isolation_checks || die "isolation invariant already broken; fix before P2"

# --- BACKUP IPv4 path MTU ----------------------------------------------------------
hr "BACKUP IPv4 path MTU (FIB 2, DF set, from $(cat /var/db/bak_ip))"
bak_mtu=""
for s in 1472 1452 1444 1432 1424 1412 1400 1372; do
	if setfib 2 ping -D -c 2 -t 4 -S "$(cat /var/db/bak_ip)" -s "$s" 1.1.1.1 >/dev/null 2>&1; then
		bak_mtu=$((s + 28)); echo "payload $s ok (MTU $bak_mtu)"; break
	fi
	echo "payload $s too big or lost"
done
if [[ -z $bak_mtu ]]; then say "WARNING: no DF size got through; MSS $BACKUP_MSS unverified"
elif (( bak_mtu - 40 < BACKUP_MSS )); then say "WARNING: measured MTU $bak_mtu needs MSS <= $((bak_mtu - 40)); pf.conf bak_mss=$BACKUP_MSS"
else say "PASS bak_mss=$BACKUP_MSS fits measured IPv4 MTU $bak_mtu"; fi

if [[ $MODE != apply ]]; then
	say "dry run complete; re-run with --apply"
	exit 0
fi

# --- apply ----------------------------------------------------------------------
backup p2
cp "$PF_CONF" "$STAGE/pf.conf.orig"
for t in "${KEEP_TABLES[@]}"; do
	pfctl -q -t "$t" -T show > "$STAGE/table.$t" 2>/dev/null || : > "$STAGE/table.$t"
done
restore_tables() {
	local t before after
	for t in "${KEEP_TABLES[@]}"; do
		before=$(wc -l < "$STAGE/table.$t" | tr -d ' ')
		after=$(pfctl -q -t "$t" -T show 2>/dev/null | wc -l | tr -d ' ')
		if (( after < before )); then
			pfctl -q -t "$t" -T add -f "$STAGE/table.$t"
			say "restored table $t ($after -> $(pfctl -q -t "$t" -T show | wc -l | tr -d ' ') entries, was $before)"
		else
			say "table $t kept ($after entries, was $before)"
		fi
	done
}
revert() {
	say "REVERTING pf.conf: $1"
	install -m 0644 -o root -g wheel "$STAGE/pf.conf.orig" "$PF_CONF"
	pfctl -f "$PF_CONF"
	restore_tables
	die "P2 reverted (wan-lib.sh and rc.conf left installed; harmless with the old pf.conf)"
}

install -m 0644 -o root -g wheel "$STAGE/rc.conf" /etc/rc.conf
install -m 0644 -o root -g wheel "$REPO/router/etc/dhclient-scripts/wan-lib.sh" "$WANLIB"
install -m 0644 -o root -g wheel "$REPO/router/etc/pf/pf.conf" "$PF_CONF"
say "installed rc.conf, $WANLIB, $PF_CONF"
pfctl -f "$PF_CONF" || revert "pfctl -f failed"
say "loaded $PF_CONF"
restore_tables

hr "verify"
fails=0
pass() { say "PASS $*"; }
fail() { say "FAIL $*"; fails=$((fails + 1)); }

for r in pri bak; do
	want="$(cat /var/db/${r}_ip)"
	have="$(pfctl -q -t ${r}_addr -T show | tr -d ' ')"
	if [[ $have == "$want" ]]; then pass "<${r}_addr> = $want"; else fail "<${r}_addr> = '$have', want '$want'"; fi
done
nat_rules="$(pfctl -sn)"
for want in "nat on ixl0 inet from <nat_approved_wide> to any -> <pri_addr>" \
            "nat on ix0 inet from <nat_approved_wide> to any -> <bak_addr>" \
            "to 192.168.11.1 -> 192.168.11.2" "to 192.168.12.1 -> 192.168.12.2"; do
	if [[ $(printf '%s\n' "$nat_rules" | /usr/bin/grep -cF -- "$want") -gt 0 ]]; then pass "nat rule: $want"
	else fail "nat rule missing: $want"; fi
done
filter_rules="$(pfctl -sr)"
if [[ $(printf '%s\n' "$filter_rules" | /usr/bin/grep -c 'pass in .*on ix0 .*proto tcp') -eq 0 ]]; then pass "no inbound TCP passes on ix0"
else fail "inbound TCP pass still on ix0"; fi

# States created by the NEW PRIMARY NAT rule (counters reset on load) prove LAN
# traffic is being translated by it.
pri_nat_states() {
	local out; out="$(pfctl -vsn)"
	awk 'hit && /States:/ { for (i = 1; i <= NF; i++) if ($i == "States:") n = $(i + 1); hit = 0 }
	     index($0, "-> <pri_addr>") { hit = 1 }
	     END { print n + 0 }' <<<"$out"
}
n=0
for _ in $(seq 1 30); do n=$(pri_nat_states); (( n > 0 )) && break; sleep 1; done
if (( n > 0 )); then pass "PRIMARY NAT rule translating LAN traffic ($n states)"; else fail "PRIMARY NAT rule has created no states in 30s"; fi

if ping -c 3 -t 5 1.1.1.1 >/dev/null 2>&1; then pass "FIB 0 reaches 1.1.1.1"; else fail "FIB 0 cannot reach 1.1.1.1"; fi
pub="$(curl -4 -s -m 8 https://1.1.1.1/cdn-cgi/trace | sed -n 's/^ip=//p')"
if [[ $pub == "$(cat /var/db/pri_ip)" ]]; then pass "FIB 0 public IPv4 $pub (PRIMARY)"; else fail "FIB 0 public IPv4 '$pub'"; fi

if (( fails > 0 )); then revert "$fails core check(s) failed"; fi

# Non-core: management paths, BACKUP probe path, IPv6 on ix0.
if ping -c 2 -t 4 -S 192.168.11.2 192.168.11.1 >/dev/null 2>&1; then pass "ONT 192.168.11.1 from 192.168.11.2"; else fail "ONT unreachable from 192.168.11.2"; fi
if ping -c 2 -t 4 -S 192.168.12.2 192.168.12.1 >/dev/null 2>&1; then pass "CPE 192.168.12.1 from 192.168.12.2"; else fail "CPE unreachable from 192.168.12.2"; fi
if setfib 2 ping -c 3 -t 8 -S "$(cat /var/db/bak_ip)" 1.1.1.1 >/dev/null 2>&1; then pass "FIB 2 reaches 1.1.1.1 via BACKUP"; else fail "FIB 2 cannot reach 1.1.1.1"; fi

rtsol ix0 || true
v6=""
for _ in $(seq 1 15); do
	v6="$(ifconfig ix0 inet6 | awk '$1 == "inet6" && $2 !~ /^fe80/ { print $2 }' | tr '\n' ' ')"
	[[ -n $v6 ]] && break; sleep 1
done
say "INFO ix0 IPv6 after RA: ${v6:-none yet} (CPE routers: $(ndp -rn | /usr/bin/grep -c ix0))"

hr "LAN IPv6 isolation (after RA on ix0)"
isolation_checks || fails=$((fails + 1))

say "P2 applied with $fails non-core failure(s)."
say "Check from the LAN: browsing, https://192.168.12.1 (CPE), ONT UI."
say "Rollback: sudo $REPO/scripts/rollback.sh $(cat "$BACKUP_DIR/LATEST-p2") --apply && sudo pfctl -f $PF_CONF"
