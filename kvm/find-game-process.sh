#!/usr/bin/env bash
# 实时监控网络连接的进程名，帮助识别需要加速的游戏进程
# 用法: 运行此脚本后启动游戏，观察新增的进程名
set -euo pipefail

echo "监控网络活动进程 (Ctrl+C 退出)"
echo "启动游戏后，观察新增的进程名，加入 mihomo PROCESS-NAME 规则"
echo "=========================================="
echo

# 排除的常见系统/代理进程
EXCLUDE='mihomo|clash|dnsmasq|systemd|NetworkManager|tailscale|kwin|kded|plasma|firefox|chrome|chromium|code|zed|ghostty|fish|bash|sshd|dbus|opencode|node'

prev_pids=""

while true; do
    # TCP + UDP 连接的进程名
    current=$(ss -tunp 2>/dev/null | \
        grep -v "127.0.0.1\|::1\|\[::1\]" | \
        grep "users:" | \
        sed 's/.*users:(("\(.*\)",pid=[0-9]*.*/\1/' | \
        grep -vE "$EXCLUDE" | \
        sort -u)

    # 显示新增的进程
    new_procs=$(comm -23 <(echo "$current") <(echo "$prev_pids") 2>/dev/null || true)
    if [ -n "$new_procs" ]; then
        ts=$(date '+%H:%M:%S')
        while IFS= read -r proc; do
            [ -z "$proc" ] && continue
            # 显示进程名和对应的远程地址
            conns=$(ss -tunp 2>/dev/null | grep "users:((\"${proc}\"" | grep -v "127.0.0.1\|::1" | awk '{print $5, $6}' | head -3)
            echo "[${ts}] + ${proc}"
            echo "$conns" | while IFS= read -r line; do
                [ -n "$line" ] && echo "         -> ${line}"
            done
            echo
        done <<< "$new_procs"
    fi

    prev_pids="$current"
    sleep 2
done
