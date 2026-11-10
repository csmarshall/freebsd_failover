#!/usr/local/bin/bash
# Fixes for what the 2026-11-10 failover exposed:
#   1. FIB 0 ended with two default routes (multipath across both uplinks):
#      controller replaces routes path by path and reads the table back.
#   2. dhclient on the active uplink could add a second default: wan-lib.sh
#      prunes FIB 0 after its lease events.
#   3. IPv6 from router itself was sourced from the BACKUP address and sent to
#      PRIMARY: /etc/ip6addrctl.conf gives the 5G carrier's space its own label.
#   4. Transition pushes were lost silently: IPv4-only sender with time
#      limits (/usr/local/libexec/wan-notify), failures logged.
#   5. set_gateway_entries.sh replaces /etc/hosts atomically.
#   6. /var/log/network_failover.log is rotated.
#
# Independent of the CLAT phase 3+4 rollout: if clat_p34.sh has not been
# applied, the controller is installed with BACKUP_PROBE_PATH=clat4, so the
# probes stay exactly as they are now (checked below).
unset TMOUT
set -euo pipefail
. "$(dirname "$0")/lib.sh"

usage() {
	cat <<EOF
Usage: $0 [--apply]
  (no args)  dry run: tests, diffs, read-only checks of the live state; touches nothing
  --apply    back up to $BACKUP_DIR, run the live route test, install, verify (needs root)
EOF
}
parse_mode "${1:-}"

CTL=/usr/local/sbin/wan-failover
NOTIFIER=/usr/local/libexec/wan-notify
NOTIFY_CONF=/usr/local/etc/wan-notify.conf
OLD_SENDER=/usr/local/bin/pushover_message.sh   # the credentials are copied from here
POLICY=/etc/ip6addrctl.conf
BACKUP_IF=ix0
BACKUP_LABEL=14   # the label router/etc/ip6addrctl.conf gives the 5G carrier's space
V6_PROBE_DSTS="2606:4700:4700::1111 2001:4860:4860::8888 2620:fe::fe"
PUSHOVER_HOST=api.pushover.net
declare -A FILES=(
	[$CTL]=0755
	[/etc/dhclient-scripts/wan-lib.sh]=0644
	[/etc/dhclient-scripts/set_gateway_entries.sh]=0755
	[$NOTIFIER]=0555
	[$POLICY]=0644
	[/usr/local/etc/newsyslog.conf.d/wan-failover.conf]=0644
)

