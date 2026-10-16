#!/usr/bin/env bash
#
# 移除本地媒体中心的自启项。不会删除数据目录（~/.mediacenter），
# 你的索引、缩略图和备份的照片都还在。
set -euo pipefail

LABEL="ai.mediacenter.server"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

if [ ! -f "$PLIST" ]; then
  echo "没有找到自启配置：$PLIST"
  echo "（可能本来就没装，或者已经卸载过了）"
  exit 0
fi

# 先停掉，再删文件。顺序反过来的话进程会继续跑，只是不再自启 ——
# 用户会以为"卸载了但服务还在"，比卸载失败更让人困惑。
launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || launchctl unload -w "$PLIST" 2>/dev/null || true
rm -f "$PLIST"

echo "已移除自启：$PLIST"
echo "数据目录未改动：$HOME/.mediacenter"
