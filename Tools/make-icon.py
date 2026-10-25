#!/usr/bin/env python3
"""从 Assets/*.svg 生成桌宠图标和 app 图标。

三个标志都是单色的（Claude 珊瑚、GPT 黑、Gemini 紫），QuickLook 渲染出来的
PNG 带白底。这里按「白底 + 单色」反推出 alpha，得到干净的透明边缘，再按目标
颜色（或渐变）重画。

    python3 Tools/make-icon.py

产物：
    Assets/claude-mark.png / gpt-mark.png / gemini-mark.png   透明底标志
    Assets/AppIcon.icns                                     app 图标（奶油底圆角方块）
"""

import os
import shutil
import subprocess
import tempfile
from collections import Counter

from PIL import Image, ImageDraw, ImageFilter

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ASSETS = os.path.join(ROOT, "Assets")
ICNS = os.path.join(ASSETS, "AppIcon.icns")
CREAM = (240, 238, 230)  # #F0EEE6

# 名字 → (源 SVG, 输出 PNG, 颜色或渐变)
# 渐变按对角线从左上到右下取 3 个色标
ICONS = {
    "claude": ("claude-mark.svg", "claude-mark.png", [(217, 119, 87)], "vertical"),
    "gpt": ("gpt-mark.svg", "gpt-mark.png", [(16, 163, 127)], "vertical"),
    "gemini": ("gemini-mark.svg", "gemini-mark.png",
               [(66, 133, 244), (155, 114, 203), (217, 101, 112)], "vertical"),
}


def render_svg(svg, size=1024):
    """用 macOS 自带的 QuickLook 把 SVG 渲染成 PNG（白底）。"""
    tmp = tempfile.mkdtemp()
    try:
        subprocess.run(["qlmanage", "-t", "-s", str(size), "-o", tmp, svg],
                       check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        out = os.path.join(tmp, os.path.basename(svg) + ".png")
        return Image.open(out).convert("RGB").copy()
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def solid_color(rgb):
    """取图里最常见的非白色，就是标志本身的颜色。"""
    counts = Counter(rgb.getdata())
    for color, _ in counts.most_common():
        if min(color) < 240:
            return color
    return (0, 0, 0)


def key_out_white(rgb):
    """白底单色图 → 透明底的单通道遮罩（L 模式）。"""
    base = solid_color(rgb)
    # 离白最远的通道算 alpha 最稳
    channel = min(range(3), key=lambda i: base[i])
    scale = 255.0 - base[channel]
    alpha = rgb.split()[channel].point(
        lambda v: max(0, min(255, round((255 - v) / scale * 255))))
    return alpha


def paint(alpha, colors, axis="vertical"):
    """把遮罩按纯色或对角线渐变上色。"""
    w, h = alpha.size
    out = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    if len(colors) == 1:
        out.paste(Image.new("RGBA", (w, h), colors[0] + (255,)), (0, 0), alpha)
        return out

    gradient = Image.new("RGB", (w, h))
    pixels = gradient.load()
    for y in range(h):
        for x in range(w):
            if axis == "diagonal":
                t = (x + y) / (w + h - 2)      # 0 → 1，左上到右下
            else:
                t = y / (h - 1)                # 0 → 1，从上到下
            if t < 0.5:
                a, b, k = colors[0], colors[1], t * 2
            else:
                a, b, k = colors[1], colors[2], (t - 0.5) * 2
            pixels[x, y] = tuple(round(a[i] + (b[i] - a[i]) * k) for i in range(3))
    out.paste(gradient.convert("RGBA"), (0, 0), alpha)
    return out


def with_padding(im, ratio=0.04):
    pad = round(im.width * ratio)
    canvas = Image.new("RGBA", (im.width + pad * 2, im.height + pad * 2), (0, 0, 0, 0))
    canvas.paste(im, (pad, pad))
    return canvas


def soft_blob(diameter, color):
    """一颗带高光的软糖：中间偏亮，边缘略深，边上柔化。"""
    size = diameter
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    pixels = img.load()
    light = tuple(round(c + (255 - c) * 0.32) for c in color)
    r = (size - 1) / 2
    for y in range(size):
        for x in range(size):
            dx = (x - r) / r
            dy = (y - r) / r
            d = (dx * dx + dy * dy) ** 0.5
            if d > 1.0:
                continue
            edge = min(1.0, (1.0 - d) * (size / 2.0))  # 抗锯齿，约 1px
            k = max(0.0, 1 - d) ** 1.6                # 中心更亮
            c = tuple(round(color[i] + (light[i] - color[i]) * k) for i in range(3))
            pixels[x, y] = c + (round(255 * edge),)
    return img


def app_icon(size=1024):
    """奶油底圆角方块 + 三颗叠在一起的软糖（对应三个可切换的图标）。"""
    bg = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    ImageDraw.Draw(bg).rounded_rectangle(
        (0, 0, size - 1, size - 1), radius=round(size * 0.225), fill=CREAM + (255,))

    diameter = round(size * 0.42)
    centers = [(0.50, 0.375), (0.345, 0.605), (0.655, 0.605)]
    colors = [(217, 119, 87), (16, 163, 127), (122, 108, 232)]

    for (cx, cy), color in zip(centers, colors):
        blob = soft_blob(diameter, color)
        bg.alpha_composite(blob, (round(cx * size - diameter / 2),
                                  round(cy * size - diameter / 2)))
    return bg


def write_icns(im):
    tmp = tempfile.mkdtemp()
    try:
        iconset = os.path.join(tmp, "AppIcon.iconset")
        os.makedirs(iconset)
        for s in (16, 32, 128, 256, 512):
            for scale, suffix in ((1, ""), (2, "@2x")):
                px = s * scale
                im.resize((px, px), Image.LANCZOS).save(
                    os.path.join(iconset, f"icon_{s}x{s}{suffix}.png"))
        subprocess.run(["iconutil", "-c", "icns", iconset, "-o", ICNS],
                       check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def main():
    marks = {}
    for name, (svg_name, png_name, colors, axis) in ICONS.items():
        svg = os.path.join(ASSETS, svg_name)
        rgb = render_svg(svg)
        mark = with_padding(paint(key_out_white(rgb), colors, axis))
        mark.save(os.path.join(ASSETS, png_name))
        marks[name] = mark

        colors_used = mark.getcolors(maxcolors=1 << 20)
        opaque = sum(n for n, c in colors_used if c[3] > 200)
        print(f"{png_name}: {mark.size[0]}px，实心像素 {opaque / (mark.width * mark.height):.1%}")

    icon = app_icon()
    icon.save(os.path.join(ASSETS, "AppIcon.png"))
    write_icns(icon)
    print(f"AppIcon.icns")


if __name__ == "__main__":
    main()