# Install order: the sender before the controller that calls it.
INSTALL_ORDER=(
	"$NOTIFIER"
	/etc/dhclient-scripts/set_gateway_entries.sh
	/usr/local/etc/newsyslog.conf.d/wan-failover.conf
	"$POLICY"
	"$CTL"
	/etc/dhclient-scripts/wan-lib.sh
)
(( ${#INSTALL_ORDER[@]} == ${#FILES[@]} )) || die "INSTALL_ORDER and FILES disagree"

STAGE="$(mktemp -d -t p3fixes)"
trap 'rm -rf "$STAGE"' EXIT
mkdir "$STAGE/run"
fails=0
pass() { say "PASS $*"; }
fail() { say "FAIL $*"; fails=$((fails + 1)); }

# --- the controller build to install ---------------------------------------------
# The source tree's controller already carries the unapplied CLAT phase 4
# probe change (BACKUP probed over NAT64 from bak-clat's alias). Until
# clat_p34.sh has been applied, install it with the old probe path.
CAND="$STAGE/wan-failover"
if [[ $(/usr/bin/grep -c '^BACKUP_PROBE_PATH=nat64$' "$CTL" 2>/dev/null) -eq 1 ]]; then
	cp "$REPO/router$CTL" "$CAND"
	say "live controller is the CLAT phase 4 build: installing the source as is"
else
	sed 's/^BACKUP_PROBE_PATH=nat64$/BACKUP_PROBE_PATH=clat4/' "$REPO/router$CTL" > "$CAND"
	[[ $(/usr/bin/grep -c '^BACKUP_PROBE_PATH=clat4$' "$CAND") -eq 1 ]] || die "could not set BACKUP_PROBE_PATH=clat4 in the candidate"
	say "CLAT phase 3+4 not applied: candidate keeps the current IPv4 BACKUP probes (BACKUP_PROBE_PATH=clat4)"
fi
chmod 0755 "$CAND"
src_for() { if [[ $1 == "$CTL" ]]; then echo "$CAND"; else echo "$REPO/router$1"; fi; }

hr "tests"
sh "$REPO/tests/test_hooks.sh" >/dev/null || die "hook tests failed"
sh "$REPO/tests/test_failover.sh" >/dev/null || die "controller tests failed"
sh "$REPO/tests/test_gateway_entries.sh" >/dev/null || die "set_gateway_entries tests failed"
sh "$REPO/tests/test_fixes.sh" >/dev/null || die "fix tests (source, with mutation pass) failed"
sh "$REPO/tests/test_fixes.sh" "$CAND" "$REPO/router$NOTIFIER" | tail -1 || die "fix tests failed on the candidate"
say "all suites pass, including on the exact controller file to be installed"

hr "probe commands: live controller vs candidate (must be identical)"
probes_of() { WF_DRYRUN=1 WF_RUN="$STAGE/run" "$1" start 2>&1 >/dev/null | /usr/bin/grep 'dpinger' || true; }
probes_of "$CTL" > "$STAGE/probes.live"
probes_of "$CAND" > "$STAGE/probes.cand"
if [[ -s $STAGE/probes.live ]] && cmp -s "$STAGE/probes.live" "$STAGE/probes.cand"; then
	say "identical ($(wc -l < "$STAGE/probes.live" | tr -d ' ') dpinger commands): running probes need no restart"
else
	diff -u "$STAGE/probes.live" "$STAGE/probes.cand" || true
	die "the candidate would start different probes than the live controller; not installing"
fi

hr "diffs"
for live in "${!FILES[@]}"; do
	hr "$live"; show_diff "$live" "$(src_for "$live")"
done

# --- read-only checks of the live state ------------------------------------------
hr "FIB 0 IPv4 defaults now"
netstat -rn -4 -F 0 | awk '$1 == "default"'
n_def=$(netstat -rn -4 -F 0 | awk '$1 == "default"' | /usr/bin/grep -c . || true)
if (( n_def == 1 )); then say "one default"; else say "NOTE: $n_def defaults; the first evaluate after install should reduce this to one"; fi

hr "IPv6 source address router picks now (no packets sent)"
BACKUP_PREFIX=$(awk -v l="$BACKUP_LABEL" '$1 !~ /^#/ && $3 == l { print $1 }' "$REPO/router$POLICY")
[[ -n $BACKUP_PREFIX ]] || die "no label $BACKUP_LABEL line in $REPO/router$POLICY"
# Prints "<dst> <src> bak|other" per destination; bak = source is in the 5G carrier space.
v6_sources() {
	python3 - "$BACKUP_PREFIX" $V6_PROBE_DSTS <<'PY'
import ipaddress, socket, sys
net = ipaddress.ip_network(sys.argv[1])
for dst in sys.argv[2:]:
    s = socket.socket(socket.AF_INET6, socket.SOCK_DGRAM)
    try:
        s.connect((dst, 53))
        src = s.getsockname()[0]
        print(dst, src, "bak" if ipaddress.ip_address(src) in net else "other")
    except OSError as e:
        print(dst, "-", "error:%s" % e.strerror)
    finally:
        s.close()
PY
}
v6_sources | tee "$STAGE/v6.before"
if [[ $(/usr/bin/grep -c ' bak$' "$STAGE/v6.before" || true) -gt 0 ]]; then
	say "known-bad confirmed: the BACKUP address is chosen for traffic that leaves PRIMARY"
else
	say "the BACKUP address is not being chosen right now"
fi
bak_addrs=$(ifconfig "$BACKUP_IF" | awk '$1 == "inet6" && $2 !~ /^(fe80|fd|fc)/ { print $2 }')
[[ -n $bak_addrs ]] || say "NOTE: $BACKUP_IF has no global IPv6 address right now"
for a in $bak_addrs; do
	if python3 -c "import ipaddress,sys; sys.exit(0 if ipaddress.ip_address(sys.argv[1]) in ipaddress.ip_network(sys.argv[2]) else 1)" "$a" "$BACKUP_PREFIX"; then
		say "$BACKUP_IF address $a is inside $BACKUP_PREFIX"
	else
		die "$BACKUP_IF address $a is OUTSIDE $BACKUP_PREFIX: the policy line would not cover it; fix router$POLICY first"
	fi
done

hr "notification path"
if curl -4 -s -o /dev/null --connect-timeout 8 --max-time 15 "https://$PUSHOVER_HOST/"; then say "IPv4 HTTPS to $PUSHOVER_HOST works"
else say "NOTE: IPv4 HTTPS to $PUSHOVER_HOST failed just now"; fi
# Credentials for the new sender come from the old one; values are never printed.
cred() { awk -v f="$1" '{ for (i = 1; i < NF; i++) if ($i == f) { v = $(i + 1); gsub(/["\\]/, "", v); print v; exit } }' "$OLD_SENDER" 2>/dev/null; }
if [[ -s $NOTIFY_CONF ]]; then
	say "$NOTIFY_CONF exists: kept as is"
else
	[[ -n $(cred -u) && -n $(cred -t) ]] || die "cannot find -u/-t credentials in $OLD_SENDER to create $NOTIFY_CONF"
	say "$NOTIFY_CONF will be created (root, 0600) from the user and token in $OLD_SENDER"
fi

hr "/etc/hosts: what the new set_gateway_entries.sh would change (run on a copy)"
cp /etc/hosts "$STAGE/hosts"
preview() { SGE_HOSTS="$STAGE/hosts" SGE_LOCK="$STAGE/sge.lock" SGE_LOGGER=true \
	/usr/local/bin/bash "$REPO/router/etc/dhclient-scripts/set_gateway_entries.sh" "$@"; }
preview "$(cat /var/db/pri_router)" "gateway-pri.localhost gateway.localhost"
preview "$(cat /var/db/bak_router)" "gateway-bak.localhost gateway-backup.localhost" allow-private
diff -u /etc/hosts "$STAGE/hosts" && say "no change: every gateway name is already correct" || true

hr "log rotation entry"
newsyslog -nv -f "$REPO/router/usr/local/etc/newsyslog.conf.d/wan-failover.conf" 2>&1 | sed 's/^/    /'

if [[ $MODE != apply ]]; then
	say "dry run complete, nothing changed. Next: sudo $0 --apply"
	say "--apply first runs tests/test_route_live.sh as root (a scratch route for TEST-NET-2 in FIB 0, removed again) and installs nothing if it fails"
	exit 0
fi

# --- apply -------------------------------------------------------------------------
hr "live route test (root, real routing table, before anything is installed)"
/usr/local/bin/bash "$REPO/tests/test_route_live.sh" "$CAND" || die "live route test failed; nothing installed"

backup p3fixes
had_policy=no; [[ -e $POLICY ]] && had_policy=yes
# Credentials first, so the sender never exists without them.
if [[ ! -s $NOTIFY_CONF ]]; then
	( umask 077; printf 'PUSHOVER_USER=%s\nPUSHOVER_TOKEN=%s\n' "$(cred -u)" "$(cred -t)" > "$NOTIFY_CONF" )
	chown root:wheel "$NOTIFY_CONF"; chmod 0600 "$NOTIFY_CONF"
	say "created $NOTIFY_CONF (0600)"
fi
for live in "${INSTALL_ORDER[@]}"; do
	mkdir -p "$(dirname "$live")"
	# -S: write a temp file and rename, so a cron evaluate never reads half a script.
	install -S -m "${FILES[$live]}" -o root -g wheel "$(src_for "$live")" "$live" ||
		die "installing $live failed; files before it in the list are installed. Roll back with: $REPO/scripts/rollback.sh $(cat "$BACKUP_DIR/LATEST-p3fixes") --apply"
	say "installed $live"
done
if [[ -e /etc/hosts.new ]]; then rm -f /etc/hosts.new; say "removed the old script's leftover /etc/hosts.new"; fi

hr "verify: IPv6 source selection"
service ip6addrctl start >/dev/null 2>&1 || true
v6_sources | tee "$STAGE/v6.after"
bad_src=$(/usr/bin/grep -c ' bak$' "$STAGE/v6.after" || true)
err_src=$(/usr/bin/grep -c ' error:' "$STAGE/v6.after" || true)
ping_ok=0; ping_n=0
for d in $V6_PROBE_DSTS; do
	ping_n=$((ping_n + 1))
	if ping -6 -c 2 -t 5 "$d" >/dev/null 2>&1; then ping_ok=$((ping_ok + 1)); fi
done
if (( bad_src == 0 && err_src == 0 )); then pass "router no longer picks the BACKUP address for traffic leaving PRIMARY"
elif (( bad_src != 0 )); then fail "$bad_src destination(s) still get the BACKUP source address"
else fail "$err_src destination(s) had no usable IPv6 route just now (not a statement about the policy)"; fi
# Replies to real packets: independent of the address reading above.
if (( ping_ok == ping_n )); then pass "IPv6 ping from router, no source given: $ping_ok/$ping_n destinations answer"
else fail "IPv6 ping from router: only $ping_ok/$ping_n destinations answer"; fi
if (( bad_src != 0 )) && (( ping_ok == 0 )); then
	if [[ $had_policy == no ]]; then
		rm -f "$POLICY"
		say "the policy did not help: removed $POLICY, address policy is back to stock"
	else
		tar -xzpf "$(cat "$BACKUP_DIR/LATEST-p3fixes")" -C / "${POLICY#/}"
		say "the policy did not help: restored the previous $POLICY from the backup"
	fi
	service ip6addrctl start >/dev/null 2>&1 || true
fi

hr "verify: FIB 0"
verdict="$($CTL evaluate 2>&1 | tail -1 || true)"
echo "  evaluate: $verdict"
if $CTL reconcile >/dev/null 2>&1; then pass "controller accepts 'reconcile' (what the dhclient hook now calls)"; else fail "'$CTL reconcile' failed"; fi
$CTL status || true
state="$(cat /var/run/wan_state 2>/dev/null || echo pri)"
want_gw="$(cat "/var/db/${state}_router" 2>/dev/null || true)"
have="$(netstat -rn -4 -F 0 | awk '$1 == "default" { print $2 }' | tr '\n' ' ')"; have=${have% }
if [[ $have == "$want_gw" ]]; then pass "FIB 0 has exactly one default, via $want_gw ($state)"
else fail "FIB 0 defaults: '${have:-none}', want only $want_gw ($state)"; fi
# Read from the kernel's nexthop-group table, which the controller never uses.
sleep 2   # a group is freed a moment after its last route goes
grp=$(netstat -4 -OnW -F 0 | awk '$1 ~ /^[0-9]+$/ && $2 ~ /^-+$/' | /usr/bin/grep -c . || true)
if (( grp == 0 )); then pass "no IPv4 nexthop groups in FIB 0"; else fail "$grp IPv4 nexthop group(s) still in FIB 0"; fi
if [[ $(pgrep -f 'dpinger .*-i (pri|bak)_' | wc -l) -eq 4 ]]; then pass "the four probes are still running (not restarted)"
else fail "expected 4 running probes"; fi

hr "verify: notification"
if echo "router: failover fixes installed $(date '+%F %T'). If you can read this, transition alerts work again." | "$NOTIFIER" normal; then
	pass "Pushover accepted a test message over IPv4 (check your phone: this proves delivery, the exit status only proves acceptance)"
else
	fail "test notification was not accepted"
fi

hr "verify: files"
if newsyslog -nv -f /usr/local/etc/newsyslog.conf.d/wan-failover.conf >/dev/null 2>&1; then pass "newsyslog accepts the rotation entry"; else fail "newsyslog rejects the rotation entry"; fi
if [[ $(stat -f %Lp "$NOTIFY_CONF") == 600 ]]; then pass "$NOTIFY_CONF is 0600"; else fail "$NOTIFY_CONF mode is $(stat -f %Lp "$NOTIFY_CONF")"; fi

say "p3_fixes applied with $fails failure(s)."
say "Not exercised: a real failover (P6), and the dhclient hook and hosts updater on a real lease event (next RENEW)."
say "Rollback: sudo $REPO/scripts/rollback.sh $(cat "$BACKUP_DIR/LATEST-p3fixes") --apply"
say "  then, for files that did not exist before: sudo rm -f $NOTIFIER $NOTIFY_CONF /usr/local/etc/newsyslog.conf.d/wan-failover.conf$([[ $had_policy == no ]] && echo " $POLICY") && sudo service ip6addrctl start"
(( fails == 0 ))
