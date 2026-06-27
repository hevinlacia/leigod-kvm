# Leigod KVM

用于：在 CachyOS (Arch Linux) 上用 KVM 运行 OpenWrt 虚拟机安装雷神加速器路由器插件，通过 SOCKS5 代理（默认）或 WireGuard 透明网关（备用）向宿主机暴露加速通道。

触发词：雷神加速器、KVM、OpenWrt、CachyOS、leigod、macvtap、UPnP、WireGuard、mihomo、SOCKS5、游戏加速。

不适用：需要原生 Linux 雷神客户端的场景（雷神只有 OpenWrt 路由器插件，无 PC 客户端）；需要完全无 VM 的方案。

## 架构

```text
CachyOS host
  ┌─────────────────────────────────────────────┐
  │ 模式 B (默认): SOCKS5 + mihomo 分流          │
  │                                             │
  │   mihomo 按进程名 → SOCKS5 192.168.122.10:1080│
  │   → OpenWrt VM → 雷神加速                   │
  │   适合: 只需加速特定游戏, 不影响其他代理      │
  │   游戏进程识别: ./kvm/find-game-process.sh   │
  ├─────────────────────────────────────────────┤
  │ 模式 A (备用): WireGuard 透明网关            │
  │                                             │
  │   所有流量 → wg-leigod 隧道 → OpenWrt VM     │
  │                                ├─ 游戏IP → 雷神加速
  │                                └─ 非游戏 → NAT 直连
  │   打游戏时: ./kvm/wg-up.sh                  │
  │   打完:     ./kvm/wg-down.sh                │
  └─────────────────────────────────────────────┘

OpenWrt VM (KVM)
  eth0: macvtap 绑定物理网卡 — 手机 UPnP 发现/绑定
  eth1: libvirt NAT, 静态 192.168.122.10 — 宿主机管理
  wg0:  WireGuard :51820, 10.10.0.1/24 — 透明网关隧道
  雷神插件 TUN 模式 + SOCKS5 :1080 (默认)
```

为什么双网卡：

- `macvtap` 让 VM 出现在物理 LAN，手机 APP 通过 UPnP/SSDP 发现并绑定。
- `macvtap` 宿主机无法直接访问 VM，所以第二张 libvirt NAT 网卡给宿主机管理用。

## 前置条件

```sh
sudo pacman -S libvirt qemu-base virt-install dnsmasq curl openssl parted e2fsprogs sshpass wireguard-tools
```

> `qemu-base` 提供 `qemu-img` + `qemu-system-x86_64`（headless），不需要 `qemu-full`。
> `wireguard-tools` 提供 `wg` / `wg-quick`，模式 A 必需。
> `sshpass` 用于 SSH 密码登录 VM。`parted` + `e2fsprogs` 用于扩容镜像分区。

确保当前用户在 `libvirt` 组中：

```sh
groups | grep libvirt || sudo usermod -aG libvirt "$USER"
# 加入后需要重新登录或 newgrp libvirt
```

宿主机必须有可用于 macvtap 的物理网卡（非 Wi-Fi）。脚本自动检测默认路由接口。若需指定：

```sh
PHYSICAL_IFACE=enp7s0f1np1 ./kvm/setup.sh
```

### sudo 使用说明

| 场景 | sudo 调用 | 原因 |
|------|----------|------|
| libvirt 服务未运行 | 1 次（一次性） | 启动 systemd 服务 |
| 镜像处理 | 1 次 | losetup/mount/parted/e2fsck/resize2fs |
| `wg-up.sh` | 1 次 | wg-quick up + systemctl stop mihomo |
| `wg-down.sh` | 1 次 | wg-quick down + systemctl start mihomo |

libvirt 操作（`virsh`/`virt-install`）和磁盘写入不需要 sudo（用户在 libvirt 组，磁盘在 `~/.local/share/libvirt/images/`）。

## 部署步骤

### 1. 创建 VM

```sh
git clone git@github.com:hevinlacia/leigod-kvm.git
cd leigod-kvm
./kvm/setup.sh
```

默认镜像 OpenWrt `21.02.7` x86_64 ext4 combined（fw3/iptables 兼容雷神插件）。换镜像：

```sh
IMAGE_URL='https://downloads.immortalwrt.org/releases/23.05.3/targets/x86/64/immortalwrt-23.05.3-x86-64-generic-ext4-combined.img.gz' ./kvm/setup.sh
```

### 2. 安装雷神 + WireGuard

等待 30-60 秒 VM 启动后：

```sh
sshpass -p leigod ssh root@192.168.122.10
sh /root/vm-bootstrap.sh
```

`vm-bootstrap.sh` 会安装：雷神依赖包、雷神官方插件、UPnP、TUN 模式、SOCKS5 服务、WireGuard 服务端。

### 3. 手机绑定

手机与 VM 的 `eth0` 在同一物理局域网。打开雷神 APP → 添加设备 → UPnP 自动发现 VM → 绑定。

## 模式 B：SOCKS5 + mihomo 分流（默认）

适合只需加速特定游戏、不想停止 mihomo 的场景。

**1. 识别游戏进程名**：

