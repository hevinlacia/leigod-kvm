#!/usr/bin/env bash
set -euo pipefail

WG_IFACE="wg-leigod"
WG_DIR="${HOME}/.config/wireguard-leigod"
WG_CONF="${WG_DIR}/${WG_IFACE}.conf"
STATE_FILE="${WG_DIR}/.state"

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || { echo "Missing: $1" >&2; exit 1; }
}

stop_tunnel() {
    echo "Stopping WireGuard tunnel..."

    local restart_mihomo=false
    if [ -f "$STATE_FILE" ]; then
        grep -q "mihomo_stopped=true" "$STATE_FILE" && restart_mihomo=true
    fi

    sudo bash -c "
        wg-quick down '${WG_CONF}' 2>/dev/null || true
        if [ '${restart_mihomo}' = 'true' ]; then
            systemctl start mihomo
        fi
    "

    rm -f "$STATE_FILE"
}

print_status() {
    echo
    echo "WireGuard tunnel is DOWN."
    echo "  mihomo has been restored."
    echo "  All traffic back to normal (mihomo TUN)."
}

main() {
    require_cmd wg-quick
    stop_tunnel
    print_status
}

main "$@"
