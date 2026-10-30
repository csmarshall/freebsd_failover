#!/usr/local/bin/bash
# Smokeping per-uplink probes: installs the fping-att / fping-tmo wrappers
# (fping run in FIB 1 / FIB 2 from that uplink's lease address) and the
# smokeping config with an Uplinks section (ATT, TMO, ATT-vs-TMO) and the
# gateway targets renamed (T-Mobile -> TMO, Comcast removed: it no longer
# resolves and made every fping round exit 2). Restarts smokeping.
unset TMOUT
set -euo pipefail
. "$(dirname "$0")/lib.sh"

usage() {
	cat <<EOF
Usage: $0 [--apply]
  (no args)  dry run: wrapper test pings, diff, smokeping --check; touches nothing
  --apply    back up to $BACKUP_DIR, install, restart smokeping, verify (needs root)
EOF
}
parse_mode "${1:-}"

CONF=/usr/local/etc/smokeping/config
WRAP_SRC="$REPO/router/usr/local/libexec/fping-uplink"
TR6_SRC="$REPO/router/usr/local/libexec/traceroute6-tmo"
RRD_DIR=/usr/local/var/smokeping/FPings/Network/Uplinks
STAGE="$(mktemp -d -t smokeping)"
trap 'rm -rf "$STAGE"' EXIT

# Stage the wrappers under their real names and a config pointing at them.
for r in att tmo; do install -m 0755 "$WRAP_SRC" "$STAGE/fping-$r"; done
install -m 0755 "$TR6_SRC" "$STAGE/traceroute6-tmo"
sed -e "s|/usr/local/libexec/fping-|$STAGE/fping-|" \
    -e "s|/usr/local/libexec/traceroute6-tmo|$STAGE/traceroute6-tmo|" "$REPO/router$CONF" > "$STAGE/config"

hr "wrapper test pings (each through its own FIB)"
for r in att tmo; do
	out="$("$STAGE/fping-$r" -C 3 -q -p 1000 1.1.1.1 2>&1 || true)"
	echo "  $r: $out"
	[[ $out == *"1.1.1.1 :"* && $out != *" - - -"* ]] || die "fping-$r got no replies"
done
cp "$WRAP_SRC" "$STAGE/fping-bogus"
if "$STAGE/fping-bogus" 1.1.1.1 >/dev/null 2>&1; then die "wrapper ran under a wrong name"; fi
say "PASS wrapper refuses an unknown name"

hr "TMO first hop (hop 2 over IPv6, FIB 2)"
hop2="$("$STAGE/traceroute6-tmo" -w 2 -f 2 -m 2 -q 1 -n 2001:4860:4860::8888 2>&1 || true)"
echo "$hop2" | sed 's/^/  /'
if [[ $(printf '%s\n' "$hop2" | /usr/bin/grep -c '^2 ::2 [0-9.]* ms') -gt 0 ]]; then say "PASS hop 2 answers"
else say "WARNING no hop-2 reply (FIB 2 IPv6 default missing? re-run p1_fibs_hooks.sh --apply)"; fi

hr "$CONF"; show_diff "$CONF" "$REPO/router$CONF"
hr "smokeping --check (staged)"
/usr/local/bin/smokeping --check --config="$STAGE/config" || die "staged config fails smokeping --check"

if [[ $MODE != apply ]]; then
	say "dry run complete; re-run with --apply"
	exit 0
fi

backup smokeping
owner="$(stat -f %Su:%Sg "$CONF")"
for r in att tmo; do
	install -m 0755 -o root -g wheel "$WRAP_SRC" "/usr/local/libexec/fping-$r"
	say "installed /usr/local/libexec/fping-$r"
done
install -m 0755 -o root -g wheel "$TR6_SRC" /usr/local/libexec/traceroute6-tmo
say "installed /usr/local/libexec/traceroute6-tmo"
install -m 0644 -o "${owner%%:*}" -g "${owner##*:}" "$REPO/router$CONF" "$CONF"
say "installed $CONF ($owner)"
/usr/local/bin/smokeping --check --config="$CONF" ||
	die "installed config fails --check; restore: $REPO/scripts/rollback.sh $(cat "$BACKUP_DIR/LATEST-smokeping") --apply"
LOG_LINES_BEFORE="$(wc -l < /var/log/smokeping.log | tr -d ' ')"
service smokeping restart

hr "verify"
fails=0
pass() { say "PASS $*"; }
fail() { say "FAIL $*"; fails=$((fails + 1)); }
procs=""
for _ in $(seq 1 30); do
	procs="$(pgrep -lf 'smokeping \[' || true)"
	[[ $procs == *FPingATT* && $procs == *FPingTMO* && $procs == *FPingDefault* && $procs == *TraceroutePing* ]] && break
	sleep 1
done
echo "$procs"
for p in FPingDefault FPingATT FPingTMO TraceroutePing; do
	if [[ $procs == *"[$p]"* ]]; then pass "probe process $p running"; else fail "probe process $p not running"; fi
done
for t in ATT/CloudFlare ATT/Google ATT/Level3 TMO/CloudFlare TMO/Google TMO/Level3 TMO/First_Hop; do
	if [[ -e $RRD_DIR/$t.rrd ]]; then pass "RRD $t"; else fail "no RRD $RRD_DIR/$t.rrd"; fi
done
echo "----- smokeping.log since restart -----"
tail -n +"$((LOG_LINES_BEFORE + 1))" /var/log/smokeping.log | cut -c1-200
say "smokeping updated with $fails failure(s). First uplink data lands within one 5-minute step."
say "Graphs: https://router.example.com/smokeping/smokeping.cgi?target=FPings.Network.Uplinks"
say "Rollback: sudo $REPO/scripts/rollback.sh $(cat "$BACKUP_DIR/LATEST-smokeping") --apply && sudo service smokeping restart"
