#!/usr/bin/env bash
#
# 一次产出全部平台的发布二进制、发布目录、压缩包与校验和。
#
# 用法：
#   scripts/build-release.sh                     # 版本号取自 git describe
#   scripts/build-release.sh -v 0.2.0            # 手动指定版本号
#   scripts/build-release.sh -o /tmp/dist        # 指定输出目录（默认 dist/）
#
# 产出：
#   dist/mediacenter-<version>-<os>-<arch>/      每个平台的发布目录
#       mediacenter[.exe]                        静态二进制（CGO_ENABLED=0）
#       INSTALL.md                               面向非开发者的安装说明
#       service/                                 开机自启的 install/uninstall 脚本
#   dist/mediacenter-<version>-<os>-<arch>.tar.gz | .zip
#   dist/SHA256SUMS                              校验和（用户下载后先核对这个）
#
# 如果客户端 APK 已经构建过，会额外打一个 android 包放进去 —— 非开发者拿到
# 一个目录就能同时装服务端和手机端，不用再回去找构建产物。
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BACKEND="$REPO/backend"
PACKAGING="$REPO/packaging"

VERSION=""
OUT_DIR="$REPO/dist"

usage() {
  sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

while [ $# -gt 0 ]; do
  case "$1" in
    -v|--version) VERSION="${2:-}"; shift 2 ;;
    -o|--out)     OUT_DIR="${2:-}"; shift 2 ;;
    -h|--help)    usage 0 ;;
    *) echo "未知参数：$1" >&2; usage 1 ;;
  esac
done

# ---------------------------------------------------------------- 找 Go
#
# 本机的 Go 不在默认 PATH 上（装在受管目录里），但脚本不该因此不可用。
GO="${GO:-}"
if [ -z "$GO" ]; then
  if command -v go >/dev/null 2>&1; then
    GO=go
  elif [ -x "$HOME/.workbuddy-ai/binaries/go/go/bin/go" ]; then
    GO="$HOME/.workbuddy-ai/binaries/go/go/bin/go"
  else
    echo "找不到 go。请把它加进 PATH，或用 GO=/path/to/go 指定。" >&2
    exit 1
  fi
fi

# ---------------------------------------------------------------- 版本号
if [ -z "$VERSION" ]; then
  if VERSION="$(git -C "$REPO" describe --tags --always --dirty 2>/dev/null)"; then
    VERSION="${VERSION#v}"   # v0.1.0 -> 0.1.0
  else
    VERSION="dev"
    echo "提示：拿不到 git 版本信息，版本号回退为 dev。" >&2
  fi
fi

# ---------------------------------------------------------------- 目标平台
#
# 五个目标覆盖了 D10 定的范围（桌面端 + Android 配套服务端）。
# 交叉编译能成立完全靠 CGO_ENABLED=0：modernc.org/sqlite 是纯 Go 实现，
# 没有 cgo 就没有"需要目标平台工具链"这回事。
TARGETS=(
  "darwin/arm64"
  "darwin/amd64"
  "linux/amd64"
  "linux/arm64"
  "windows/amd64"
)

HOST_OS="$(uname -s | tr '[:upper:]' '[:lower:]')"
case "$(uname -m)" in
  arm64|aarch64) HOST_ARCH="arm64" ;;
  x86_64|amd64)  HOST_ARCH="amd64" ;;
  *)             HOST_ARCH="unknown" ;;
esac

LDFLAGS="-s -w -X mediacenter/internal/api.Version=$VERSION"

rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"

echo "版本号   : $VERSION"
echo "输出目录 : $OUT_DIR"
echo "Go       : $GO ($("$GO" version | awk '{print $3}'))"
echo

# ---------------------------------------------------------------- 构建
declare -a ARCHIVE_PATHS=()

