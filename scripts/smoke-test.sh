#!/usr/bin/env bash
#
# 对一个已构建的服务端二进制做冒烟测试。
#
# 验的是"这个二进制真的能跑起来并干活"：启动 → 建库 → 加目录 → 扫描 → 索引 → 响应 API。
# 交叉编译出来的二进制在本机跑不了，所以这个脚本要配合容器使用，例如：
#
#   docker run --rm -v "$PWD:/w" -w /w alpine:latest \
#     sh -c 'apk add --no-cache curl bash >/dev/null && \
#            ./scripts/smoke-test.sh ./dist/mediacenter-x-linux-amd64/mediacenter'
#
# 用法：scripts/smoke-test.sh <二进制路径> [期望版本号]
#
# 只依赖 curl 和 bash。测试素材在脚本里现造（一个 >1KiB 的假 jpg）——
# 扫描器对解码失败是容忍的（缩略图生成失败只记日志，文件照样入库），
# 所以不需要真图片，也就不需要 ffmpeg 或 Python。
set -uo pipefail

BIN="${1:-}"
EXPECT_VERSION="${2:-}"

if [ -z "$BIN" ]; then
  echo "用法：$0 <二进制路径> [期望版本号]" >&2
  exit 2
fi
if [ ! -x "$BIN" ]; then
  echo "不是可执行文件：$BIN" >&2
  exit 2
fi
if ! command -v curl >/dev/null 2>&1; then
  echo "需要 curl（alpine 上先 apk add --no-cache curl）" >&2
  exit 2
fi

BIN="$(cd "$(dirname "$BIN")" && pwd)/$(basename "$BIN")"
WORK="$(mktemp -d)"
DATA="$WORK/data"
MEDIA="$WORK/media"
SERVER_PID=""

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  [OK]   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  [FAIL] %s\n' "$1"; }

