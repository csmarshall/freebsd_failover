#!/usr/local/bin/bash
# Usage: set_gateway_entries.sh <gateway-ip> "<name> [name...]" [allow-private]
# Points /etc/hosts names (used by smokeping) at a WAN gateway. RFC1918 and
# loopback gateways are refused unless allow-private is given (TMO's gateway
# is the Teltonika at 192.168.12.1).
new_routers="${1}"
NAMES="${2}"
ALLOW_PRIVATE="${3:-}"
LOGGER="/usr/bin/logger -s -p user.notice -t set_gateway_entries"

if [[ -z "${new_routers}" ]]; then
	${LOGGER} "No new routers provided"
	exit 0
fi

if [[ "${ALLOW_PRIVATE}" != "allow-private" ]] &&
   [[ "${new_routers}" =~ (^127\.)|(^10\.)|(^172\.1[6-9]\.)|(^172\.2[0-9]\.)|(^172\.3[0-1]\.)|(^192\.168\.) ]]; then
	${LOGGER} "Not setting gateway to ${new_routers}"
	exit 0
fi

for NAME in ${NAMES} ; do
	grep -v -e " ${NAME}" /etc/hosts > /etc/hosts.new &&
	    echo -e "${new_routers} ${NAME} # $(date -Iseconds)" | tee -a /etc/hosts.new | ${LOGGER} &&
	    cp /etc/hosts.new /etc/hosts
	getent hosts "${NAME}" | ${LOGGER}
done
