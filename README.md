# leigod-kvm

在 Linux 桌面（CachyOS/Arch Linux）上用 KVM 运行 OpenWrt 虚拟机，安装雷神加速器路由器插件，向宿主机暴露加速通道。

## 为什么需要这个项目

雷神加速器只有 OpenWrt 路由器插件，没有 Linux PC 客户端。如果你没有 OpenWrt 路由器，但想在 Linux 桌面上使用雷神加速游戏，本方案通过 KVM 虚拟机运行 OpenWrt 来实现。

## 方案

- KVM 运行 OpenWrt x86_64 虚拟机，安装雷神路由器插件
- 双网卡：macvtap 接入物理 LAN（手机 UPnP 发现绑定）+ libvirt NAT（宿主机管理）
- **模式 A（备用）：WireGuard 透明网关** — 所有流量经过 VM，雷神自动识别游戏 IP 加速
- **模式 B（默认）：SOCKS5 + mihomo 分流** — 按进程名识别游戏流量，通过 SOCKS5 转发到 VM，不影响 mihomo 其他代理

## 快速开始

```sh
# 1. 安装依赖
sudo pacman -S libvirt qemu-base virt-install dnsmasq curl openssl parted e2fsprogs sshpass wireguard-tools

# 2. 创建并启动 OpenWrt VM
./kvm/setup.sh

# 3. 等待 30-60 秒后 SSH 进 VM 安装雷神
sshpass -p leigod ssh root@192.168.122.10
sh /root/vm-bootstrap.sh

# 4. 手机雷神 APP 发现并绑定 VM

# 5. 模式 B（默认）：mihomo 按进程名分流
#    把 kvm/mihomo-snippet.yaml 合并到 mihomo 配置
#    用 kvm/find-game-process.sh 识别游戏进程名

# 模式 A（备用）：WireGuard 全局隧道
#    ./kvm/wg-up.sh   # 打游戏时启动（暂停 mihomo）
#    ./kvm/wg-down.sh # 打完关闭（恢复 mihomo）
```

## 文件说明

| 文件 | 说明 |
|------|------|
| `kvm/setup.sh` | 宿主机侧：下载 OpenWrt 镜像、注入配置、创建双网卡 VM |
| `kvm/vm-bootstrap.sh` | VM 内：安装雷神 + WireGuard + SOCKS5 + UPnP |
| `kvm/socks5.py` | 轻量 SOCKS5 代理（TCP + UDP ASSOCIATE） |
| `kvm/wg-up.sh` | 模式 A：启动 WireGuard 隧道 |
| `kvm/wg-down.sh` | 模式 A：关闭隧道，恢复 mihomo |
| `kvm/find-game-process.sh` | 识别游戏进程名，用于 mihomo PROCESS-NAME 规则 |
| `kvm/mihomo-snippet.yaml` | mihomo 配置示例（SOCKS5 节点 + 进程名规则） |

## 文档

完整架构、两种模式说明、sudo 使用、踩坑记录和排障指南见 [kvm/README.md](kvm/README.md)。

## 要求

- Arch Linux / CachyOS（其他发行版需调整包管理器命令）
- CPU 支持 VT-x/AMD-V 虚拟化
- 有线网卡（macvtap 不支持 Wi-Fi）
- 用户在 `libvirt` 组中

## 致谢

- [openwrt-leigodacc-manager](https://github.com/miaoermua/openwrt-leigodacc-manager) — 雷神加速器 OpenWrt 插件管理器
- 雷神（武汉）网络技术有限公司 — 路由器插件版权所有者

## License

GPL-2.0
