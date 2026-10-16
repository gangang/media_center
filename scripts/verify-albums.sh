#!/usr/bin/env bash
#
# 相册功能回归验证。
#
# 覆盖：相册 CRUD（含大小写不敏感的唯一性、部分更新语义）、成员增删（幂等）、
#       封面推导与反向查询、删除相册不影响媒体本身、
#       以及「文件从磁盘消失后成员关系被外键级联清理」。
#
# 用法：
#   ./scripts/verify-albums.sh                    # 默认 http://127.0.0.1:18080
#   ./scripts/verify-albums.sh http://host:port
#   MC_TOKEN=xxx ./scripts/verify-albums.sh       # 显式指定令牌
#
# 令牌来源优先级：环境变量 MC_TOKEN > 数据目录下的 config.json。
#
# G 段（级联）需要一个真实文件做「移出扫描目录」实验，默认用
# /tmp/mc-test-media/photos/IMG_0001.jpg（由 scripts/make-test-media.sh 生成）。
# 找不到该文件时 G 段会被跳过，而不是报失败。可用 MC_CASCADE_FILE 覆盖路径。

set -u

BASE="${1:-http://127.0.0.1:18080}"
BASE="${BASE%/}"

# ---------- 解析令牌 ----------
TOK="${MC_TOKEN:-}"
if [ -z "$TOK" ]; then
  for d in "${MC_DATA_DIR:-}" /tmp/mc-data "$HOME/.mediacenter" ./data; do
    [ -n "$d" ] || continue
    if [ -f "$d/config.json" ]; then
      TOK="$(python3 -c "import sys,json;print(json.load(open(sys.argv[1])).get('token',''))" "$d/config.json" 2>/dev/null)"
      [ -n "$TOK" ] && break
    fi
  done
fi
if [ -z "$TOK" ]; then
  echo "错误：找不到访问令牌。请设置 MC_TOKEN 或 MC_DATA_DIR 后重试。" >&2
  exit 2
fi

AUTH="Authorization: Bearer $TOK"
J="Content-Type: application/json"
PASS=0; FAIL=0

chk() { # chk <名称> <期望> <实际>
  if [ "$2" = "$3" ]; then
    printf '  \033[32mPASS\033[0m  %-48s %s\n' "$1" "$3"; PASS=$((PASS+1))
  else
    printf '  \033[31mFAIL\033[0m  %-48s got=%s want=%s\n' "$1" "$3" "$2"; FAIL=$((FAIL+1))
  fi
}
note() { if [ "$2" = "1" ]; then printf '  \033[32mPASS\033[0m  %s\n' "$1"; PASS=$((PASS+1)); else printf '  \033[31mFAIL\033[0m  %s\n' "$1"; FAIL=$((FAIL+1)); fi; }
code()   { curl -s -o /dev/null -w '%{http_code}' "$@"; }
post()   { curl -s -X POST   -H "$AUTH" -H "$J" -d "$2" "$BASE$1"; }
postc()  { curl -s -o /dev/null -w '%{http_code}' -X POST   -H "$AUTH" -H "$J" -d "$2" "$BASE$1"; }
patchc() { curl -s -o /dev/null -w '%{http_code}' -X PATCH  -H "$AUTH" -H "$J" -d "$2" "$BASE$1"; }
delc()   { curl -s -o /dev/null -w '%{http_code}' -X DELETE -H "$AUTH" -H "$J" -d "$2" "$BASE$1"; }
jq_()    { python3 -c "import sys,json;d=json.load(sys.stdin);print($1)" 2>/dev/null || echo "PARSE_ERR"; }

