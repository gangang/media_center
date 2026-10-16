#!/usr/bin/env python3
"""生成 Android 应用图标与启动图。

图形：品牌色渐变圆角方底 + 白色「相框轮廓内含播放三角」。
相框对应相册，播放三角对应影院，两个功能一个图形。

为什么是脚本而不是设计稿：
  1. adaptive icon 的图形必须落在安全区内（108dp 画布，中心 72dp 才是保证可见的），
     这种几何约束用脚本表达比靠肉眼对齐可靠。
  2. 一共要出 3 种用途 × 5 种密度 = 15 个文件，手改必然漂移。
  3. 换配色只改下面两个常量。

配色取自客户端主题（lib/main.dart 的 colorSchemeSeed = 0xFF2F6BFF），
以及 scaffoldBackgroundColor = 0xFFFAFAFA（启动图背景要跟它一致，否则会白闪）。

依赖：Pillow。用法：
  /Users/zhangbaobao/.workbuddy-ai/binaries/python/envs/default/bin/python \
      scripts/gen-android-icons.py
"""

from __future__ import annotations

import os
from PIL import Image, ImageDraw

# ---------------------------------------------------------------- 品牌常量

BRAND_START = (47, 107, 255)   # #2F6BFF —— 与客户端 colorSchemeSeed 一致
BRAND_END = (109, 74, 255)     # #6D4AFF —— 渐变另一端，偏紫，避免单色发闷
SPLASH_BG = (255, 255, 255)    # 与 Android 窗口背景（Theme.Light）一致

SS = 4  # 超采样倍数，用于抗锯齿

HERE = os.path.dirname(os.path.abspath(__file__))
RES = os.path.join(HERE, "..", "client", "android", "app", "src", "main", "res")

# 传统图标（API 24-25 用，launcher 不裁切，所以自带圆角方底）
LEGACY_SIZES = {
    "mipmap-mdpi": 48,
    "mipmap-hdpi": 72,
    "mipmap-xhdpi": 96,
    "mipmap-xxhdpi": 144,
    "mipmap-xxxhdpi": 192,
}
LEGACY_MARK_FRAC = 0.56  # 图形占整图比例

# adaptive icon 前景层：108dp 画布，中心 72dp 才保证可见 → 比例必须 < 0.667
ADAPTIVE_SIZES = {
    "mipmap-mdpi": 108,
    "mipmap-hdpi": 162,
    "mipmap-xhdpi": 216,
    "mipmap-xxhdpi": 324,
    "mipmap-xxxhdpi": 432,
}
ADAPTIVE_MARK_FRAC = 0.62

# 启动图：以 dp 为单位定义，按密度换算成 px
LAUNCH_LOGO_DP = 112
LAUNCH_DENSITY = {
    "drawable-mdpi": 1.0,
    "drawable-hdpi": 1.5,
    "drawable-xhdpi": 2.0,
    "drawable-xxhdpi": 3.0,
    "drawable-xxxhdpi": 4.0,
}


# ---------------------------------------------------------------- 绘制原语


def linear_gradient(size: int, c0: tuple[int, int, int], c1: tuple[int, int, int]) -> Image.Image:
    """左上到右下的对角线性渐变。渐变本身平滑，不需要超采样。"""
    img = Image.new("RGB", (size, size))
    px = img.load()
    denom = max(1, 2 * (size - 1))
    for y in range(size):
        row = y / denom
        for x in range(size):
            t = row + x / denom
            px[x, y] = (
                int(c0[0] + (c1[0] - c0[0]) * t),
                int(c0[1] + (c1[1] - c0[1]) * t),
                int(c0[2] + (c1[2] - c0[2]) * t),
            )
    return img


def rounded_square_mask(size: int, radius_frac: float, ss: int = SS) -> Image.Image:
    """圆角方形遮罩。在放大 ss 倍后绘制再缩回，得到抗锯齿边缘。"""
    big = size * ss
    m = Image.new("L", (big, big), 0)
    ImageDraw.Draw(m).rounded_rectangle(
        [0, 0, big - 1, big - 1], radius=int(round(big * radius_frac)), fill=255
    )
    return m.resize((size, size), Image.LANCZOS)


def mark_mask(size: int, mark_frac: float, ss: int = SS) -> Image.Image:
    """相框 + 播放三角的白色遮罩（透明底）。"""
    big = size * ss
    m = Image.new("L", (big, big), 0)
    d = ImageDraw.Draw(m)

    ms = int(round(big * mark_frac))          # 图形边长
    off = (big - ms) // 2                      # 居中偏移
    stroke = max(2, int(round(ms * 0.080)))    # 相框线宽
    half = stroke // 2

    # 相框：圆角矩形描边
    d.rounded_rectangle(
        [off + half, off + half, off + ms - 1 - half, off + ms - 1 - half],
        radius=int(ms * 0.22),
        outline=255,
        width=stroke,
    )

    # 播放三角：光学居中（向右挪一点点，视觉上才像居中）
    cx = off + ms / 2.0
    cy = off + ms / 2.0
    h = ms * 0.34
    w = h * 0.866                              # 等边三角形的高宽比
    x0 = cx - w / 2.0 + w * 0.06
    d.polygon([(x0, cy - h / 2.0), (x0, cy + h / 2.0), (x0 + w, cy)], fill=255)

    return m.resize((size, size), Image.LANCZOS)


def tint(mask: Image.Image, color: tuple[int, int, int]) -> Image.Image:
    """把遮罩染成纯色，返回 RGBA。"""
    img = Image.new("RGBA", mask.size, color + (0,))
    img.putalpha(mask)
    return img


def tint_gradient(mask: Image.Image, c0, c1) -> Image.Image:
    """把遮罩填上渐变，返回 RGBA。"""
    img = linear_gradient(mask.size[0], c0, c1).convert("RGBA")
    img.putalpha(mask)
    return img


def write(img: Image.Image, density_dir: str, name: str) -> str:
    out_dir = os.path.join(RES, density_dir)
    os.makedirs(out_dir, exist_ok=True)
    path = os.path.join(out_dir, name)
    img.save(path, "PNG", optimize=True)
    return os.path.relpath(path, os.path.join(HERE, ".."))


# ---------------------------------------------------------------- 产出


def main() -> None:
    written: list[str] = []

    # 1) 传统图标：渐变圆角方底 + 白色图形
    for d, size in LEGACY_SIZES.items():
        bg = linear_gradient(size, BRAND_START, BRAND_END).convert("RGBA")
        bg.putalpha(rounded_square_mask(size, 0.22))
        icon = Image.alpha_composite(bg, tint(mark_mask(size, LEGACY_MARK_FRAC), (255, 255, 255)))
        written.append(write(icon, d, "ic_launcher.png"))

    # 2) adaptive 前景层：只有白色图形，底色由 drawable 提供
    for d, size in ADAPTIVE_SIZES.items():
        fg = tint(mark_mask(size, ADAPTIVE_MARK_FRAC), (255, 255, 255))
        written.append(write(fg, d, "ic_launcher_foreground.png"))

    # 3) 启动图 logo：浅色底上用渐变图形（不是白色，否则在浅底上看不见）
    for d, scale in LAUNCH_DENSITY.items():
        size = int(round(LAUNCH_LOGO_DP * scale))
        logo = tint_gradient(mark_mask(size, 0.92), BRAND_START, BRAND_END)
        written.append(write(logo, d, "launch_image.png"))

    for w in written:
        print(w)
    print(f"\n共 {len(written)} 个文件")


if __name__ == "__main__":
    main()
