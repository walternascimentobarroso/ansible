#!/usr/bin/env bash

# Disables DHCP on the NOS router (Sagemcom, RDK-B web UI) so Pi-hole is the only DHCP server.
# Re-run it whenever NOS resets the router.

set -euo pipefail

set -a
# shellcheck disable=SC1091
source .env
set +a

ROUTER_URL="http://${PIHOLE_DHCP_ROUTER}"
ROUTER_USER="${ROUTER_USER:-admin}"
ROUTER_PASSWORD="${ROUTER_PASSWORD:-admin}"
LEASE_SECONDS=3600

COOKIES="$(mktemp)"
router() {
    curl -fsS -b "${COOKIES}" -c "${COOKIES}" "$@"
}

# The router allows a single HTTP session, so always log out to keep the web UI reachable.
logout() {
    router -o /dev/null "${ROUTER_URL}/home_loggedout.php" || true
    rm -f "${COOKIES}"
}
trap logout EXIT

dhcp_enabled() {
    router "${ROUTER_URL}/local_ip_configuration.php" | grep -q 'id="DHCPstatus"[^>]*checked'
}

csrf_token() {
    awk '$6 == "csrfp_token" { print $7 }' "${COOKIES}"
}

echo "==> Logging in to ${ROUTER_URL}"
router -o /dev/null "${ROUTER_URL}/index.php"
router -o /dev/null \
    --data-urlencode "username=${ROUTER_USER}" \
    --data-urlencode "password=$(printf '%s' "${ROUTER_PASSWORD}" | base64)" \
    "${ROUTER_URL}/check.php"

if ! dhcp_enabled; then
    echo "==> DHCP already disabled"
    exit 0
fi

echo "==> Disabling DHCP"
config="{\"Ipaddr\":\"${PIHOLE_DHCP_ROUTER}\", \"Subnet_mask\":\"${PIHOLE_DHCP_NETMASK}\", \"Dhcp_begin_addr\":\"${PIHOLE_DHCP_START}\", \"manual_dns\":\"false\", \"Dhcp_end_addr\":\"${PIHOLE_DHCP_END}\", \"Dhcp_lease_time\":\"${LEASE_SECONDS}\", \"jsdhcp_status\":\"Disabled\"}"
router -o /dev/null \
    --data-urlencode "configInfo=${config}" \
    --data-urlencode "csrfp_token=$(csrf_token)" \
    "${ROUTER_URL}/actionHandler/ajaxSet_IP_configuration.php"

if dhcp_enabled; then
    echo "DHCP is still enabled on the router" >&2
    exit 1
fi

echo "==> DHCP disabled, Pi-hole is now the DHCP server"
