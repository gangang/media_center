#!/usr/bin/env bash
#
# 把本地媒体中心注册为 macOS 登录自启项。
#
# 用用户级 LaunchAgent（~/Library/LaunchAgents/），不需要 sudo —— 媒体中心是
# 用户自己的服务，不该往系统级目录里塞东西，也不该要管理员密码。
#
# 卸载用同目录的 uninstall.sh。
set -euo pipefail

LABEL="ai.mediacenter.server"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="$(cd "$HERE/.." && pwd)/mediacenter"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG_DIR="$HOME/.mediacenter/logs"

if [ ! -x "$BIN" ]; then
  echo "找不到可执行文件：$BIN" >&2
  echo "请把 service/ 目录连同上一层的 mediacenter 一起解压后再运行本脚本。" >&2
  exit 1
fi

mkdir -p "$(dirname "$PLIST")" "$LOG_DIR"

# 关键细节：LaunchAgent 的环境是精简的，PATH 通常只有 /usr/bin:/bin:/usr/sbin:/sbin。
# Homebrew 装的 ffmpeg 在 /opt/homebrew/bin（Apple Silicon）或 /usr/local/bin（Intel），
# 不显式补进 PATH 的话服务端会报"未检测到 ffmpeg"，而手动运行同一个二进制却一切正常 ——
# 这种"自启才出问题"最难查。这里直接把两个常见位置写进 plist。
cat > "$PLIST" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>

    <!-- -scan 在启动时跑一遍增量索引：只对 size 或 mtime 变过的文件做实际工作，
         所以代价很低，换来的是"关机期间放进来的照片开机就能看到"。 -->
    <key>ProgramArguments</key>
    <array>
        <string>$BIN</string>
        <string>-scan</string>
    </array>

    <key>RunAtLoad</key>
    <true/>

    <!-- 崩了自动拉起。ThrottleInterval 防止"端口被占用→退出→重启"变成刷屏：
         日志里如果每 30 秒重复一次 listen ... address already in use，
         说明 8080 被别的程序占了，改 config.json 的 port 或停掉那个程序。 -->
    <key>KeepAlive</key>
    <true/>
    <key>ThrottleInterval</key>
    <integer>30</integer>

    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
    </dict>

    <key>StandardOutPath</key>
    <string>$LOG_DIR/mediacenter.log</string>
    <key>StandardErrorPath</key>
    <string>$LOG_DIR/mediacenter.err.log</string>
</dict>
</plist>
PLIST_EOF

# 已经加载过就先卸掉，否则 bootstrap 会因"已存在"直接失败。
launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true

if ! launchctl bootstrap "gui/$UID" "$PLIST" 2>/dev/null; then
  # 旧版 macOS 没有 bootstrap/bootout，退回已废弃但仍可用的 load。
  launchctl load -w "$PLIST"
fi

echo "已安装自启：$PLIST"
echo "  日志 : $LOG_DIR/mediacenter.log"
echo "  查看 : launchctl print gui/$UID/$LABEL | head -20"
echo "  卸载 : $(dirname "$HERE")/service/uninstall.sh"