cleanup() {
  if [ -n "$SERVER_PID" ] && kill -0 "$SERVER_PID" 2>/dev/null; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT

# 极简 JSON 取值。冒烟测试只用到几个标量字段，为它们引一个 JSON 库不值当，
# 而 alpine 上既没有 jq 也没有 python3。
#
# 正则允许冒号两侧有空白：API 返回的是紧凑 JSON，但 config.json 是 MarshalIndent
# 出来的（`"token": "..."` 带空格），只按紧凑格式写会静默取到空值 ——
# 表现是所有带令牌的请求都 401，看起来像鉴权坏了。
jnum()  { sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p" <<<"$1" | head -1; }
jstr()  { sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" <<<"$1" | head -1; }

# 布尔单独处理，别用 \(true\|false\)：BSD sed 的 BRE 不支持 \| 交替（GNU sed 支持），
# 在 macOS 上会静默匹配不到东西、返回空串 —— 而空串和"值是 false"没法区分，
# 于是"扫描是否结束"这类判断会永远不成立，报告却说不出所以然。
# 用 grep -E 分别问一次，语义直白且在 BSD/GNU/busybox 上行为一致。
jbool() {
  if grep -qE "\"$2\"[[:space:]]*:[[:space:]]*true" <<<"$1"; then
    printf 'true'
  elif grep -qE "\"$2\"[[:space:]]*:[[:space:]]*false" <<<"$1"; then
    printf 'false'
  fi
}

echo "冒烟测试：$BIN"
echo

# ---------------------------------------------------------------- 1. 自报版本
VOUT="$("$BIN" -version 2>&1)"
if grep -q '^mediacenter ' <<<"$VOUT"; then
  ok "能自报版本：$VOUT"
else
  bad "自报版本格式不对：$VOUT"
fi

if [ -n "$EXPECT_VERSION" ]; then
  if grep -q "$EXPECT_VERSION" <<<"$VOUT"; then
    ok "版本号含 ${EXPECT_VERSION}（ldflags 注入生效）"
  else
    bad "版本号不含 ${EXPECT_VERSION}，实际：$VOUT"
  fi
fi

# ---------------------------------------------------------------- 2. 造测试素材
mkdir -p "$MEDIA/photos"
# 必须 >1024 字节：扫描器有 1KiB 下限，比它小的文件会被跳过。
head -c 4096 /dev/urandom | base64 > "$MEDIA/photos/IMG_9001.jpg"
[ -s "$MEDIA/photos/IMG_9001.jpg" ] || bad "测试素材没造出来"
mkdir -p "$MEDIA/photos/sub"
head -c 4096 /dev/urandom | base64 > "$MEDIA/photos/sub/IMG_9002.jpg"

# ---------------------------------------------------------------- 3. 起服务
#
# 端口必须挑一个**空闲**的。这一条不是洁癖，是踩过的坑：
#
# 候选端口上如果已经坐着另一个服务端实例（比如上次冒烟测试忘了收的进程），
# 我们的 ping 会命中它、于是判定"就绪"，但它的 data 目录是别人的、令牌自然对不上。
# 结果是一路 401，而 "无令牌访问被拒" 这类检查反而全绿 ——
# 报告读起来像鉴权坏了，实际上被测二进制毫无问题。冒烟测试一旦会撒谎就失去了意义。
#
# 所以做两层防护：
#   1. 起之前先探端口是否空闲（占用就跳过）；
#   2. 起之后核对对面那台自报的版本号，是不是我们刚构建的这个二进制。
#
# 另外"某些端口请求返回 502"是沙箱/容器里代理拦截的表现，换端口也能一并绕开。
port_in_use() {
  # bash 的 /dev/tcp 伪设备：连得上就说明有东西在监听。不需要 nc / lsof。
  if (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null; then
    return 0
  fi
  return 1
}

# 候选端口：默认用随机高位端口打头（避开固定端口上的历史残留），固定端口兜底。
#
# SMOKE_PORTS 可以覆盖这个列表，用途是复现/回归"端口被占"这一类问题：
#   SMOKE_PORTS="18080 18081" ./scripts/smoke-test.sh ./mediacenter
# 这样"必须先跳过被占端口"的行为就能被确定性地测到，而不是靠运气撞上。
if [ -n "${SMOKE_PORTS:-}" ]; then
  read -r -a CANDIDATES <<<"$SMOKE_PORTS"
else
  RAND_BASE=$((20000 + (RANDOM % 20000)))
  CANDIDATES=("$RAND_BASE" $((RAND_BASE + 1)) $((RAND_BASE + 2)) 18080 18081 18082 18085 18090 19080 28080)
fi

PORT=""
skipped=""
for p in "${CANDIDATES[@]}"; do
  if port_in_use "$p"; then
    skipped="$skipped $p"
    continue
  fi
  "$BIN" -data "$DATA" -port "$p" -mdns=false > "$WORK/server.log" 2>&1 &
  SERVER_PID=$!
  ready=0
  for _ in $(seq 1 40); do
    if ! kill -0 "$SERVER_PID" 2>/dev/null; then break; fi
    if curl -fsS --max-time 1 "http://127.0.0.1:$p/api/ping" >/dev/null 2>&1; then ready=1; break; fi
    sleep 0.25
  done
  if [ "$ready" = "1" ]; then PORT="$p"; break; fi
  # 进程可能已经退出（端口被占），或者进程活着但请求被代理拦了 —— 两种都换下一个。
  kill "$SERVER_PID" 2>/dev/null || true
  wait "$SERVER_PID" 2>/dev/null || true
  SERVER_PID=""
done

if [ -n "$skipped" ]; then
  echo "  （跳过被占用的端口：$skipped ）"
fi

if [ -z "$PORT" ]; then
  bad "服务端没能在任何候选端口上就绪"
  echo "--- server.log ---"; cat "$WORK/server.log"
  echo; echo "通过 $PASS 项，失败 $FAIL 项"
  exit 1
fi
ok "服务端已就绪（端口 ${PORT}）"

if kill -0 "$SERVER_PID" 2>/dev/null; then
  ok "进程存活"
else
  bad "进程已退出"
fi

BASE="http://127.0.0.1:$PORT"

# ---------------------------------------------------------------- 4. 鉴权
PING="$(curl -fsS --max-time 3 "$BASE/api/ping")"
check_api="$(jnum "$PING" api_version)"
if [ "$check_api" = "1" ]; then ok "/api/ping 报告 api_version=1"; else bad "/api/ping 的 api_version 是「${check_api}」"; fi

# 对面那台到底是不是"我们刚构建的二进制"？
#
# 这一步是防"端口上有别的实例"的第二道闸。端口空闲检查和实际绑定之间总有缝隙，
# 而一旦连错了服务，后面每一条带令牌的检查都会 401，报告会指向一个不存在的问题。
# /api/ping 是公开接口且自报版本，拿它和 `-version` 的输出对一下，成本几乎为零。
BIN_VERSION="${VOUT#mediacenter }"
BIN_VERSION="${BIN_VERSION%% (api*}"
PING_VERSION="$(jstr "$PING" version)"
if [ -n "$PING_VERSION" ] && [ "$PING_VERSION" = "$BIN_VERSION" ]; then
  ok "对面服务自报版本 ${PING_VERSION}，与被测二进制一致"
else
  bad "对面服务自报版本「${PING_VERSION}」，与被测二进制「${BIN_VERSION}」不一致（端口上可能坐着别的实例）"
fi

CODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "$BASE/api/stats")"
if [ "$CODE" = "401" ]; then ok "无令牌访问 /api/stats 被拒（401）"; else bad "无令牌访问 /api/stats 返回 ${CODE}，期望 401"; fi

TOKEN="$(jstr "$(cat "$DATA/config.json")" token)"
if [ -n "$TOKEN" ]; then ok "config.json 里有令牌"; else bad "config.json 里没读到令牌"; fi

AUTH=(-H "Authorization: Bearer $TOKEN")
CODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "${AUTH[@]}" "$BASE/api/stats")"
if [ "$CODE" = "200" ]; then
  ok "带令牌访问 /api/stats 通过（200）"
else
  # 报长度而不是令牌本身：既能一眼看出"取到空串"（长度为 0），又不把凭据写进日志。
  bad "带令牌访问 /api/stats 返回 ${CODE}（令牌长度 ${#TOKEN}）"
fi

# ---------------------------------------------------------------- 5. 建库
if [ -f "$DATA/index.db" ]; then ok "已创建索引数据库 index.db"; else bad "没有生成 index.db"; fi

# ---------------------------------------------------------------- 6. 加目录 + 扫描
CODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "${AUTH[@]}" \
  -H 'Content-Type: application/json' -X POST -d "{\"path\":\"$MEDIA/photos\"}" "$BASE/api/folders")"
if [ "$CODE" = "201" ] || [ "$CODE" = "200" ]; then ok "添加扫描目录（${CODE}）"; else bad "添加扫描目录返回 $CODE"; fi

# 409 是合法结果，不是失败：添加目录本身会自动触发一次扫描，
# 我们紧接着再手动触发，服务端就会回 "a scan is already running"（409 Conflict）。
# 真正要验证的是"扫描跑完并且索引到了东西"，那是下面轮询 /api/scan/status 的事。
CODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "${AUTH[@]}" -X POST "$BASE/api/scan/start")"
case "$CODE" in
  200 | 202) ok "触发扫描（${CODE}）" ;;
  409) ok "触发扫描返回 409：已有一轮扫描在跑（添加目录自动触发），符合预期" ;;
  *) bad "触发扫描返回 $CODE" ;;
