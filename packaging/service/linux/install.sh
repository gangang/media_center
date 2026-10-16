#!/usr/bin/env bash
#
# 把本地媒体中心注册为 Linux 用户级 systemd 服务。
#
# 用 systemd user unit（~/.config/systemd/user/）而不是系统服务：
# 媒体中心是用户自己的服务，不该需要 root，也不该在系统层面全局可见。
#
# 卸载用同目录的 uninstall.sh。
set -euo pipefail

UNIT="mediacenter.service"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="$(cd "$HERE/.." && pwd)/mediacenter"
UNIT_DIR="$HOME/.config/systemd/user"
UNIT_PATH="$UNIT_DIR/$UNIT"

if [ ! -x "$BIN" ]; then
  echo "找不到可执行文件：$BIN" >&2
  echo "请把 service/ 目录连同上一层的 mediacenter 一起解压后再运行本脚本。" >&2
  exit 1
fi

if ! command -v systemctl >/dev/null 2>&1; then
  echo "这台机器上没有 systemctl，无法用 systemd 自启。" >&2
  echo "可以先手动运行：$BIN -scan" >&2
  exit 1
fi

mkdir -p "$UNIT_DIR"

# 关键细节：systemd user unit 的 PATH 是固定的精简值，不含 /usr/local/bin。
# 如果 ffmpeg 是手动编译装在 /usr/local/bin 的，不补 PATH 就会出现
# "自启后视频没有缩略图、手动跑却正常"这种最难查的现象。
cat > "$UNIT_PATH" <<UNIT_EOF
[Unit]
Description=本地媒体中心（Local Media Center）
# 不写 network-online.target 的强依赖：它需要 NetworkManager-wait-online，
# 很多桌面发行版没启用，强依赖会让服务直接起不来。服务端本身能容忍网络晚到
# （mDNS 失败只记日志），所以只要"排在网络之后"就够。
After=network-online.target

[Service]
Type=simple
# -scan 启动时跑一遍增量索引：只对 size/mtime 变过的文件做实际工作，
# 代价低，换来"关机期间放进来的照片开机就能看到"。
ExecStart=$BIN -scan
Restart=on-failure
RestartSec=10
Environment=PATH=/usr/local/bin:/usr/bin:/bin:/usr/local/sbin:/usr/sbin:/sbin

[Install]
WantedBy=default.target
UNIT_EOF

systemctl --user daemon-reload
systemctl --user enable --now "$UNIT"

# 默认情况下用户级服务会在"该用户所有会话都退出"时被停掉。
# 对一台当服务器用的机器（或者你只是 SSH 上去用一下），这不是期望行为。
# linger 让服务在无人登录时也保持运行；不需要 root，但可能弹一次授权。
#
# 用户名不能直接取 ${USER}：精简环境（容器、部分 systemd/sudo 上下文）里它可能没有定义，
# 而本脚本开了 set -u，直接引用会让脚本在"unit 已经写好、服务已经 enable"之后崩掉 ——
# 用户只看到一句 unbound variable，完全不知道自启其实已经生效了。
# 所以按可靠性依次回退：$USER → id -un → whoami。
LOGIN_USER="${USER:-}"
if [ -z "$LOGIN_USER" ]; then
  LOGIN_USER="$(id -un 2>/dev/null || whoami 2>/dev/null || true)"
fi

LINGER_OK=1
LINGER_WHY=""
if ! command -v loginctl >/dev/null 2>&1; then
  LINGER_OK=0
  LINGER_WHY="这台机器上没有 loginctl"
elif [ -z "$LOGIN_USER" ]; then
  LINGER_OK=0
  LINGER_WHY="没能确定当前用户名"
elif ! loginctl enable-linger "$LOGIN_USER" >/dev/null 2>&1; then
  LINGER_OK=0
  LINGER_WHY="loginctl enable-linger 执行失败"
fi

echo "已安装自启：$UNIT_PATH"
echo "  状态 : systemctl --user status $UNIT"
echo "  日志 : journalctl --user -u $UNIT -f"
echo "  卸载 : $(dirname "$HERE")/service/uninstall.sh"
if [ "$LINGER_OK" -eq 0 ]; then
  echo
  echo "注意：${LINGER_WHY}，服务会在你注销登录后停止。"
  echo "      想让它在无人登录时也一直跑，手动执行一次："
  echo "        sudo loginctl enable-linger ${LOGIN_USER:-\$USER}"
fi
