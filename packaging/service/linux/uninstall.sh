#!/usr/bin/env bash
#
# 移除本地媒体中心的 systemd 用户服务。不会删除数据目录（~/.mediacenter）。
set -euo pipefail

UNIT="mediacenter.service"
UNIT_PATH="$HOME/.config/systemd/user/$UNIT"

if [ ! -f "$UNIT_PATH" ]; then
  echo "没有找到服务单元：$UNIT_PATH"
  echo "（可能本来就没装，或者已经卸载过了）"
  exit 0
fi

# 先停掉再删单元文件，否则 systemd 会记住这个已启用的服务、下次开机继续尝试启动。
systemctl --user disable --now "$UNIT" 2>/dev/null || true
rm -f "$UNIT_PATH"
systemctl --user daemon-reload 2>/dev/null || true

echo "已移除自启：$UNIT_PATH"
echo "数据目录未改动：$HOME/.mediacenter"
