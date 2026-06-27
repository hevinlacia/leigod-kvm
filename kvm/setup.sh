#!/usr/bin/env bash
set -euo pipefail

VM_NAME="${VM_NAME:-leigod-openwrt}"
VM_MEMORY_MB="${VM_MEMORY_MB:-768}"
VM_VCPUS="${VM_VCPUS:-2}"
VM_DISK_SIZE="${VM_DISK_SIZE:-2G}"
ROOT_PASSWORD="${ROOT_PASSWORD:-leigod}"
LIBVIRT_URI="${LIBVIRT_URI:-qemu:///system}"
NAT_NETWORK="${NAT_NETWORK:-default}"
IMAGE_URL="${IMAGE_URL:-https://downloads.openwrt.org/releases/21.02.7/targets/x86/64/openwrt-21.02.7-x86-64-generic-ext4-combined.img.gz}"
PHYSICAL_IFACE="${PHYSICAL_IFACE:-}"
DISK_PATH="${DISK_PATH:-${HOME}/.local/share/libvirt/images/${VM_NAME}.qcow2}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR="${WORK_DIR:-/tmp/opencode/${VM_NAME}-setup}"
RAW_IMAGE="${WORK_DIR}/openwrt.img"
QCOW_IMAGE="${WORK_DIR}/${VM_NAME}.qcow2"
MOUNT_DIR="${WORK_DIR}/rootfs"

require_cmd() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "Missing command: $1" >&2
        exit 1
    fi
}

# ── libvirt (no sudo needed if user is in libvirt group) ──

ensure_libvirt() {
    local need_start=false

    if systemctl list-unit-files virtqemud.service >/dev/null 2>&1; then
        for svc in virtqemud virtnetworkd virtlogd virtstoraged; do
            if ! systemctl is-active "$svc" >/dev/null 2>&1; then
                need_start=true
                break
            fi
        done
        if [ "$need_start" = true ]; then
            echo "Libvirt services not running. Starting them (needs sudo, one-time only):"
            sudo systemctl enable --now virtqemud.service virtnetworkd.service virtlogd.service virtstoraged.service
        fi
    else
        if ! systemctl is-active libvirtd >/dev/null 2>&1; then
            echo "libvirtd not running. Starting it (needs sudo, one-time only):"
            sudo systemctl enable --now libvirtd.service
        fi
    fi
}

ensure_default_network() {
    if ! virsh --connect "$LIBVIRT_URI" net-info "$NAT_NETWORK" >/dev/null 2>&1; then
        local xml
        xml="${WORK_DIR}/${NAT_NETWORK}.xml"
        cat > "$xml" <<EOF_NET
<network>
  <name>${NAT_NETWORK}</name>
  <forward mode='nat'/>
  <bridge name='virbr0' stp='on' delay='0'/>
  <ip address='192.168.122.1' netmask='255.255.255.0'>
    <dhcp>
      <range start='192.168.122.2' end='192.168.122.254'/>
    </dhcp>
  </ip>
</network>
EOF_NET
        virsh --connect "$LIBVIRT_URI" net-define "$xml" >/dev/null
    fi

    virsh --connect "$LIBVIRT_URI" net-start "$NAT_NETWORK" >/dev/null 2>&1 || true
    virsh --connect "$LIBVIRT_URI" net-autostart "$NAT_NETWORK" >/dev/null 2>&1 || true
}

detect_physical_iface() {
    if [ -z "$PHYSICAL_IFACE" ]; then
        PHYSICAL_IFACE="$(ip route show default | awk '{print $5; exit}')"
    fi

    if [ -z "$PHYSICAL_IFACE" ]; then
        echo "Cannot detect default route interface. Set PHYSICAL_IFACE manually." >&2
        exit 1
    fi

    if [ ! -d "/sys/class/net/${PHYSICAL_IFACE}" ]; then
        echo "Network interface not found: ${PHYSICAL_IFACE}" >&2
        exit 1
    fi

    if [ -d "/sys/class/net/${PHYSICAL_IFACE}/wireless" ]; then
        echo "Warning: ${PHYSICAL_IFACE} looks like Wi-Fi. macvtap bridge mode may not work on Wi-Fi." >&2
    fi
}

# ── image download (no sudo) ──

download_image() {
    mkdir -p "$WORK_DIR"
    if [ -f "$RAW_IMAGE" ]; then
        echo "Using existing raw image: $RAW_IMAGE"
        return
    fi

    echo "Downloading OpenWrt image: $IMAGE_URL"
    curl -fL --retry 3 --retry-delay 3 -o "${RAW_IMAGE}.gz" "$IMAGE_URL"
    if ! gunzip -f "${RAW_IMAGE}.gz"; then
        if [ -f "$RAW_IMAGE" ]; then
            echo "gunzip returned a warning, but raw image exists; continuing: $RAW_IMAGE" >&2
        else
            echo "Failed to decompress OpenWrt image" >&2
            exit 1
        fi
    fi
}

# ── guest config generation (no sudo) ──

