#!/bin/sh
set -u

LOG_PREFIX="[leigod-vm]"
OFFICIAL_INSTALL_URL="${OFFICIAL_INSTALL_URL:-http://119.3.40.126/router_plugin_new/plugin_install.sh}"

log() {
    echo "${LOG_PREFIX} $*"
}

install_pkg() {
    pkg="$1"
    if opkg list-installed | grep -q "^${pkg} -"; then
        log "package already installed: ${pkg}"
        return 0
    fi
    log "install package: ${pkg}"
    opkg install "$pkg" || log "warn: failed to install ${pkg}"
}

prepare_system() {
    log "update opkg index"
    opkg update

    for pkg in curl libpcap iptables kmod-ipt-nat iptables-mod-tproxy kmod-ipt-tproxy kmod-ipt-ipset ipset kmod-tun miniupnpd tc-full kmod-netem conntrack; do
        install_pkg "$pkg"
    done

    log "make firewall permissive for VM scenario"
    uci set firewall.@defaults[0].input='ACCEPT' 2>/dev/null || true
    uci set firewall.@defaults[0].output='ACCEPT' 2>/dev/null || true
    uci set firewall.@defaults[0].forward='ACCEPT' 2>/dev/null || true
    uci commit firewall 2>/dev/null || true
    /etc/init.d/firewall restart 2>/dev/null || true
}

install_socks5() {
    log "install SOCKS5 service"

    if opkg install python3 >/tmp/python3-install.log 2>&1; then
        cp /root/socks5.py /usr/bin/leigod-socks5.py
        chmod +x /usr/bin/leigod-socks5.py
        cat > /etc/init.d/leigod-socks5 <<'EOF_INIT'
#!/bin/sh /etc/rc.common
START=99
STOP=10

start() {
    pgrep -f "leigod-socks5.py" >/dev/null 2>&1 && return 0
    SOCKS5_BIND=0.0.0.0 SOCKS5_PORT=1080 python3 /usr/bin/leigod-socks5.py >/tmp/leigod-socks5.log 2>&1 &
}

stop() {
    pkill -f leigod-socks5.py >/dev/null 2>&1 || true
}
EOF_INIT
    elif opkg install microsocks >/tmp/microsocks-install.log 2>&1; then
        log "python3 unavailable, fallback to microsocks (TCP-only on most builds)"
        cat > /etc/init.d/leigod-socks5 <<'EOF_INIT'
#!/bin/sh /etc/rc.common
START=99
STOP=10

start() {
    pgrep -f "microsocks.*1080" >/dev/null 2>&1 && return 0
    microsocks -i 0.0.0.0 -p 1080 >/tmp/leigod-socks5.log 2>&1 &
}

stop() {
    killall microsocks >/dev/null 2>&1 || true
}
EOF_INIT
    else
        log "error: cannot install python3 or microsocks"
        exit 1
    fi

    chmod +x /etc/init.d/leigod-socks5
    /etc/init.d/leigod-socks5 enable
    /etc/init.d/leigod-socks5 restart
}

install_wireguard() {
    log "install WireGuard for transparent gateway mode"

    for pkg in wireguard-tools kmod-wireguard kmod-udptunnel4; do
        install_pkg "$pkg"
    done

    mkdir -p /etc/wireguard
    if [ ! -f /etc/wireguard/server.key ]; then
        wg genkey > /etc/wireguard/server.key
        chmod 600 /etc/wireguard/server.key
        wg pubkey < /etc/wireguard/server.key > /etc/wireguard/server.pub
    fi

    local server_key
    server_key=$(cat /etc/wireguard/server.key)

    uci -q delete network.wg0 2>/dev/null || true
    uci set network.wg0='interface'
    uci set network.wg0.proto='wireguard'
    uci set network.wg0.private_key="$server_key"
    uci set network.wg0.listen_port='51820'
    uci add_list network.wg0.addresses='10.10.0.1/24'
    uci commit network

    echo 1 > /proc/sys/net/ipv4/ip_forward

    iptables -t nat -C POSTROUTING -s 10.10.0.0/24 -o eth0 -j MASQUERADE 2>/dev/null || \
        iptables -t nat -A POSTROUTING -s 10.10.0.0/24 -o eth0 -j MASQUERADE

    ifup wg0 2>/dev/null || true

    log "WireGuard server ready: port 51820, subnet 10.10.0.0/24"
    log "Server public key: $(cat /etc/wireguard/server.pub)"
}

install_leigod() {
    if [ -d /usr/sbin/leigod ] || [ -f /etc/init.d/acc ]; then
        log "Leigod appears installed, skip official installer"
        return 0
    fi

    log "download official Leigod router plugin installer"
    cd /tmp || exit 1
    curl -fsSL -o /tmp/leigod-plugin-install.sh "$OFFICIAL_INSTALL_URL" || {
        log "error: cannot download official installer: ${OFFICIAL_INSTALL_URL}"
        exit 1
    }
    sh /tmp/leigod-plugin-install.sh
}

enable_upnp() {
    log "enable UPnP for phone discovery"
    if [ -f /etc/config/upnpd ]; then
        uci set upnpd.config.enabled='1' 2>/dev/null || true
        uci set upnpd.config.internal_iface='wan' 2>/dev/null || true
        uci set upnpd.config.external_iface='wan' 2>/dev/null || true
        uci set upnpd.config.secure_mode='0' 2>/dev/null || true
        uci commit upnpd 2>/dev/null || true
        /etc/init.d/miniupnpd enable 2>/dev/null || true
        /etc/init.d/miniupnpd restart 2>/dev/null || true
    else
        log "warn: /etc/config/upnpd not found"
    fi
}

enable_tun_mode() {
    log "enable Leigod TUN mode"
    if [ -f /etc/config/accelerator ]; then
        uci set accelerator.base.tun='1' 2>/dev/null || true
        uci commit accelerator 2>/dev/null || true
    fi

    if [ -f /etc/init.d/acc ] && ! grep -q -- "--mode tun" /etc/init.d/acc; then
        sed -i 's|${args}|--mode tun|' /etc/init.d/acc 2>/dev/null || true
    fi

    /etc/init.d/acc enable 2>/dev/null || true
    /etc/init.d/acc restart 2>/dev/null || true
}

print_status() {
    log "bootstrap completed"
    echo
    echo "Interfaces:"
    ip -4 addr show eth0 2>/dev/null || true
    ip -4 addr show eth1 2>/dev/null || true
    echo
    echo "SOCKS5: listen on 0.0.0.0:1080 (backup mode)"
    echo "WireGuard: port 51820, subnet 10.10.0.0/24 (default mode)"
    echo "Logs:   /tmp/leigod-socks5.log and /tmp/acc/"
    echo
    echo "Mode A (default): ./kvm/wg-up.sh  — all traffic through VM via WireGuard"
    echo "Mode B (backup):  mihomo SOCKS5 192.168.122.10:1080"
}

prepare_system
install_socks5
install_wireguard
install_leigod
enable_upnp
enable_tun_mode
print_status