# 判断 /api/media/{id}/albums 的响应里是否含指定相册 id。
# 相册 id 走环境变量传入，避免在内联 python 里做 shell 展开。
has_album() { AID="$1" python3 -c '
import sys, json, os
d = json.load(sys.stdin)
aid = int(os.environ["AID"])
print(len([a for a in d.get("items", []) if a["id"] == aid]))'; }

# 按文件名取 media id，比依赖分页顺序稳健。
media_id_of() { NAME="$1" python3 -c '
import sys, json, os
want = os.environ["NAME"]
for i in json.load(sys.stdin)["items"]:
    if i["file_name"] == want:
        print(i["id"]); break'; }

wait_scan() {
  for _ in $(seq 1 60); do
    [ "$(curl -s -H "$AUTH" "$BASE/api/scan/status" | jq_ 'd["running"]')" = "False" ] && return 0
    sleep 0.4
  done
  return 1
}

# 清掉上次运行可能残留的测试相册
cleanup_test_albums() {
  curl -s -H "$AUTH" "$BASE/api/albums" | python3 -c '
import sys, json
for a in json.load(sys.stdin).get("items", []):
    n = a["name"]
    if n.startswith("测试相册") or n.startswith("级联测试") or n.lower().startswith("test-album"):
        print(a["id"])' 2>/dev/null | while read -r id; do
    [ -n "$id" ] && curl -s -o /dev/null -X DELETE -H "$AUTH" "$BASE/api/albums/$id"
  done
}

echo "服务器: $BASE"
cleanup_test_albums

echo
echo "=============================================================="
echo " A. 创建相册"
echo "=============================================================="
A1=$(post /api/albums '{"name":"测试相册-旅行","description":"2024 年夏天"}')
ID=$(echo "$A1" | jq_ 'd["id"]')
echo "  创建结果: $A1"
chk "POST /api/albums -> 201" 201 "$(postc /api/albums '{"name":"测试相册-临时"}')"
chk "同名 -> 409"             409 "$(postc /api/albums '{"name":"测试相册-旅行"}')"
chk "空名称 -> 400"           400 "$(postc /api/albums '{"name":"   "}')"
chk "非法 JSON -> 400"        400 "$(postc /api/albums 'not-json')"
chk "description 正确保存"    "2024 年夏天" "$(echo "$A1" | jq_ 'd["description"]')"
chk "新相册 item_count=0"     "0" "$(echo "$A1" | jq_ 'd["item_count"]')"
chk "新相册 cover_url 为空"   "" "$(echo "$A1" | jq_ 'd["cover_url"]')"

# 唯一性大小写不敏感。中文没有大小写，所以用 ASCII 名验证。
chk "创建 Test-Album -> 201"  201 "$(postc /api/albums '{"name":"Test-Album"}')"
chk "test-album 同名 -> 409"  409 "$(postc /api/albums '{"name":"test-album"}')"

TMPID=$(curl -s -H "$AUTH" "$BASE/api/albums" | python3 -c '
import sys, json
for a in json.load(sys.stdin)["items"]:
    if a["name"] == "测试相册-临时":
        print(a["id"]); break' 2>/dev/null)
[ -n "$TMPID" ] && curl -s -o /dev/null -X DELETE -H "$AUTH" "$BASE/api/albums/$TMPID"
echo "  相册 id=$ID"

echo
echo "=============================================================="
echo " B. 加入媒体"
echo "=============================================================="
MEDIA_IDS=$(curl -s -H "$AUTH" "$BASE/api/media?page_size=4" | python3 -c '
import sys, json
print(",".join(str(i["id"]) for i in json.load(sys.stdin)["items"]))' 2>/dev/null)
echo "  取到媒体 id: $MEDIA_IDS"
M1=$(echo "$MEDIA_IDS" | cut -d, -f1)
M2=$(echo "$MEDIA_IDS" | cut -d, -f2)
M3=$(echo "$MEDIA_IDS" | cut -d, -f3)

R=$(post "/api/albums/$ID/media" "{\"media_ids\":[$M1,$M2,$M3]}")
echo "  加入结果: $R"
chk "首次加入 added=3" "3" "$(echo "$R" | jq_ 'd["added"]')"
# 注意：不要把这个 payload 直接内联进 "$( ... )"——内层的 \" 会被外层双引号
# 语境提前吃掉，JSON 会被破坏，表现为莫名的 PARSE_ERR。先用变量承载。
PAYLOAD="{\"media_ids\":[$M1,$M2,$M3]}"
chk "重复加入 added=0（幂等）" "0" "$(post "/api/albums/$ID/media" "$PAYLOAD" | jq_ 'd["added"]')"
chk "不存在的 media_id -> 400" 400 "$(postc "/api/albums/$ID/media" '{"media_ids":[999999]}')"
chk "空 media_ids -> 400"      400 "$(postc "/api/albums/$ID/media" '{"media_ids":[]}')"
chk "非法 media_id -> 400"     400 "$(postc "/api/albums/$ID/media" '{"media_ids":[-1]}')"
chk "不存在的相册 -> 404"      404 "$(postc "/api/albums/999999/media" '{"media_ids":[7]}')"

echo
echo "=============================================================="
echo " C. 读取相册"
echo "=============================================================="
chk "相册内媒体数 = 3" "3" "$(curl -s -H "$AUTH" "$BASE/api/albums/$ID/media" | jq_ 'd["total"]')"
A=$(curl -s -H "$AUTH" "$BASE/api/albums/$ID")
chk "item_count = 3" "3" "$(echo "$A" | jq_ 'd["item_count"]')"
COVER=$(echo "$A" | jq_ 'd["cover_url"]')
echo "  cover_url: $COVER"
echo "$COVER" | grep -qE "^/api/media/[0-9]+/thumbnail$" && note "cover_url 指向缩略图" 1 || note "cover_url 格式异常" 0
chk "cover 缩略图可访问 -> 200" 200 "$(code -H "$AUTH" "$BASE$COVER")"
chk "反向查询含本相册" "1" "$(curl -s -H "$AUTH" "$BASE/api/media/$M1/albums" | has_album "$ID")"
curl -s -H "$AUTH" "$BASE/api/albums" | grep -q "测试相册-旅行" && note "相册出现在列表中" 1 || note "相册未出现在列表" 0

echo
echo "=============================================================="
echo " D. 重命名（PATCH 部分更新语义）"
echo "=============================================================="
chk "PATCH 改名 -> 200" 200 "$(patchc "/api/albums/$ID" '{"name":"测试相册-已改名"}')"
chk "改名后 name 生效" "测试相册-已改名" "$(curl -s -H "$AUTH" "$BASE/api/albums/$ID" | jq_ 'd["name"]')"
chk "只改 description 时 name 保留" "测试相册-已改名" \
    "$(curl -s -X PATCH -H "$AUTH" -H "$J" -d '{"description":"新描述"}' "$BASE/api/albums/$ID" | jq_ 'd["name"]')"
chk "PATCH 不存在 -> 404" 404 "$(patchc "/api/albums/999999" '{"name":"x"}')"
chk "PATCH 非法 id -> 400" 400 "$(patchc "/api/albums/abc" '{"name":"x"}')"

echo
echo "=============================================================="
echo " E. 移出媒体"
echo "=============================================================="
chk "DELETE body 移出 -> 200" 200 "$(delc "/api/albums/$ID/media" "{\"media_ids\":[$M1]}")"
chk "移出后剩余 2" "2" "$(curl -s -H "$AUTH" "$BASE/api/albums/$ID/media" | jq_ 'd["total"]')"
chk "DELETE query 参数移出 -> 200" 200 "$(code -X DELETE -H "$AUTH" "$BASE/api/albums/$ID/media?media_ids=$M2")"
chk "再移出后剩余 1" "1" "$(curl -s -H "$AUTH" "$BASE/api/albums/$ID/media" | jq_ 'd["total"]')"
chk "移出非成员幂等 -> 200" 200 "$(delc "/api/albums/$ID/media" "{\"media_ids\":[$M2]}")"

echo
echo "=============================================================="
echo " F. 删除相册不得影响媒体本身"
echo "=============================================================="
BEFORE=$(curl -s -H "$AUTH" "$BASE/api/stats" | jq_ 'd["photos"]+d["videos"]')
chk "DELETE 相册 -> 200" 200 "$(code -X DELETE -H "$AUTH" "$BASE/api/albums/$ID")"
chk "删除后 GET -> 404" 404 "$(code -H "$AUTH" "$BASE/api/albums/$ID")"
AFTER=$(curl -s -H "$AUTH" "$BASE/api/stats" | jq_ 'd["photos"]+d["videos"]')
chk "媒体总数不变（$BEFORE -> ${AFTER}）" "$BEFORE" "$AFTER"
chk "原媒体仍可访问 -> 200" 200 "$(code -H "$AUTH" "$BASE/api/media/$M1")"
chk "原文件仍可播放 -> 200" 200 "$(code -I -H "$AUTH" "$BASE/api/media/$M3/original")"
chk "媒体不再属于任何相册" "0" "$(curl -s -H "$AUTH" "$BASE/api/media/$M1/albums" | jq_ 'len(d["items"])')"

echo
echo "=============================================================="
echo " G. 文件消失后成员关系被外键级联清理"
echo "=============================================================="
CASCADE_FILE="${MC_CASCADE_FILE:-/tmp/mc-test-media/photos/IMG_0001.jpg}"
PARK="/tmp/mc-parked"
if [ ! -f "$CASCADE_FILE" ]; then
  echo "  跳过：找不到 ${CASCADE_FILE}（先跑 scripts/make-test-media.sh，或设置 MC_CASCADE_FILE）"
else
  mkdir -p "$PARK"
  MID=$(curl -s -H "$AUTH" "$BASE/api/media?page_size=200" | media_id_of "$(basename "$CASCADE_FILE")")
  echo "  $(basename "$CASCADE_FILE") 的 media id = $MID"
  if [ -z "$MID" ]; then
    echo "  跳过：该文件不在索引中"
  else
    A=$(curl -s -X POST -H "$AUTH" -H "$J" -d '{"name":"级联测试相册"}' "$BASE/api/albums")
    AID=$(echo "$A" | jq_ 'd["id"]')
    curl -s -o /dev/null -X POST -H "$AUTH" -H "$J" -d "{\"media_ids\":[$MID]}" "$BASE/api/albums/$AID/media"
    chk "相册内 1 项" "1" "$(curl -s -H "$AUTH" "$BASE/api/albums/$AID" | jq_ 'd["item_count"]')"

    mv "$CASCADE_FILE" "$PARK/"
    echo "  已移出扫描目录，重新扫描…"
    curl -s -o /dev/null -X POST -H "$AUTH" -H "$J" -d '{}' "$BASE/api/scan/start"
    wait_scan || echo "  (扫描等待超时)"
    echo "  扫描结果: $(curl -s -H "$AUTH" "$BASE/api/scan/status" | jq_ 'd')"

    chk "媒体已从索引移除 -> 404" 404 "$(code -H "$AUTH" "$BASE/api/media/$MID")"
    chk "相册 item_count 归零（级联生效）" "0" "$(curl -s -H "$AUTH" "$BASE/api/albums/$AID" | jq_ 'd["item_count"]')"
    chk "相册内媒体列表为空" "0" "$(curl -s -H "$AUTH" "$BASE/api/albums/$AID/media" | jq_ 'd["total"]')"

    mv "$PARK/$(basename "$CASCADE_FILE")" "$CASCADE_FILE"
    echo "  已还原文件，重新扫描…"
    curl -s -o /dev/null -X POST -H "$AUTH" -H "$J" -d '{}' "$BASE/api/scan/start"
    wait_scan || echo "  (扫描等待超时)"
    NEWID=$(curl -s -H "$AUTH" "$BASE/api/media?page_size=200" | media_id_of "$(basename "$CASCADE_FILE")")
    echo "  还原后 id = ${NEWID}（原 id = ${MID}）"
    chk "文件重新入库" "$NEWID" "$(echo "$NEWID" | grep -qE '^[0-9]+$' && echo "$NEWID" || echo MISSING)"
    # 这是有意的取舍：成员关系跟着 media 行走，行没了关系就没了。
    chk "相册成员关系未自动恢复（已知取舍）" "0" "$(curl -s -H "$AUTH" "$BASE/api/albums/$AID" | jq_ 'd["item_count"]')"

    curl -s -o /dev/null -X DELETE -H "$AUTH" "$BASE/api/albums/$AID"
  fi
fi

cleanup_test_albums

echo
echo "=============================================================="
printf " 结果: PASS=%d  FAIL=%d\n" "$PASS" "$FAIL"
echo "=============================================================="
[ "$FAIL" -eq 0 ] && echo "✅ 全部通过" || echo "❌ 存在失败项"
[ "$FAIL" -eq 0 ]
