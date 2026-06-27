#!/usr/bin/env bash
set -euo pipefail

VM_IP="${VM_IP:-192.168.122.10}"
VM_PORT="${VM_PORT:-51820}"
WG_IFACE="wg-leigod"
WG_DIR="${HOME}/.config/wireguard-leigod"
WG_CONF="${WG_DIR}/${WG_IFACE}.conf"
SSH_PASS="${SSH_PASS:-leigod}"
STATE_FILE="${WG_DIR}/.state"

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || { echo "Missing: $1" >&2; exit 1; }
}

generate_host_keypair() {
    mkdir -p "$WG_DIR"
    chmod 700 "$WG_DIR"
    if [ ! -f "${WG_DIR}/privatekey" ]; then
        wg genkey > "${WG_DIR}/privatekey"
        chmod 600 "${WG_DIR}/privatekey"
    fi
}

configure_vm_peer() {
    local host_privkey host_pubkey server_pubkey
    host_privkey=$(cat "${WG_DIR}/privatekey")
    host_pubkey=$(wg pubkey <<< "$host_privkey")

    echo "Configuring WireGuard peer on VM (${VM_IP})..."

    server_pubkey=$(sshpass -p "$SSH_PASS" ssh -o StrictHostKeyChecking=no root@"$VM_IP" bash -s <<EOF
if [ ! -f /etc/wireguard/server.key ]; then
    mkdir -p /etc/wireguard
    wg genkey > /etc/wireguard/server.key
    chmod 600 /etc/wireguard/server.key
    wg pubkey < /etc/wireguard/server.key > /etc/wireguard/server.pub
fi
uci -q delete network.wg_peer_host 2>/dev/null || true
uci set network.wg_peer_host='wireguard_wg0'
uci set network.wg_peer_host.public_key='${host_pubkey}'
uci set network.wg_peer_host.persistent_keepalive='25'
uci del_list network.wg_peer_host.allowed_ips='10.10.0.2/32' 2>/dev/null || true
uci add_list network.wg_peer_host.allowed_ips='10.10.0.2/32'
uci commit network
ifup wg0 2>/dev/null || true
cat /etc/wireguard/server.pub
EOF
)

    echo "$server_pubkey" > "${WG_DIR}/server.pub"

    cat > "$WG_CONF" <<EOF
[Interface]
PrivateKey = ${host_privkey}
Address = 10.10.0.2/24

[Peer]
PublicKey = ${server_pubkey}
Endpoint = ${VM_IP}:${VM_PORT}
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF
    chmod 600 "$WG_CONF"
}

start_tunnel() {
    echo "Starting WireGuard tunnel (stops mihomo temporarily)..."

    local mihomo_was_active=false
    if systemctl is-active mihomo >/dev/null 2>&1; then
        mihomo_was_active=true
    fi

    sudo bash -c "
        if systemctl is-active mihomo 2>/dev/null; then
            systemctl stop mihomo
        fi
        wg-quick up '${WG_CONF}'
    "

    echo "mihomo_stopped=${mihomo_was_active}" > "$STATE_FILE"
}

print_status() {
    echo
    echo "WireGuard tunnel is UP."
    echo "  Interface:  ${WG_IFACE}"
    echo "  VM peer:    ${VM_IP}:${VM_PORT}"
    echo "  Tunnel IP:  10.10.0.2"
    echo "  All traffic now routes through VM -> Leigod acceleration."
    echo
    echo "  mihomo is temporarily stopped."
    echo "  Run ./kvm/wg-down.sh to restore mihomo and close the tunnel."
    echo
    echo "  Verify: curl -s --connect-timeout 5 http://ip-api.com/json | jq -r .query"
}

main() {
    require_cmd wg
    require_cmd wg-quick
    require_cmd sshpass
    require_cmd ssh

    generate_host_keypair
    configure_vm_peer
    start_tunnel
    print_status
}

main "$@"
