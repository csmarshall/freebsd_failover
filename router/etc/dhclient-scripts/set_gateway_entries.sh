#!/usr/local/bin/bash
# Usage: set_gateway_entries.sh <gateway-ip> "<name> [name...]" [allow-private]
#
# Points /etc/hosts names (used by smokeping) at a WAN gateway. RFC1918 and
# loopback gateways are refused unless allow-private is given (BACKUP's gateway
# is the 5G CPE).
#
# The file is replaced in one rename, with every name updated in the same
# pass, so a reader never sees a partial /etc/hosts and a failure leaves the
# old file as it was. Nothing is written when every name already points at
# the gateway (a lease RENEW normally changes nothing). Runs are serialised:
# both uplinks' dhclient hooks call this.
#
# Exit: 0 = updated or already correct (or refused gateway: not an error for
#       the hook), 1 = could not update, 2 = usage.
unset TMOUT
set -uo pipefail
PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/bin

HOSTS="${SGE_HOSTS:-/etc/hosts}"
LOCK="${SGE_LOCK:-/var/run/set_gateway_entries.lock}"
LOGGER="${SGE_LOGGER:-/usr/bin/logger -s -p user.notice -t set_gateway_entries}"

if [[ $# -lt 2 || $# -gt 3 ]]; then
	echo "usage: $0 <gateway-ip> \"<name> [name...]\" [allow-private]" >&2
	exit 2
fi
gw=$1
NAMES=$2
ALLOW_PRIVATE=${3:-}

if [[ -z $gw ]]; then
	${LOGGER} "No new routers provided"
	exit 0
fi
if [[ $ALLOW_PRIVATE != allow-private ]] &&
   [[ $gw =~ (^127\.)|(^10\.)|(^172\.1[6-9]\.)|(^172\.2[0-9]\.)|(^172\.3[0-1]\.)|(^192\.168\.) ]]; then
	${LOGGER} "Not setting gateway to ${gw}"
	exit 0
fi
if [[ ! $gw =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
	${LOGGER} "Not an IPv4 address: ${gw}"
	exit 1
fi
if [[ -z ${NAMES// /} ]]; then
	${LOGGER} "No names given"
	exit 2
fi

if [[ -z ${SGE_LOCKED:-} ]]; then
	SGE_LOCKED=1 exec lockf -k -t 10 "$LOCK" /usr/local/bin/bash "$0" "$@"
fi

# Prints the new file: every line of the old one with our names taken out
# (a line left with no name is dropped), then one "<gw> <name>" line per name.
# Exits 3 without output worth using when the file is already correct: each
# name appears exactly once, alone on a line whose address is the gateway.
render() {
	awk -v names="$NAMES" -v gw="$gw" -v stamp="$(date -Iseconds)" '
	BEGIN { n = split(names, order, " "); for (i = 1; i <= n; i++) want[order[i]] = 1 }
	{
		body = $0; comment = ""
		if ((c = index(body, "#")) > 0) { comment = substr(body, c); body = substr(body, 1, c - 1) }
		m = split(body, f, /[ \t]+/)
		first = (m > 0 && f[1] == "") ? 2 : 1      # leading whitespace gives an empty first field
		ours = 0; others = ""; nnames = 0
		for (i = first + 1; i <= m; i++) {
			if (f[i] == "") continue
			nnames++
			if (f[i] in want) { ours++; seen[f[i]]++; last = f[i] } else others = others " " f[i]
		}
		if (ours == 0) { print; next }
		if (ours == 1 && nnames == 1 && f[first] == gw) good[last]++
		else dirty = 1
		if (others != "") print f[first] others (comment == "" ? "" : " " comment)
	}
	END {
		for (i = 1; i <= n; i++) {
			print gw " " order[i] " # " stamp
			if (good[order[i]] != 1 || seen[order[i]] != 1) dirty = 1
		}
		if (!dirty) exit 3
	}' "$HOSTS"
}

# Counts the non-empty lines of <file> that name none of our names.
other_lines() { # other_lines <file>
	awk -v names="$NAMES" '
	BEGIN { n = split(names, a, " "); for (i = 1; i <= n; i++) want[a[i]] = 1 }
	/^[ \t]*$/ { next }
	{
		body = $0
		if ((c = index(body, "#")) > 0) body = substr(body, 1, c - 1)
		m = split(body, f, /[ \t]+/)
		for (i = 2; i <= m; i++) if (f[i] in want) next
		count++
	}
	END { print count + 0 }' "$1"
}

if [[ ! -r $HOSTS ]]; then
	${LOGGER} "Cannot read ${HOSTS}"
	exit 1
fi
# Beside the target so the rename cannot cross filesystems.
tmp=$(mktemp "${HOSTS}.XXXXXX") || { ${LOGGER} "Cannot create a temp file beside ${HOSTS}"; exit 1; }
trap 'rm -f "$tmp"' EXIT

render > "$tmp"
rc=$?
if (( rc == 3 )); then
	exit 0   # already correct: leave the file (and its mtime) alone
fi
if (( rc != 0 )) || [[ ! -s $tmp ]]; then
	${LOGGER} "Building the new ${HOSTS} failed (awk exit ${rc}); left unchanged"
	exit 1
fi
# The new file must keep every line that does not mention our names. Lines
# that do are left out of both counts (they are meant to change); a shared
# line keeps its other names, so the new count can only be equal or higher.
kept_old=$(other_lines "$HOSTS")
kept_new=$(other_lines "$tmp")
if (( kept_new < kept_old )); then
	${LOGGER} "New ${HOSTS} lost unrelated lines (${kept_old} -> ${kept_new}); left unchanged"
	exit 1
fi

chmod 0644 "$tmp" && mv -f "$tmp" "$HOSTS" || { ${LOGGER} "Could not replace ${HOSTS}"; exit 1; }
${LOGGER} "${gw} <- ${NAMES}"
exit 0
