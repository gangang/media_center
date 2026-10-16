#!/usr/bin/env bash
#
# 后端 API 全量回归验证。
#
# 覆盖：鉴权三种传参方式、索引与元数据（EXIF 大小端 / 视频 creation_time）、
#       缩略图、HTTP Range 四种形态 + 分段拼接一致性、多音轨 MKV 元数据、错误边界。
#
# 用法：
#   ./scripts/verify-api.sh                       # 默认 http://127.0.0.1:18080
#   ./scripts/verify-api.sh http://host:port
#   MC_TOKEN=xxx ./scripts/verify-api.sh          # 显式指定令牌
#
# 令牌来源优先级：环境变量 MC_TOKEN > 数据目录下的 config.json。
# 数据目录默认为后端启动时 -data 指定的路径；找不到时请用 MC_TOKEN 显式传入。

set -u

BASE="${1:-http://127.0.0.1:18080}"
BASE="${BASE%/}"

# ---------- 解析令牌 ----------
TOK="${MC_TOKEN:-}"
if [ -z "$TOK" ]; then
  for d in "${MC_DATA_DIR:-}" /tmp/mc-data "$HOME/.mediacenter" ./data; do
    [ -n "$d" ] || continue
    if [ -f "$d/config.json" ]; then
      TOK="$(python3 -c "import json,sys;print(json.load(open(sys.argv[1])).get('token',''))" "$d/config.json" 2>/dev/null)"
      [ -n "$TOK" ] && break
    fi
  done
fi
if [ -z "$TOK" ]; then
  echo "错误：找不到访问令牌。请设置 MC_TOKEN 或 MC_DATA_DIR 后重试。" >&2
  exit 2
fi

AUTH="Authorization: Bearer $TOK"
PASS=0; FAIL=0

chk() { # chk <名称> <期望> <实际>
  if [ "$2" = "$3" ]; then
    printf '  \033[32mPASS\033[0m  %-46s %s\n' "$1" "$3"; PASS=$((PASS+1))
  else
    printf '  \033[31mFAIL\033[0m  %-46s got=%s want=%s\n' "$1" "$3" "$2"; FAIL=$((FAIL+1))
  fi
}
note() { if [ "$2" = "1" ]; then printf '  \033[32mPASS\033[0m  %s\n' "$1"; PASS=$((PASS+1)); else printf '  \033[31mFAIL\033[0m  %s\n' "$1"; FAIL=$((FAIL+1)); fi; }
code() { curl -s -o /dev/null -w '%{http_code}' "$@"; }

echo "服务器: $BASE"
echo

echo "=============================================================="
echo " A. 认证 (auth)"
echo "=============================================================="
chk "GET /api/ping (公开路径, 无 token)"    200 "$(code "$BASE/api/ping")"
chk "GET /api/media (无 token -> 401)"      401 "$(code "$BASE/api/media")"
chk "GET /api/media (错误 token -> 401)"    401 "$(code -H 'Authorization: Bearer wrong' "$BASE/api/media")"
chk "GET /api/media (X-Token 头)"           200 "$(code -H "X-Token: $TOK" "$BASE/api/media")"
chk "GET /api/media (?token= 查询参数)"     200 "$(code "$BASE/api/media?token=$TOK")"
chk "GET /api/media (正确 Bearer)"          200 "$(code -H "$AUTH" "$BASE/api/media")"

echo
echo "=============================================================="
echo " B. 索引与元数据 (index / metadata)"
echo "=============================================================="
STATS=$(curl -s -H "$AUTH" "$BASE/api/stats")
echo "  stats: $STATS"
echo "$STATS" | grep -q '"photos"' && note "stats 含 photos 字段" 1 || note "stats 含 photos 字段" 0
echo "$STATS" | grep -q '"videos"' && note "stats 含 videos 字段" 1 || note "stats 含 videos 字段" 0
echo "$STATS" | grep -q '"ffmpeg_available":true' && note "ffmpeg 可用" 1 || note "ffmpeg 可用" 0

LIST=$(curl -s -H "$AUTH" "$BASE/api/media?page=1&pageSize=200")
TOTAL=$(echo "$LIST" | python3 -c 'import sys,json;print(json.load(sys.stdin)["total"])' 2>/dev/null || echo 0)
echo "  /api/media total = $TOTAL"
[ "$TOTAL" -ge 1 ] 2>/dev/null && note "索引非空" 1 || note "索引为空（先扫描一个目录）" 0