for t in "${TARGETS[@]}"; do
  os="${t%%/*}"
  arch="${t##*/}"
  name="mediacenter-${VERSION}-${os}-${arch}"
  pkg="$OUT_DIR/$name"

  bin="mediacenter"
  [ "$os" = "windows" ] && bin="mediacenter.exe"

  mkdir -p "$pkg/service"

  printf '%-34s' "$name"
  ( cd "$BACKEND" && \
    CGO_ENABLED=0 GOOS="$os" GOARCH="$arch" \
    "$GO" build -trimpath -ldflags "$LDFLAGS" -o "$pkg/$bin" . )

  # 每个包都带上说明和自启脚本：用户拿到的应该是一个自洽的目录，
  # 而不是"二进制在这里、脚本在别处、说明在 README 里"。
  cp "$PACKAGING/INSTALL.md" "$pkg/INSTALL.md"
  cp -R "$PACKAGING/service/$os/." "$pkg/service/"
  [ "$os" != "windows" ] && chmod +x "$pkg/service"/*.sh

  size="$(du -h "$pkg/$bin" | cut -f1)"

  # 能在本机跑就直接自检一下版本号 —— 交叉编译出来的二进制没法这样验证，
  # 所以这里只对 host 平台生效，但它能立刻抓出"ldflags 没生效"这类问题。
  selfcheck=""
  if [ "$os" = "$HOST_OS" ] && [ "$arch" = "$HOST_ARCH" ]; then
    if got="$("$pkg/$bin" -version 2>&1)"; then
      case "$got" in
        *"$VERSION"*) selfcheck="  自检 OK（${got}）" ;;
        *)            selfcheck="  自检失败：期望含 ${VERSION}，实际「${got}」" ;;
      esac
    else
      selfcheck="  自检失败：-version 退出码非 0"
    fi
  fi

  # 打包。tar.gz 给类 Unix，zip 给 Windows（Windows 资源管理器不认 tar.gz）。
  if [ "$os" = "windows" ]; then
    ( cd "$OUT_DIR" && zip -qr "$name.zip" "$name" )
    ARCHIVE_PATHS+=("$name.zip")
  else
    ( cd "$OUT_DIR" && tar -czf "$name.tar.gz" "$name" )
    ARCHIVE_PATHS+=("$name.tar.gz")
  fi

  echo "$size$selfcheck"
done

# ---------------------------------------------------------------- Android 包（可选）
APK_SRC="$REPO/client/build/app/outputs/flutter-apk/app-arm64-v8a-release.apk"
if [ -f "$APK_SRC" ]; then
  name="mediacenter-${VERSION}-android-arm64"
  pkg="$OUT_DIR/$name"
  mkdir -p "$pkg"
  cp "$APK_SRC" "$pkg/MediaCenter.apk"
  cp "$PACKAGING/INSTALL.md" "$pkg/INSTALL.md"
  ( cd "$OUT_DIR" && zip -qr "$name.zip" "$name" )
  ARCHIVE_PATHS+=("$name.zip")
  printf '%-34s' "$name"
  echo "$(du -h "$pkg/MediaCenter.apk" | cut -f1)  来自 $APK_SRC"
else
  echo
  echo "提示：没找到已构建的客户端 APK，跳过 android 包。"
  echo "      先跑 client/ 下的 flutter build apk --release --split-per-abi 再执行本脚本。"
fi

# ---------------------------------------------------------------- 校验和
hash_file() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1"
  else sha256sum "$1"; fi
}

(
  cd "$OUT_DIR"
  : > SHA256SUMS
  for a in "${ARCHIVE_PATHS[@]}"; do
    hash_file "$a" >> SHA256SUMS
  done
)

echo
echo "=== 校验和 ==="
cat "$OUT_DIR/SHA256SUMS"
echo
echo "校验方法："
echo "  macOS : (cd $OUT_DIR && shasum -a 256 -c SHA256SUMS)"
echo "  Linux : (cd $OUT_DIR && sha256sum -c SHA256SUMS)"
