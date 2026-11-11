# Shared helpers for the phase scripts. Sourced, bash.

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BACKUP_DIR="/root/failover-backups"
TS="$(date +%F-%H%M%S)"

# Everything any phase might touch; each phase backs all of it up.
BACKUP_PATHS=(
	/etc/rc.conf /etc/rc.local /etc/sysctl.conf /boot/loader.conf /etc/hosts
	/etc/pf
	/etc/dhclient.conf /etc/dhclient-enter-hooks /etc/dhclient-exit-hooks /etc/dhclient-scripts
	/etc/dpinger
	/usr/local/sbin/wan-failover /usr/local/etc/rc.d/wan_failover /etc/cron.d/wan-failover
	/usr/local/libexec/wan-notify /usr/local/etc/wan-notify.conf /etc/ip6addrctl.conf /usr/local/etc/newsyslog.conf.d/wan-failover.conf
	/etc/periodic.conf /usr/local/etc/periodic/daily/480.status-smokeping
	/usr/local/etc/smokeping/config /usr/local/libexec/fping-pri /usr/local/libexec/fping-bak /usr/local/libexec/fping-bak6 /usr/local/libexec/traceroute6-bak /usr/local/libexec/tcpping-connect
	/usr/local/sbin/bak-clat /usr/local/etc/bak-clat.conf /etc/cron.d/bak-clat
	/boot/loader.conf.d /boot/modules/pf.ko /boot/modules/pf.ko.buildinfo /usr/local/etc/periodic/daily/481.status-pfko
)

say()  { printf '[%s] %s\n' "$(date +%T)" "$*"; }
die()  { printf '[%s] ERROR: %s\n' "$(date +%T)" "$*" >&2; exit 1; }
hr()   { printf -- '----- %s -----\n' "$*"; }

parse_mode() { # sets MODE=dry-run|apply
	MODE=dry-run
	case "${1:-}" in
	"") ;;
	--apply) MODE=apply ;;
	-h|--help) usage; exit 0 ;;
	*) usage >&2; exit 2 ;;
	esac
	if [[ $MODE == apply && $(id -u) -ne 0 ]]; then
		die "--apply needs root: sudo $0 --apply"
	fi
	say "mode: $MODE"
}

backup() { # backup <phase-tag>
	mkdir -p "$BACKUP_DIR"
	local out="$BACKUP_DIR/${TS}-$1.tgz" existing=()
	for p in "${BACKUP_PATHS[@]}"; do
		if [[ -e $p ]]; then existing+=("${p#/}"); fi
	done
	tar -czpf "$out" -C / "${existing[@]}"
	say "backup: $out ($(tar -tzf "$out" | wc -l | tr -d ' ') entries)"
	echo "$out" > "$BACKUP_DIR/LATEST-$1"
}

show_diff() { # show_diff <live> <candidate>
	if [[ -e $1 ]]; then
		diff -u "$1" "$2" && say "unchanged: $1" || true
	else
		say "new file: $1"; cat "$2"
	fi
}