echo "$LIST" | grep -q "secret.jpg" && note "隐藏目录文件已排除" 0 || note "隐藏目录文件已排除" 1
echo "$LIST" | grep -q "notes.txt"  && note "非媒体文件已排除" 0   || note "非媒体文件已排除" 1
echo "$LIST" | grep -q "2019-07-14T18:30:00" && note "EXIF 大端 2019-07-14 18:30 正确" 1 || note "EXIF 大端时间缺失（素材未生成？）" 0
echo "$LIST" | grep -q "2023-12-25T09:15:00" && note "EXIF 小端 2023-12-25 09:15 正确" 1 || note "EXIF 小端时间缺失（素材未生成？）" 0

echo
echo "  各条目:"
echo "$LIST" | python3 -c '
import sys,json
for i in json.load(sys.stdin)["items"]:
    print("    id=%-3s %-18s %-6s %-26s %sx%s" % (
        i["id"], i["file_name"], i["media_type"], i.get("taken_at","-"),
        i.get("width",0), i.get("height",0)))
' 2>/dev/null

PID=$(echo "$LIST" | python3 -c 'import sys,json;print(next((i["id"] for i in json.load(sys.stdin)["items"] if i["media_type"]=="photo"), ""))' 2>/dev/null)
VID=$(echo "$LIST" | python3 -c 'import sys,json;print(next((i["id"] for i in json.load(sys.stdin)["items"] if i["media_type"]=="video"), ""))' 2>/dev/null)

echo
echo "=============================================================="
echo " C. 缩略图 (thumbnails)"
echo "=============================================================="
echo "  photo id=${PID:-无}   video id=${VID:-无}"
if [ -n "$PID" ]; then
  chk "GET 照片缩略图 -> 200"  200 "$(code -H "$AUTH" "$BASE/api/media/$PID/thumbnail")"
  chk "缩略图 Content-Type"    "image/jpeg" "$(curl -s -o /dev/null -w '%{content_type}' -H "$AUTH" "$BASE/api/media/$PID/thumbnail")"
  TSZ=$(curl -s -H "$AUTH" "$BASE/api/media/$PID/thumbnail" | wc -c | tr -d ' ')
  echo "  缩略图字节数: $TSZ"
  [ "$TSZ" -gt 500 ] 2>/dev/null && note "缩略图确实有图像数据" 1 || note "缩略图内容过小" 0
  CC=$(curl -s -o /dev/null -w '%{header_json}' -H "$AUTH" "$BASE/api/media/$PID/thumbnail" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("cache-control",[""])[0])' 2>/dev/null)
  echo "  缩略图 Cache-Control: $CC"
  echo "$CC" | grep -q "immutable" && note "缩略图带 immutable 缓存头" 1 || note "缩略图缺 immutable" 0
else
  echo "  (无照片，跳过)"
fi
if [ -n "$VID" ]; then
  chk "GET 视频缩略图 -> 200"  200 "$(code -H "$AUTH" "$BASE/api/media/$VID/thumbnail")"
fi

