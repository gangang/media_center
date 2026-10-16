#!/usr/bin/env bash
#
# 手机备份上传接口的端到端回归验证。
#
# 自带服务端与独立数据目录：跑完自动清理，不污染 ~/.mediacenter。
#
# 覆盖：分片上传、断点续传、秒传去重、哈希校验、同名冲突改名、
#       参数与越界校验、取消清理、媒体库目录保护、上传后即可播放与拖动。
#
# 用法：
#   ./scripts/verify-upload.sh              # 默认端口 18091
#   MC_PORT=19000 ./scripts/verify-upload.sh
#   GO_BIN=/path/to/go ./scripts/verify-upload.sh
#
# 前置：ffmpeg（生成测试素材）、python3、curl。

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
MC_DIR="$(cd "$HERE/.." && pwd)"
BACKEND="$MC_DIR/backend"

PORT="${MC_PORT:-18091}"
BASE="http://127.0.0.1:$PORT"

WORK="$(mktemp -d)"
DATA="$WORK/data"
MEDIA="$WORK/media"
SERVER_LOG="$WORK/server.log"
BIN="$WORK/mcserver"
SRV_PID=""

cleanup() {
  if [ -n "$SRV_PID" ]; then
    kill "$SRV_PID" 2>/dev/null
    wait "$SRV_PID" 2>/dev/null
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT

PASS=0; FAIL=0
chk() { # chk <名称> <期望> <实际>
  if [ "$2" = "$3" ]; then
    printf '  \033[32mPASS\033[0m  %-48s %s\n' "$1" "$3"; PASS=$((PASS+1))
  else
    printf '  \033[31mFAIL\033[0m  %-48s got=%s want=%s\n' "$1" "$3" "$2"; FAIL=$((FAIL+1))
  fi
}
note() { if [ "$2" = "1" ]; then printf '  \033[32mPASS\033[0m  %s\n' "$1"; PASS=$((PASS+1)); else printf '  \033[31mFAIL\033[0m  %s\n' "$1"; FAIL=$((FAIL+1)); fi; }
code() { curl -s -o /dev/null -w '%{http_code}' "$@"; }
jq_() { python3 -c "import sys,json;d=json.load(sys.stdin);print($1)" 2>/dev/null; }

# 与后端 scanner.ContentHash 必须完全一致：sha256(小端 size || 前 256KiB || 后 256KiB)
mc_hash() {
  python3 - "$1" <<'PY'
import hashlib, struct, sys
data = open(sys.argv[1], "rb").read()
h = hashlib.sha256()
h.update(struct.pack("<Q", len(data)))
h.update(data[:262144])
if len(data) > 262144:
    h.update(data[-262144:])
print(h.hexdigest())
PY
}

# 把文件按固定大小切片，输出 <目录>/chunk_0 .. chunk_N
mc_split() { # mc_split <源文件> <分片大小> <输出目录>
  python3 - "$1" "$2" "$3" <<'PY'
import os, sys
src, size, outdir = sys.argv[1], int(sys.argv[2]), sys.argv[3]
data = open(src, "rb").read()
os.makedirs(outdir, exist_ok=True)
for i, off in enumerate(range(0, len(data), size)):
    open(os.path.join(outdir, "chunk_%d" % i), "wb").write(data[off:off + size])
PY
}

# ------------------------------------------------------------------ 准备 --

GO_BIN="${GO_BIN:-}"
if [ -z "$GO_BIN" ]; then
  if command -v go >/dev/null 2>&1; then
    GO_BIN="$(command -v go)"
  else
    for c in "$HOME/.workbuddy-ai/binaries/go/go/bin/go" /usr/local/go/bin/go /opt/homebrew/bin/go; do
      [ -x "$c" ] && GO_BIN="$c" && break
    done
  fi
fi
if [ -z "$GO_BIN" ]; then
  echo "错误：找不到 go，请用 GO_BIN=/path/to/go 指定。" >&2
  exit 2
fi

# 国内网络下 proxy.golang.org 常常不可达；未显式设置时给一个可用的默认值。
export GOPROXY="${GOPROXY:-https://goproxy.cn,direct}"
export GOSUMDB="${GOSUMDB:-sum.golang.google.cn}"

echo "==> 编译后端"
if ! (cd "$BACKEND" && "$GO_BIN" build -o "$BIN" .) ; then
  echo "编译失败，无法继续。" >&2
  exit 1
fi

echo "==> 生成测试素材"
mkdir -p "$MEDIA"
ffmpeg -v error -y -f lavfi -i "testsrc2=size=640x480:rate=1" -frames:v 1 "$MEDIA/photo.jpg"
# 大一点的视频：确保分片数 > 1，能真正走通续传与补发逻辑
ffmpeg -v error -y -f lavfi -i "testsrc2=size=640x480:rate=25:duration=6" \
  -c:v libx264 -preset ultrafast -pix_fmt yuv420p "$MEDIA/clip.mp4"
ffmpeg -v error -y -f lavfi -i "smptebars=size=640x480:rate=1" -frames:v 1 "$MEDIA/photo2.jpg"

PHOTO="$MEDIA/photo.jpg"
PHOTO2="$MEDIA/photo2.jpg"
VIDEO="$MEDIA/clip.mp4"
PHOTO_HASH="$(mc_hash "$PHOTO")"
PSIZE=$(wc -c < "$PHOTO" | tr -d ' ')
P2SIZE=$(wc -c < "$PHOTO2" | tr -d ' ')
VSIZE=$(wc -c < "$VIDEO" | tr -d ' ')
echo "    photo.jpg  $PSIZE 字节"
echo "    photo2.jpg $P2SIZE 字节"
echo "    clip.mp4   $VSIZE 字节"

echo "==> 启动服务端（数据目录 $DATA）"
"$BIN" -data "$DATA" -port "$PORT" -mdns=false >"$SERVER_LOG" 2>&1 &
SRV_PID=$!

for _ in $(seq 1 60); do
  [ "$(code "$BASE/api/ping")" = "200" ] && break
  if ! kill -0 "$SRV_PID" 2>/dev/null; then
    echo "服务端启动失败：" >&2; cat "$SERVER_LOG" >&2; exit 1
  fi
  sleep 0.25
done
if [ "$(code "$BASE/api/ping")" != "200" ]; then
  echo "服务端未在预期时间内就绪：" >&2; cat "$SERVER_LOG" >&2; exit 1
fi

TOK="$(python3 -c "import json;print(json.load(open('$DATA/config.json'))['token'])")"
AUTH="Authorization: Bearer $TOK"
CT="Content-Type: application/json"
LIB="$DATA/library"
UPLOADS="$DATA/uploads"
temp_count() { ls -1 "$UPLOADS" 2>/dev/null | wc -l | tr -d ' '; }

echo "服务器: $BASE"
echo

# --------------------------------------------------------------- A. 鉴权 --

echo "=============================================================="
echo " A. 鉴权与参数校验"
echo "=============================================================="
chk "POST /api/uploads (无 token -> 401)" 401 \
  "$(code -X POST -H "$CT" -d '{"file_name":"a.jpg","file_size":99999}' "$BASE/api/uploads")"
chk "GET 不存在的会话 -> 404" 404 "$(code -H "$AUTH" "$BASE/api/uploads/deadbeef")"
chk "非媒体扩展名 -> 415" 415 \
  "$(code -X POST -H "$AUTH" -H "$CT" -d '{"file_name":"notes.txt","file_size":99999}' "$BASE/api/uploads")"
chk "路径穿越文件名 -> 400" 400 \
  "$(code -X POST -H "$AUTH" -H "$CT" -d '{"file_name":"../../evil.jpg","file_size":99999}' "$BASE/api/uploads")"
chk "带子目录的文件名 -> 400" 400 \
  "$(code -X POST -H "$AUTH" -H "$CT" -d '{"file_name":"a/b.jpg","file_size":99999}' "$BASE/api/uploads")"
chk "file_name 为空 -> 400" 400 \
  "$(code -X POST -H "$AUTH" -H "$CT" -d '{"file_name":"","file_size":99999}' "$BASE/api/uploads")"
chk "file_size 过小 -> 400" 400 \
  "$(code -X POST -H "$AUTH" -H "$CT" -d '{"file_name":"a.jpg","file_size":10}' "$BASE/api/uploads")"
chk "非法 JSON -> 400" 400 \
  "$(code -X POST -H "$AUTH" -H "$CT" -d 'not-json' "$BASE/api/uploads")"
chk "参数校验未产生临时文件" "0" "$(temp_count)"

# ------------------------------------------------------- B. 完整分片上传 --

echo
echo "=============================================================="
echo " B. 完整上传（照片，单分片）"
echo "=============================================================="
INIT=$(curl -s -X POST -H "$AUTH" -H "$CT" \
  -d "{\"file_name\":\"photo.jpg\",\"file_size\":$PSIZE}" "$BASE/api/uploads")
UID1=$(echo "$INIT" | jq_ 'd["upload_id"]')
CKSZ1=$(echo "$INIT" | jq_ 'd["chunk_size"]')
CKN1=$(echo "$INIT" | jq_ 'd["chunk_count"]')
note "init 返回 upload_id" "$([ -n "$UID1" ] && echo 1 || echo 0)"
chk "单分片文件 chunk_count = 1" "1" "$CKN1"
chk "init 后 received 为空" "0" "$(echo "$INIT" | jq_ 'len(d["received"])')"
chk "init 后 status = pending" "pending" "$(echo "$INIT" | jq_ 'd["status"]')"
note "init 后临时文件已预分配" "$([ -f "$UPLOADS/$UID1.part" ] && echo 1 || echo 0)"
chk "预分配大小等于 file_size" "$PSIZE" "$(wc -c < "$UPLOADS/$UID1.part" | tr -d ' ')"

mkdir -p "$WORK/p1"
mc_split "$PHOTO" "$CKSZ1" "$WORK/p1"

chk "分片大小不符 -> 400" 400 \
  "$(code -X PUT -H "$AUTH" --data-binary @/dev/null "$BASE/api/uploads/$UID1/chunks/0")"
chk "分片序号越界 -> 400" 400 \
  "$(code -X PUT -H "$AUTH" --data-binary @"$WORK/p1/chunk_0" "$BASE/api/uploads/$UID1/chunks/9")"

PUT1=$(curl -s -X PUT -H "$AUTH" --data-binary @"$WORK/p1/chunk_0" \
  "$BASE/api/uploads/$UID1/chunks/0")
chk "PUT 分片后 done=true" "True" "$(echo "$PUT1" | jq_ 'd["done"]')"

# 重复发送同一分片，计数不应被灌水
PUT_AGAIN=$(curl -s -X PUT -H "$AUTH" --data-binary @"$WORK/p1/chunk_0" \
  "$BASE/api/uploads/$UID1/chunks/0")
chk "重复发送分片后计数不变" "$CKN1" "$(echo "$PUT_AGAIN" | jq_ 'd["received_chunks"]')"

DONE1=$(curl -s -X POST -H "$AUTH" "$BASE/api/uploads/$UID1/complete")
MID1=$(echo "$DONE1" | jq_ 'd["media"]["id"]')
note "complete 返回 media.id ($MID1)" "$([ -n "$MID1" ] && [ "$MID1" != "None" ] && echo 1 || echo 0)"
chk "上传媒体的 origin = upload" "upload" "$(echo "$DONE1" | jq_ 'd["media"]["origin"]')"
chk "照片宽高已解析" "640x480" "$(echo "$DONE1" | jq_ 'd["media"]["width"]')x$(echo "$DONE1" | jq_ 'd["media"]["height"]')"
chk "mime 识别为 jpeg" "image/jpeg" "$(echo "$DONE1" | jq_ 'd["media"]["mime_type"]')"

chk "complete 幂等（重复调用仍 200）" 200 \
  "$(code -X POST -H "$AUTH" "$BASE/api/uploads/$UID1/complete")"
chk "完成后再发分片 -> 409" 409 \
  "$(code -X PUT -H "$AUTH" --data-binary @"$WORK/p1/chunk_0" "$BASE/api/uploads/$UID1/chunks/0")"
chk "完成后临时文件已清理" "0" "$(temp_count)"

LANDED=$(find "$LIB" -type f -name 'photo.jpg' | head -1)
note "文件已落入媒体库 ($LANDED)" "$([ -n "$LANDED" ] && echo 1 || echo 0)"
if [ -n "$LANDED" ]; then
  chk "落盘字节数与源文件一致" "$PSIZE" "$(wc -c < "$LANDED" | tr -d ' ')"
  chk "落盘内容 sha256 一致" "$(shasum -a 256 "$PHOTO" | cut -d' ' -f1)" \
    "$(shasum -a 256 "$LANDED" | cut -d' ' -f1)"
  chk "按月分目录存放" "1" \
    "$(find "$LIB" -type f -path '*/20*/*/photo.jpg' | wc -l | tr -d ' ')"
fi

chk "上传后缩略图可生成 -> 200" 200 "$(code -H "$AUTH" "$BASE/api/media/$MID1/thumbnail")"
chk "上传后原图可下载 -> 200" 200 "$(code -H "$AUTH" "$BASE/api/media/$MID1/original")"
chk "原图下载字节数一致" "$PSIZE" \
  "$(curl -s -H "$AUTH" "$BASE/api/media/$MID1/original" | wc -c | tr -d ' ')"
chk "?origin=upload 能查到该媒体" "True" \
  "$(curl -s -H "$AUTH" "$BASE/api/media?origin=upload" | jq_ "any(i['id']==$MID1 for i in d['items'])")"
chk "?origin=scan 查不到上传的媒体" "True" \
  "$(curl -s -H "$AUTH" "$BASE/api/media?origin=scan" | jq_ "not any(i['id']==$MID1 for i in d['items'])")"

# ---------------------------------------------------------- C. 秒传去重 --

echo
echo "=============================================================="
echo " C. 秒传（内容去重）"
echo "=============================================================="
DEDUP=$(curl -s -X POST -H "$AUTH" -H "$CT" \
  -d "{\"file_name\":\"photo-again.jpg\",\"file_size\":$PSIZE,\"content_hash\":\"$PHOTO_HASH\"}" \
  "$BASE/api/uploads")
chk "带已知 hash 的 init 标记 dedup = true" "True" "$(echo "$DEDUP" | jq_ 'd["dedup"]')"
chk "秒传返回同一个 media id" "$MID1" "$(echo "$DEDUP" | jq_ 'd["media"]["id"]')"
chk "秒传未产生上传会话" "0" "$(temp_count)"
chk "秒传未落盘新文件" "0" "$(find "$LIB" -type f -name 'photo-again.jpg' | wc -l | tr -d ' ')"

# 非 64 位十六进制的 hash 视为"未提供"，仍应正常建立会话，而不是报错
BADHASH=$(curl -s -X POST -H "$AUTH" -H "$CT" \
  -d "{\"file_name\":\"badhash.jpg\",\"file_size\":$PSIZE,\"content_hash\":\"zzzz\"}" \
  "$BASE/api/uploads")
UIDBAD=$(echo "$BADHASH" | jq_ 'd["upload_id"]')
note "非法 hash 被忽略，仍建立上传会话" "$([ -n "$UIDBAD" ] && echo 1 || echo 0)"
chk "非法 hash 未触发秒传" "False" "$(echo "$BADHASH" | jq_ '"dedup" in d')"
[ -n "$UIDBAD" ] && curl -s -o /dev/null -X DELETE -H "$AUTH" "$BASE/api/uploads/$UIDBAD"

# ---------------------------------------------------------- D. 断点续传 --

echo
echo "=============================================================="
echo " D. 断点续传（视频，多分片）"
echo "=============================================================="
INITV=$(curl -s -X POST -H "$AUTH" -H "$CT" \
  -d "{\"file_name\":\"clip.mp4\",\"file_size\":$VSIZE,\"chunk_size\":262144}" "$BASE/api/uploads")
UID2=$(echo "$INITV" | jq_ 'd["upload_id"]')
VKSZ=$(echo "$INITV" | jq_ 'd["chunk_size"]')
VKN=$(echo "$INITV" | jq_ 'd["chunk_count"]')
note "视频被切成多个分片 (chunk_count=$VKN)" "$([ "$VKN" -gt 1 ] 2>/dev/null && echo 1 || echo 0)"

mkdir -p "$WORK/v"
mc_split "$VIDEO" "$VKSZ" "$WORK/v"

# 只发分片 1，模拟中途断线
curl -s -o /dev/null -X PUT -H "$AUTH" --data-binary @"$WORK/v/chunk_1" \
  "$BASE/api/uploads/$UID2/chunks/1"
ST=$(curl -s -H "$AUTH" "$BASE/api/uploads/$UID2")
chk "断点后 received 只含分片 1" "[1]" "$(echo "$ST" | jq_ 'd["received"]')"
chk "断点后 status = pending" "pending" "$(echo "$ST" | jq_ 'd["status"]')"
chk "断点后 received_chunks = 1" "1" "$(echo "$ST" | jq_ 'd["received_chunks"]')"

MISS=$(curl -s -X POST -H "$AUTH" "$BASE/api/uploads/$UID2/complete")
chk "分片不全时 complete -> 409" 409 \
  "$(code -X POST -H "$AUTH" "$BASE/api/uploads/$UID2/complete")"
chk "409 响应 missing 含分片 0" "True" "$(echo "$MISS" | jq_ '0 in d["missing"]')"
chk "409 响应 missing 不含已收到的 1" "True" "$(echo "$MISS" | jq_ '1 not in d["missing"]')"
chk "409 后会话仍为 pending" "pending" \
  "$(curl -s -H "$AUTH" "$BASE/api/uploads/$UID2" | jq_ 'd["status"]')"

# 补发剩余分片（跳过已收到的 1）
i=0
while [ "$i" -lt "$VKN" ]; do
  if [ "$i" != "1" ]; then
    curl -s -o /dev/null -X PUT -H "$AUTH" --data-binary @"$WORK/v/chunk_$i" \
      "$BASE/api/uploads/$UID2/chunks/$i"
  fi
  i=$((i+1))
done

DONE2=$(curl -s -X POST -H "$AUTH" "$BASE/api/uploads/$UID2/complete")
MID2=$(echo "$DONE2" | jq_ 'd["media"]["id"]')
note "续传后 complete 成功 (id=$MID2)" "$([ -n "$MID2" ] && [ "$MID2" != "None" ] && echo 1 || echo 0)"
chk "视频 origin = upload" "upload" "$(echo "$DONE2" | jq_ 'd["media"]["origin"]')"
chk "视频 mime 正确" "video/mp4" "$(echo "$DONE2" | jq_ 'd["media"]["mime_type"]')"
chk "视频宽高已解析" "640x480" "$(echo "$DONE2" | jq_ 'd["media"]["width"]')x$(echo "$DONE2" | jq_ 'd["media"]["height"]')"

if [ "$(curl -s -H "$AUTH" "$BASE/api/stats" | jq_ 'd["ffprobe_available"]')" = "True" ]; then
  DUR=$(echo "$DONE2" | jq_ 'd["media"]["duration_ms"]')
  note "视频时长已解析 (${DUR}ms)" "$([ "$DUR" -gt 0 ] 2>/dev/null && echo 1 || echo 0)"
else
  echo "  (未检测到 ffprobe，跳过时长断言)"
fi

chk "上传视频字节级一致" "$(shasum -a 256 "$VIDEO" | cut -d' ' -f1)" \
  "$(curl -s -H "$AUTH" "$BASE/api/media/$MID2/original" | shasum -a 256 | cut -d' ' -f1)"
chk "上传视频支持 Range -> 206" 206 \
  "$(code -H "$AUTH" -H 'Range: bytes=0-1023' "$BASE/api/media/$MID2/original")"
RNG=$(curl -s -o /dev/null -w '%{size_download}' -H "$AUTH" -H 'Range: bytes=1000-2023' \
  "$BASE/api/media/$MID2/original")
chk "区间 Range 长度为 1024" "1024" "$RNG"

# ---------------------------------------------------- E. 哈希校验与失败 --

echo
echo "=============================================================="
echo " E. 哈希校验与失败处理"
echo "=============================================================="
BADHASH="$(printf '0%.0s' $(seq 1 64))"
INITE=$(curl -s -X POST -H "$AUTH" -H "$CT" \
  -d "{\"file_name\":\"corrupt.jpg\",\"file_size\":$PSIZE,\"content_hash\":\"$BADHASH\"}" \
  "$BASE/api/uploads")
UID3=$(echo "$INITE" | jq_ 'd["upload_id"]')
mkdir -p "$WORK/e"
mc_split "$PHOTO" "$(echo "$INITE" | jq_ 'd["chunk_size"]')" "$WORK/e"
curl -s -o /dev/null -X PUT -H "$AUTH" --data-binary @"$WORK/e/chunk_0" \
  "$BASE/api/uploads/$UID3/chunks/0"
chk "哈希不符时 complete -> 422" 422 \
  "$(code -X POST -H "$AUTH" "$BASE/api/uploads/$UID3/complete")"
chk "校验失败后 status = failed" "failed" \
  "$(curl -s -H "$AUTH" "$BASE/api/uploads/$UID3" | jq_ 'd["status"]')"
chk "校验失败的文件未进入媒体库" "0" \
  "$(find "$LIB" -type f -name 'corrupt.jpg' | wc -l | tr -d ' ')"
curl -s -o /dev/null -X DELETE -H "$AUTH" "$BASE/api/uploads/$UID3"
chk "失败会话取消后临时文件清理" "0" "$(temp_count)"

# ------------------------------------------------------------ F. 同名冲突 --

echo
echo "=============================================================="
echo " F. 同名文件冲突与内容去重"
echo "=============================================================="
INIT2=$(curl -s -X POST -H "$AUTH" -H "$CT" \
  -d "{\"file_name\":\"photo.jpg\",\"file_size\":$P2SIZE}" "$BASE/api/uploads")
UID4=$(echo "$INIT2" | jq_ 'd["upload_id"]')
mkdir -p "$WORK/p2"
mc_split "$PHOTO2" "$(echo "$INIT2" | jq_ 'd["chunk_size"]')" "$WORK/p2"
curl -s -o /dev/null -X PUT -H "$AUTH" --data-binary @"$WORK/p2/chunk_0" \
  "$BASE/api/uploads/$UID4/chunks/0"
DONE4=$(curl -s -X POST -H "$AUTH" "$BASE/api/uploads/$UID4/complete")
MID4=$(echo "$DONE4" | jq_ 'd["media"]["id"]')
chk "同名文件自动改名" "1" "$(find "$LIB" -type f -name 'photo (1).jpg' | wc -l | tr -d ' ')"
chk "原文件未被覆盖" "1" "$(find "$LIB" -type f -name 'photo.jpg' | wc -l | tr -d ' ')"
chk "两个媒体记录 id 不同" "True" \
  "$([ -n "$MID4" ] && [ "$MID4" != "$MID1" ] && echo True || echo False)"
chk "同名不同内容未触发秒传" "False" "$(echo "$DONE4" | jq_ 'd["dedup"]')"

# 相同内容再次上传（客户端未声明 hash）也应在 complete 阶段被识别为重复
INIT5=$(curl -s -X POST -H "$AUTH" -H "$CT" \
  -d "{\"file_name\":\"photo3.jpg\",\"file_size\":$P2SIZE}" "$BASE/api/uploads")
UID5=$(echo "$INIT5" | jq_ 'd["upload_id"]')
curl -s -o /dev/null -X PUT -H "$AUTH" --data-binary @"$WORK/p2/chunk_0" \
  "$BASE/api/uploads/$UID5/chunks/0"
DONE5=$(curl -s -X POST -H "$AUTH" "$BASE/api/uploads/$UID5/complete")
chk "complete 阶段识别出重复内容" "True" "$(echo "$DONE5" | jq_ 'd["dedup"]')"
chk "重复内容未落盘新文件" "0" "$(find "$LIB" -type f -name 'photo3.jpg' | wc -l | tr -d ' ')"
chk "重复内容返回已存在的 media id" "$MID4" "$(echo "$DONE5" | jq_ 'd["media"]["id"]')"

# ------------------------------------------------------------ G. 取消清理 --

echo
echo "=============================================================="
echo " G. 取消与清理"
echo "=============================================================="
INITC=$(curl -s -X POST -H "$AUTH" -H "$CT" \
  -d "{\"file_name\":\"cancelme.jpg\",\"file_size\":$PSIZE}" "$BASE/api/uploads")
UID6=$(echo "$INITC" | jq_ 'd["upload_id"]')
note "取消前存在临时文件" "$([ -f "$UPLOADS/$UID6.part" ] && echo 1 || echo 0)"
chk "DELETE 取消 -> 200" 200 "$(code -X DELETE -H "$AUTH" "$BASE/api/uploads/$UID6")"
note "取消后临时文件已删除" "$([ ! -f "$UPLOADS/$UID6.part" ] && echo 1 || echo 0)"
chk "取消后查询会话 -> 404" 404 "$(code -H "$AUTH" "$BASE/api/uploads/$UID6")"
chk "重复取消 -> 404" 404 "$(code -X DELETE -H "$AUTH" "$BASE/api/uploads/$UID6")"

# ------------------------------------------------------- H. 目录与统计 --

echo
echo "=============================================================="
echo " H. 媒体库目录保护与统计"
echo "=============================================================="
LIBID=$(curl -s -H "$AUTH" "$BASE/api/folders" | python3 -c "
import sys, json, os
for f in json.load(sys.stdin)['items']:
    if os.path.realpath(f['path']) == os.path.realpath('$LIB'):
        print(f['id']); break
" 2>/dev/null)
note "媒体库已自动注册为扫描目录 (id=$LIBID)" "$([ -n "$LIBID" ] && echo 1 || echo 0)"
if [ -n "$LIBID" ]; then
  chk "删除媒体库目录被拒绝 -> 409" 409 "$(code -X DELETE -H "$AUTH" "$BASE/api/folders/$LIBID")"
  chk "拒绝后目录仍然存在" "1" \
    "$(curl -s -H "$AUTH" "$BASE/api/folders" | jq_ "sum(1 for f in d['items'] if f['id']==$LIBID)")"
fi

STATS=$(curl -s -H "$AUTH" "$BASE/api/stats")
chk "stats 含 uploaded 字段" "True" "$(echo "$STATS" | jq_ '"uploaded" in d')"
chk "uploaded 计数 = 3（照片/改名照片/视频）" "3" "$(echo "$STATS" | jq_ 'd["uploaded"]')"

# 触发一次真实扫描，确认扫描不会覆盖 origin，也不会产生重复记录
chk "触发一次扫描 -> 202" 202 \
  "$(code -X POST -H "$AUTH" -H "$CT" -d '{}' "$BASE/api/scan/start")"
for _ in $(seq 1 40); do
  [ "$(curl -s -H "$AUTH" "$BASE/api/scan/status" | jq_ 'd["running"]')" = "False" ] && break
  sleep 0.25
done
chk "扫描后 origin 仍为 upload" "upload" \
  "$(curl -s -H "$AUTH" "$BASE/api/media/$MID1" | jq_ 'd["origin"]')"
chk "扫描后上传媒体未重复" "3" \
  "$(curl -s -H "$AUTH" "$BASE/api/media?origin=upload" | jq_ 'd["total"]')"
chk "扫描后 uploaded 计数仍为 3" "3" \
  "$(curl -s -H "$AUTH" "$BASE/api/stats" | jq_ 'd["uploaded"]')"

echo
echo "=============================================================="
printf " 结果: PASS=%d  FAIL=%d\n" "$PASS" "$FAIL"
echo "=============================================================="
if [ "$FAIL" -eq 0 ]; then
  echo "✅ 全部通过"
else
  echo "❌ 存在失败项，服务端日志尾部："
  tail -30 "$SERVER_LOG"
fi
[ "$FAIL" -eq 0 ]