```sh
./kvm/find-game-process.sh
# 启动游戏后观察新增的进程名，如 cs2、csgo_linux64
```

**2. 配置 mihomo**：

把 `kvm/mihomo-snippet.yaml` 合并到 mihomo 配置，按需添加游戏进程名：

```yaml
proxies:
  - name: "Leigod-OpenWrt-SOCKS5"
    type: socks5
    server: 192.168.122.10
    port: 1080
    udp: true
    skip-cert-verify: true

rules:
  - PROCESS-NAME,cs2,Game-Acceleration
  - PROCESS-NAME,csgo_linux64,Game-Acceleration
  - PROCESS-NAME,steam,Game-Acceleration
```

规则放在 `GEOIP,private`、`MATCH,DIRECT` 之前。

**为什么用进程名**：游戏连接使用裸 IP UDP，没有域名可匹配，IP 又频繁变动。进程名是唯一稳定的标识，加一次永久有效，TCP/UDP 都覆盖，不影响其他流量。`PROCESS-NAME` 只在 TUN 模式下生效。

## 模式 A：WireGuard 透明网关（备用）

打游戏时所有流量经过 VM，雷神自动识别游戏 IP 并加速，非游戏流量 NAT 直连。体验和真实 OpenWrt 路由器一致。

```sh
# 启动隧道（自动暂停 mihomo）
./kvm/wg-up.sh

# 验证：所有流量现在经过 VM
curl -s http://ip-api.com/json | jq -r .query

# 打完游戏，关闭隧道（自动恢复 mihomo）
./kvm/wg-down.sh
```

**原理**：

- `wg-up.sh` 停止 mihomo（消除 TUN 路由冲突），启动 WireGuard `AllowedIPs=0.0.0.0/0`（接管全部流量）
- VM 内雷神 ipset 自动识别游戏服务器 IP → 走加速节点
- 非游戏流量 → VM NAT → eth0 → 互联网
- `wg-down.sh` 关闭 WireGuard，恢复 mihomo

**为什么不和 mihomo 共存**：mihomo TUN 使用 `ip rule`（fwmark + table 2022）在 priority 5270/9002 拦截所有流量。WireGuard 要接管全部流量必须绕过这些规则，最可靠的方式是停止 mihomo。模式 A 期间不需要 mihomo（VM 已接管全部路由）。

### WireGuard 密钥管理

- VM 服务端密钥：`/etc/wireguard/server.key` + `server.pub`（首次 `vm-bootstrap.sh` 生成）
- 宿主机客户端密钥：`~/.config/wireguard-leigod/privatekey`（首次 `wg-up.sh` 生成）
- `wg-up.sh` 自动通过 SSH 完成密钥交换和 peer 配置

## 限制

- 模式 A 期间 mihomo 暂停，公司 VPN 等依赖 mihomo 的服务不可用
- 模式 B 的 SOCKS5 虽支持 UDP ASSOCIATE，但需要手动添加游戏进程名规则
- macvtap 不支持 Wi-Fi 网卡，宿主机需要有线网卡
- VM 关闭不影响 mihomo（除非正在使用模式 A 隧道）

## 常用命令

```sh
# VM 管理
virsh list --all
virsh console leigod-openwrt
virsh domifaddr leigod-openwrt --source arp
virsh shutdown leigod-openwrt
virsh start leigod-openwrt

# 模式 B（默认）
./kvm/find-game-process.sh  # 识别游戏进程名

# 模式 A（备用）
./kvm/wg-up.sh
./kvm/wg-down.sh
wg show

# VM 内日志
logread -f
tail -f /tmp/leigod-socks5.log
ls /tmp/acc/
```

## 踩坑记录

| 问题 | 原因 | 修复 |
|------|------|------|
| `gunzip: trailing garbage ignored` 中断脚本 | OpenWrt .img.gz 解压后 gunzip 报 warning | 检查 raw image 是否已生成，已生成则继续 |
| `e2fsck` 返回码 1 中断脚本 | e2fsck 退出码 1=已修正错误（正常） | 仅对 >1 的退出码报错 |
| `virtstoraged` 未启动导致 VM 创建失败 | CachyOS 模块化 libvirt 未启动该服务 | `ensure_libvirt` 加入 `virtstoraged.service` |
| libvirt NAT DHCP 不工作 | nftables `guest_input` 链 reject DHCP OFFER | eth1 改用静态 IP `192.168.122.10` |
| SSH 密码登录失败 | `openssl passwd -6` (SHA-512) 不兼容 busybox | 改用 `openssl passwd -1` (MD5) |
| `qemu-img` 缺失 | CachyOS 默认未装 QEMU | `pacman -S qemu-base`（非 qemu-full） |
| macvtap 宿主机无法访问 VM | Linux macvtap 限制（预期行为） | 第二张 NAT 网卡给宿主机管理 |
| 串口交互不可靠 | bash fd/socat 对 PTY 处理不一致 | 使用 `pyserial`（`uv run --with pyserial`） |
| SSH 密钥注入被串口截断 | 串口通信长行被截断 | 使用 `sshpass` 密码方式 SSH |
| `TUNSETSTEERINGEBPF` 警告 | virtio-net eBPF steering 不可用 | 无影响，QEMU 自动回退 |