esac

STATUS=""
done_scan=0
for _ in $(seq 1 60); do
  STATUS="$(curl -fsS --max-time 3 "${AUTH[@]}" "$BASE/api/scan/status")"
  running="$(jbool "$STATUS" running)"
  seen="$(jnum "$STATUS" files_seen)"
  if [ "$running" = "false" ] && [ -n "$seen" ] && [ "$seen" -ge 2 ]; then done_scan=1; break; fi
  sleep 0.5
done

if [ "$done_scan" = "1" ]; then
  ok "扫描完成，看到 $(jnum "$STATUS" files_seen) 个文件"
else
  bad "扫描没在 30 秒内完成：$STATUS"
fi

# 这里刻意**不**断言 indexed >= 2。
#
# 扫描是增量的：同一个文件再扫一遍，因为 size+mtime 没变会被记为 skipped。
# 而"添加目录"本身就会自动触发一轮扫描，所以紧接着手动触发的这一轮常常是第二遍 ——
# indexed=0、skipped=2 是完全正常的结果。
#
# 曾经按 indexed>=2 断言，于是同一个二进制在 macOS 上绿、在 Linux 上红，
# 差别只来自两轮扫描的时间差（macOS 上手动触发撞上 409，拿到的是第一轮的状态）。
# 这种断言比没有断言更糟：它把调度噪声伪装成产品缺陷。
#
# 真正不变的是记账关系：每个见到的文件必然恰好落在 indexed / skipped / failed 之一。
# 至于"库里有东西"，交给下面的 /api/stats 和 /api/media 去验。
INDEXED="$(jnum "$STATUS" indexed)"; INDEXED="${INDEXED:-0}"
SKIPPED="$(jnum "$STATUS" skipped)"; SKIPPED="${SKIPPED:-0}"
FAILED="$(jnum "$STATUS" failed)"; FAILED="${FAILED:-0}"
SEEN="$(jnum "$STATUS" files_seen)"; SEEN="${SEEN:-0}"
if [ "$SEEN" -ge 2 ] && [ $((INDEXED + SKIPPED + FAILED)) -eq "$SEEN" ]; then
  ok "扫描统计自洽：files_seen=$SEEN = indexed $INDEXED + skipped $SKIPPED + failed $FAILED"
else
  bad "扫描统计不自洽：files_seen=$SEEN, indexed=$INDEXED, skipped=$SKIPPED, failed=$FAILED"
fi

# ---------------------------------------------------------------- 7. 查索引
STATS="$(curl -fsS --max-time 3 "${AUTH[@]}" "$BASE/api/stats")"
PHOTOS="$(jnum "$STATS" photos)"
if [ -n "$PHOTOS" ] && [ "$PHOTOS" -ge 2 ]; then
  ok "/api/stats 报告照片 $PHOTOS 张"
else
  bad "/api/stats 的照片数是「${PHOTOS}」，期望 >=2"
fi

LIST="$(curl -fsS --max-time 3 "${AUTH[@]}" "$BASE/api/media?type=photo")"
if grep -q 'IMG_9001' <<<"$LIST"; then ok "/api/media 能列出刚索引的文件"; else bad "/api/media 没列出 IMG_9001"; fi

# ---------------------------------------------------------------- 8. 干净退出
kill "$SERVER_PID" 2>/dev/null || true
exited=0
for _ in $(seq 1 20); do
  if ! kill -0 "$SERVER_PID" 2>/dev/null; then exited=1; break; fi
  sleep 0.25
done
if [ "$exited" = "1" ]; then ok "收到 SIGTERM 后干净退出"; else bad "收到 SIGTERM 后没有退出"; fi
SERVER_PID=""

echo
echo "通过 $PASS 项，失败 $FAIL 项"
[ "$FAIL" -eq 0 ]
