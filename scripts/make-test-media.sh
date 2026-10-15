#!/usr/bin/env bash
# 生成一批用于验证后端的测试素材。
#
# 用法: ./make-test-media.sh [输出目录]
#
# 生成内容:
#   photos/IMG_0001.jpg   ffmpeg 生成，无 EXIF
#   photos/IMG_0002.jpg   注入 EXIF DateTimeOriginal = 2019:07:14 18:30:00
#   photos/IMG_0003.jpg   注入 EXIF DateTimeOriginal = 2023:12:25 09:15:00
#   photos/shot.png       纯 PNG
#   photos/notes.txt      非媒体文件，应被跳过
#   photos/.hidden/secret.jpg  隐藏目录，应被跳过
#   videos/clip_a.mp4     带 creation_time 元数据
#   videos/clip_b.mp4     无创建时间
set -euo pipefail

OUT="${1:-/tmp/mc-test-media}"
rm -rf "$OUT"
mkdir -p "$OUT/photos/.hidden" "$OUT/videos"

echo "==> 生成图片"
# 用不同尺寸，便于验证缩略图的等比缩放
ffmpeg -v error -y -f lavfi -i "testsrc2=size=1600x1200:rate=1" -frames:v 1 "$OUT/photos/IMG_0001.jpg"
ffmpeg -v error -y -f lavfi -i "testsrc2=size=2400x1350:rate=1" -frames:v 1 "$OUT/photos/IMG_0002.jpg"
ffmpeg -v error -y -f lavfi -i "testsrc2=size=1200x1600:rate=1" -frames:v 1 "$OUT/photos/IMG_0003.jpg"
ffmpeg -v error -y -f lavfi -i "testsrc2=size=800x600:rate=1" -frames:v 1 "$OUT/photos/shot.png"
ffmpeg -v error -y -f lavfi -i "testsrc2=size=640x480:rate=1" -frames:v 1 "$OUT/photos/.hidden/secret.jpg"

echo "==> 生成视频"
ffmpeg -v error -y -f lavfi -i "testsrc2=size=1280x720:rate=25:duration=4" \
  -f lavfi -i "sine=frequency=440:duration=4" \
  -c:v libx264 -preset ultrafast -pix_fmt yuv420p -c:a aac -shortest \
  -metadata creation_time="2021-03-05T10:00:00Z" \
  "$OUT/videos/clip_a.mp4"
ffmpeg -v error -y -f lavfi -i "testsrc2=size=854x480:rate=25:duration=2" \
  -c:v libx264 -preset ultrafast -pix_fmt yuv420p \
  "$OUT/videos/clip_b.mp4"

echo "==> 注入 EXIF 拍摄时间"
python3 - "$OUT/photos/IMG_0002.jpg" "2019:07:14 18:30:00" <<'PY'
import struct, sys

def build_app1(dt: str) -> bytes:
    """构造一个只含 DateTimeOriginal 与 DateTime 的最小 EXIF APP1 段。"""
    ts = dt.encode("ascii") + b"\x00"          # 20 字节, 含结尾 NUL
    assert len(ts) == 20

    ifd0_off, exif_ifd_off = 8, 38
    dt1_off, dt2_off = 56, 76

    tiff = bytearray()
    tiff += b"MM"                              # 大端
    tiff += struct.pack(">H", 0x002A)
    tiff += struct.pack(">I", ifd0_off)

    # IFD0: DateTime(0x0132) + ExifIFD 指针(0x8769)
    tiff += struct.pack(">H", 2)
    tiff += struct.pack(">HHI", 0x0132, 2, len(ts)) + struct.pack(">I", dt1_off)
    tiff += struct.pack(">HHI", 0x8769, 4, 1)       + struct.pack(">I", exif_ifd_off)
    tiff += struct.pack(">I", 0)               # 无下一个 IFD

    # ExifIFD: DateTimeOriginal(0x9003)
    tiff += struct.pack(">H", 1)
    tiff += struct.pack(">HHI", 0x9003, 2, len(ts)) + struct.pack(">I", dt2_off)
    tiff += struct.pack(">I", 0)

    assert len(tiff) == dt1_off, len(tiff)
    tiff += ts + ts

    payload = b"Exif\x00\x00" + bytes(tiff)
    return b"\xFF\xE1" + struct.pack(">H", len(payload) + 2) + payload

path, dt = sys.argv[1], sys.argv[2]
raw = open(path, "rb").read()
assert raw[:2] == b"\xFF\xD8", "not a JPEG"
open(path, "wb").write(raw[:2] + build_app1(dt) + raw[2:])
print(f"    {path} -> DateTimeOriginal {dt}")
PY

# 给第三张图也用同一脚本注入不同时间
python3 - "$OUT/photos/IMG_0003.jpg" "2023:12:25 09:15:00" <<'PY'
import struct, sys

def build_app1(dt: str) -> bytes:
    ts = dt.encode("ascii") + b"\x00"
    tiff = bytearray()
    tiff += b"II"                              # 小端，顺便验证字节序分支
    tiff += struct.pack("<H", 0x002A)
    tiff += struct.pack("<I", 8)
    tiff += struct.pack("<H", 2)
    tiff += struct.pack("<HHI", 0x0132, 2, len(ts)) + struct.pack("<I", 56)
    tiff += struct.pack("<HHI", 0x8769, 4, 1)       + struct.pack("<I", 38)
    tiff += struct.pack("<I", 0)
    tiff += struct.pack("<H", 1)
    tiff += struct.pack("<HHI", 0x9003, 2, len(ts)) + struct.pack("<I", 76)
    tiff += struct.pack("<I", 0)
    assert len(tiff) == 56, len(tiff)
    tiff += ts + ts
    payload = b"Exif\x00\x00" + bytes(tiff)
    return b"\xFF\xE1" + struct.pack(">H", len(payload) + 2) + payload

path, dt = sys.argv[1], sys.argv[2]
raw = open(path, "rb").read()
open(path, "wb").write(raw[:2] + build_app1(dt) + raw[2:])
print(f"    {path} -> DateTimeOriginal {dt} (little-endian TIFF)")
PY

echo "非媒体文件" > "$OUT/photos/notes.txt"

echo
echo "完成: $OUT"
find "$OUT" -type f | sort