write_guest_configs() {
    mkdir -p "${WORK_DIR}/inject"

    cat > "${WORK_DIR}/inject/network" <<'EOF_NETWORK'
config interface 'loopback'
        option device 'lo'
        option proto 'static'
        option ipaddr '127.0.0.1'
        option netmask '255.255.0.0'

config interface 'wan'
        option device 'eth0'
        option proto 'dhcp'
        option metric '10'

config interface 'lan'
        option device 'eth1'
        option proto 'static'
        option ipaddr '192.168.122.10'
        option netmask '255.255.255.0'
        option gateway '192.168.122.1'
        option dns '192.168.122.1'
        option metric '50'
EOF_NETWORK

    cat > "${WORK_DIR}/inject/dhcp" <<'EOF_DHCP'
config dnsmasq
        option domainneeded '1'
        option boguspriv '1'
        option filterwin2k '0'
        option localise_queries '1'
        option rebind_protection '1'
        option rebind_localhost '1'
        option local '/lan/'
        option domain 'lan'
        option expandhosts '1'
        option nonegcache '0'
        option authoritative '1'
        option readethers '1'
        option leasefile '/tmp/dhcp.leases'
        option resolvfile '/tmp/resolv.conf.d/resolv.conf.auto'
        option nonwildcard '1'
        option localservice '1'

config dhcp 'lan'
        option interface 'lan'
        option ignore '1'

config dhcp 'wan'
        option interface 'wan'
        option ignore '1'
EOF_DHCP

    cat > "${WORK_DIR}/inject/firewall" <<'EOF_FIREWALL'
config defaults
        option input 'ACCEPT'
        option output 'ACCEPT'
        option forward 'ACCEPT'
        option drop_invalid '0'
EOF_FIREWALL

    cat > "${WORK_DIR}/inject/dropbear" <<'EOF_DROPBEAR'
config dropbear
        option PasswordAuth 'on'
        option RootPasswordAuth 'on'
        option Port '22'
EOF_DROPBEAR

    cat > "${WORK_DIR}/inject/upnpd" <<'EOF_UPNPD'
config upnpd 'config'
        option enabled '1'
        option enable_natpmp '1'
        option secure_mode '0'
        option log_output '1'
        option download '10240'
        option upload '10240'
        option internal_iface 'wan'
        option external_iface 'wan'
EOF_UPNPD

    cat > "${WORK_DIR}/inject/system" <<'EOF_SYSTEM'
config system
        option hostname 'leigod-openwrt'
        option timezone 'CST-8'
        option ttylogin '0'
        option log_size '128'
        option urandom_seed '0'

config timeserver 'ntp'
        option enabled '1'
        option enable_server '0'
        list server 'ntp.aliyun.com'
        list server 'time1.cloud.tencent.com'
EOF_SYSTEM
}

# ── raw image resize + config injection (single sudo call) ──
#
# These operations require root due to Linux kernel restrictions:
#   losetup, mount, parted, e2fsck, resize2fs
# We consolidate them into one sudo invocation to minimize privilege escalation.

prepare_raw_image() {
    write_guest_configs

    local root_hash helper_script
    root_hash="$(openssl passwd -1 "$ROOT_PASSWORD")"
    helper_script="${WORK_DIR}/root-helper.sh"

    cat > "$helper_script" <<'EOF_HELPER'
#!/bin/bash
set -e

RAW_IMAGE="$1"
MOUNT_DIR="$2"
VM_DISK_SIZE="$3"
ROOT_HASH="$4"
INJECT_DIR="$5"
SCRIPT_DIR="$6"

echo "Expanding raw image rootfs to ${VM_DISK_SIZE}"
qemu-img resize -f raw "$RAW_IMAGE" "$VM_DISK_SIZE"

LOOP_DEV="$(losetup -fP --show "$RAW_IMAGE")"
trap 'umount "$MOUNT_DIR" 2>/dev/null || true; losetup -d "$LOOP_DEV" 2>/dev/null || true' EXIT
sleep 1

# Find ext4 root partition
ROOT_PART=""
for part in "${LOOP_DEV}p2" "${LOOP_DEV}p1"; do
    if [ -b "$part" ] && blkid "$part" 2>/dev/null | grep -q 'TYPE="ext4"'; then
        ROOT_PART="$part"
        break
    fi
done
if [ -z "$ROOT_PART" ]; then
    echo "Cannot find ext4 root partition in $RAW_IMAGE" >&2
    exit 1
fi
PART_NUM="${ROOT_PART##*p}"

parted -s "$LOOP_DEV" resizepart "$PART_NUM" 100%
partprobe "$LOOP_DEV" >/dev/null 2>&1 || true
sleep 1

set +e
e2fsck -f -y "$ROOT_PART" >/dev/null
FSCK_RC=$?
set -e
if [ "$FSCK_RC" -gt 1 ]; then
    echo "e2fsck failed with exit code ${FSCK_RC}" >&2
    exit "$FSCK_RC"
fi
resize2fs "$ROOT_PART" >/dev/null

# Mount and inject config
mkdir -p "$MOUNT_DIR"
mount "$ROOT_PART" "$MOUNT_DIR"
echo "Mounted rootfs: $ROOT_PART"

cp "$INJECT_DIR/network"   "$MOUNT_DIR/etc/config/network"
cp "$INJECT_DIR/dhcp"      "$MOUNT_DIR/etc/config/dhcp"
cp "$INJECT_DIR/firewall"  "$MOUNT_DIR/etc/config/firewall"
cp "$INJECT_DIR/dropbear"  "$MOUNT_DIR/etc/config/dropbear"
cp "$INJECT_DIR/upnpd"     "$MOUNT_DIR/etc/config/upnpd"
cp "$INJECT_DIR/system"    "$MOUNT_DIR/etc/config/system"
cp "$SCRIPT_DIR/vm-bootstrap.sh" "$MOUNT_DIR/root/vm-bootstrap.sh"
cp "$SCRIPT_DIR/socks5.py"       "$MOUNT_DIR/root/socks5.py"
chmod +x "$MOUNT_DIR/root/vm-bootstrap.sh"

if [ -f "$MOUNT_DIR/etc/shadow" ]; then
    sed -i "s|^root:[^:]*:|root:${ROOT_HASH}:|" "$MOUNT_DIR/etc/shadow"
else
    echo "root:${ROOT_HASH}:19000:0:99999:7:::" > "$MOUNT_DIR/etc/shadow"
fi

sync
umount "$MOUNT_DIR"
losetup -d "$LOOP_DEV"
trap - EXIT
echo "Raw image prepared successfully"
EOF_HELPER

    chmod +x "$helper_script"

    echo "Preparing raw image (single sudo for losetup/mount/parted/e2fsck/resize2fs):"
    sudo "$helper_script" \
        "$RAW_IMAGE" \
        "$MOUNT_DIR" \
        "$VM_DISK_SIZE" \
        "$root_hash" \
        "${WORK_DIR}/inject" \
        "$SCRIPT_DIR"
}