echo
echo "=============================================================="
echo " D. HTTP Range (视频拖动/流式播放)"
echo "=============================================================="
if [ -n "$VID" ]; then
  U="$BASE/api/media/$VID/original"
  H=$(curl -s -I -H "$AUTH" "$U")
  echo "  --- HEAD 响应头 ---"
  echo "$H" | grep -iE "^(HTTP|accept-ranges|content-length|content-type)" | tr -d '\r' | sed 's/^/    /'
  echo "$H" | grep -qi "accept-ranges: bytes" && note "HEAD 返回 Accept-Ranges: bytes" 1 || note "缺 Accept-Ranges" 0
  chk "HEAD original -> 200" 200 "$(code -I -H "$AUTH" "$U")"

  R1=$(curl -s -o /dev/null -w '%{http_code} %{size_download}' -H "$AUTH" -H 'Range: bytes=0-' "$U")
  echo "  Range: bytes=0-           -> $R1"
  [ "${R1%% *}" = "206" ] && note "开放式 Range 返回 206" 1 || note "开放式 Range 未返回 206" 0

  R2=$(curl -s -o /dev/null -w '%{http_code} %{size_download}' -H "$AUTH" -H 'Range: bytes=100000-101023' "$U")
  echo "  Range: bytes=100000-101023 -> $R2"
  { [ "${R2%% *}" = "206" ] && [ "${R2##* }" = "1024" ]; } && note "区间 Range 206 且长度 1024" 1 || note "区间 Range 异常" 0

  R3=$(curl -s -o /dev/null -w '%{http_code} %{size_download}' -H "$AUTH" -H 'Range: bytes=-1024' "$U")
  echo "  Range: bytes=-1024        -> $R3"
  [ "${R3%% *}" = "206" ] && note "后缀 Range 返回 206" 1 || note "后缀 Range 异常" 0

  chk "Range 越界 -> 416" 416 "$(code -H "$AUTH" -H 'Range: bytes=99999999999-' "$U")"
  CR=$(curl -s -D - -o /dev/null -H "$AUTH" -H 'Range: bytes=0-99' "$U" | grep -i '^content-range' | tr -d '\r')
  echo "  $CR"
  echo "$CR" | grep -q "bytes 0-99/" && note "Content-Range 格式正确" 1 || note "Content-Range 异常" 0

  # 分段拉取拼接后必须与整体字节一致——这条能抓出 Range 边界错位
  #
  # 切分点必须由实际文件大小推导：早先这里硬编码 2500000，而列表里排在最前的
  # 视频（无 creation_time、回落到文件时间）只有 768KB，于是第二段请求直接越界
  # 返回 416，拼接结果必然不一致——一条永远失败的断言等于没有断言。
  VSZ=$(curl -s -o /dev/null -w '%{size_download}' -H "$AUTH" "$U")
  SPLIT=$((VSZ / 2))
  echo "  视频字节数: $VSZ  切分点: $SPLIT"
  FULL_SHA=$(curl -s -H "$AUTH" "$U" | shasum -a 256 | cut -d' ' -f1)
  TMP=$(mktemp)
  { curl -s -H "$AUTH" -H "Range: bytes=0-$((SPLIT-1))" "$U"; curl -s -H "$AUTH" -H "Range: bytes=$SPLIT-" "$U"; } > "$TMP"
  STITCH_SHA=$(shasum -a 256 "$TMP" | cut -d' ' -f1)
  rm -f "$TMP"
  echo "  整体 sha256:     $FULL_SHA"
  echo "  分段拼接 sha256: $STITCH_SHA"
  [ "$FULL_SHA" = "$STITCH_SHA" ] && note "分段 Range 拼接后与整体字节一致" 1 || note "分段拼接内容不一致" 0
else
  echo "  (无视频，跳过)"
fi

echo
echo "=============================================================="
echo " E. 多音轨 MKV 元数据"
echo "=============================================================="
MKV=$(curl -s -H "$AUTH" "$BASE/api/media?type=video&pageSize=200" | python3 -c '
import sys,json
for i in json.load(sys.stdin)["items"]:
    if i["file_name"].endswith(".mkv"):
        print(i["id"], i.get("mime_type",""), "%sx%s"%(i.get("width"),i.get("height")),
              i.get("video_codec",""), i.get("audio_codec",""), i.get("duration_ms",0)); break
' 2>/dev/null)
if [ -n "$MKV" ]; then
  echo "  MKV: id/mime/WxH/vcodec/acodec/duration = $MKV"
  echo "$MKV" | grep -q "video/x-matroska" && note "MKV 识别为 video/x-matroska" 1 || note "MKV mime 异常" 0
  echo "$MKV" | grep -qi "h264" && note "MKV 视频编码 h264 已解析" 1 || note "MKV 视频编码缺失" 0
  echo "$MKV" | grep -qi "aac"  && note "MKV 音频编码 aac 已解析" 1 || note "MKV 音频编码缺失" 0
else
  echo "  (无 mkv，跳过)"
fi

echo
echo "=============================================================="
echo " F. 错误处理与边界"
echo "=============================================================="
chk "GET 不存在的 id -> 404"      404 "$(code -H "$AUTH" "$BASE/api/media/999999")"
chk "GET 非法 id -> 400"          400 "$(code -H "$AUTH" "$BASE/api/media/abc")"
chk "GET /api/scan/status -> 200" 200 "$(code -H "$AUTH" "$BASE/api/scan/status")"
chk "GET /api/folders -> 200"     200 "$(code -H "$AUTH" "$BASE/api/folders")"
chk "GET / (内置状态页) -> 200"    200 "$(code "$BASE/")"

echo
echo "=============================================================="
printf " 结果: PASS=%d  FAIL=%d\n" "$PASS" "$FAIL"
echo "=============================================================="
[ "$FAIL" -eq 0 ] && echo "✅ 全部通过" || echo "❌ 存在失败项"
[ "$FAIL" -eq 0 ]