# ── disk preparation (no sudo) ──

prepare_disk() {
    if virsh --connect "$LIBVIRT_URI" dominfo "$VM_NAME" >/dev/null 2>&1; then
        echo "Domain already exists: $VM_NAME" >&2
        echo "Use: virsh destroy $VM_NAME && virsh undefine $VM_NAME --remove-all-storage" >&2
        exit 1
    fi

    mkdir -p "$(dirname "$DISK_PATH")"

    if [ -f "$DISK_PATH" ]; then
        echo "Disk already exists: $DISK_PATH" >&2
        exit 1
    fi

    prepare_raw_image
    echo "Converting image to qcow2: $QCOW_IMAGE"
    qemu-img convert -f raw -O qcow2 "$RAW_IMAGE" "$QCOW_IMAGE"
    qemu-img resize "$QCOW_IMAGE" "$VM_DISK_SIZE"
    cp "$QCOW_IMAGE" "$DISK_PATH"
}

# ── VM creation (no sudo) ──

create_vm() {
    echo "Creating VM: $VM_NAME"
    virt-install \
        --connect "$LIBVIRT_URI" \
        --name "$VM_NAME" \
        --memory "$VM_MEMORY_MB" \
        --vcpus "$VM_VCPUS" \
        --disk "path=${DISK_PATH},format=qcow2,bus=virtio" \
        --network "type=direct,source=${PHYSICAL_IFACE},source_mode=bridge,model=virtio" \
        --network "network=${NAT_NETWORK},model=virtio" \
        --os-variant generic \
        --graphics none \
        --serial pty \
        --console pty,target_type=serial \
        --import \
        --autostart \
        --noautoconsole
}

print_summary() {
    echo
    echo "Leigod OpenWrt VM created."
    echo "VM:          $VM_NAME"
    echo "Disk:        $DISK_PATH"
    echo "WAN/macvtap: $PHYSICAL_IFACE (phone UPnP discovery side)"
    echo "Mgmt/SOCKS:  192.168.122.10 (libvirt ${NAT_NETWORK} network, static)"
    echo "Root login:  root / ${ROOT_PASSWORD}"
    echo
    echo "Wait 30-60 seconds for OpenWrt to boot, then:"
    echo "  sshpass -p ${ROOT_PASSWORD} ssh root@192.168.122.10"
    echo "  sh /root/vm-bootstrap.sh"
    echo
    echo "Then point mihomo to 192.168.122.10:1080. See kvm/mihomo-snippet.yaml."
}

main() {
    require_cmd curl
    require_cmd gunzip
    require_cmd qemu-img
    require_cmd virt-install
    require_cmd virsh
    require_cmd losetup
    require_cmd openssl
    require_cmd parted
    require_cmd partprobe
    require_cmd e2fsck
    require_cmd resize2fs
    require_cmd blkid
    require_cmd awk

    mkdir -p "$WORK_DIR"
    ensure_libvirt
    ensure_default_network
    detect_physical_iface
    download_image
    prepare_disk
    create_vm
    print_summary
}

main "$@"
