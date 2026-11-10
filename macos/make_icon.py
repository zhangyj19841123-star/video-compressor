#!/usr/bin/env python3
"""生成 AppIcon.icns —— 纯 Python 标准库，无第三方依赖、无外部素材。

蓝色渐变圆角矩形 + 白色向下箭头（压缩/落盘）+ 底部横线。
需要 macOS 的 iconutil（Xcode Command Line Tools 自带）。
"""
import os
import shutil
import struct
import subprocess
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
ICONSET = os.path.join(HERE, "AppIcon.iconset")
OUT = os.path.join(HERE, "AppIcon.icns")

# icns 要求的十张 PNG
SPECS = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]


def color_at(u, v):
    """归一化坐标 (0..1) -> RGBA。"""
    # 蓝色竖向渐变 #2E7CF6 -> #1552C4
    bg = (
        int(46 + (21 - 46) * v),
        int(124 + (82 - 124) * v),
        int(246 + (196 - 246) * v),
    )

    r = 0.22
    qx = min(max(u, r), 1 - r)
    qy = min(max(v, r), 1 - r)
    dx, dy = u - qx, v - qy
    if dx * dx + dy * dy > r * r:
        # 圆角外透明，但保留背景色，避免抗锯齿平均时出现暗边
        return bg + (0,)

    shaft = 0.44 <= u <= 0.56 and 0.27 <= v <= 0.55          # 箭头竖杆
    triangle = 0.50 <= v <= 0.70 and abs(u - 0.5) <= (0.70 - v)  # 箭头尖
    bar = 0.76 <= v <= 0.81 and 0.30 <= u <= 0.70            # 底部横线
    if shaft or triangle or bar:
        return (255, 255, 255, 255)
    return bg + (255,)


def chunk(tag, data):
    return (struct.pack(">I", len(data)) + tag + data
            + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF))


SS = 2  # 每像素 2x2 超采样，消除圆角与箭头斜边的锯齿


def build_png(size):
    rows = bytearray()
    n = SS * SS
    inv = 1.0 / size
    for y in range(size):
        rows.append(0)  # PNG filter type: None
        for x in range(size):
            c0 = c1 = c2 = c3 = 0
            for sy in range(SS):
                v = (y + (sy + 0.5) / SS) * inv
                for sx in range(SS):
                    u = (x + (sx + 0.5) / SS) * inv
                    c = color_at(u, v)
                    c0 += c[0]; c1 += c[1]; c2 += c[2]; c3 += c[3]
            rows.extend((c0 // n, c1 // n, c2 // n, c3 // n))
    ihdr = struct.pack(">IIBBBBB", size, size, 8, 6, 0, 0, 0)  # RGBA8
    return (b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", ihdr)
            + chunk(b"IDAT", zlib.compress(bytes(rows), 9))
            + chunk(b"IEND", b""))


def main():
    if not shutil.which("iconutil"):
        raise SystemExit("找不到 iconutil，请先安装 Xcode Command Line Tools")

    os.makedirs(ICONSET, exist_ok=True)
    cache = {}
    for name, size in SPECS:
        if size not in cache:
            cache[size] = build_png(size)
        with open(os.path.join(ICONSET, name), "wb") as f:
            f.write(cache[size])

    subprocess.run(["iconutil", "-c", "icns", ICONSET, "-o", OUT], check=True)
    shutil.rmtree(ICONSET)
    print("生成完成:", OUT)


if __name__ == "__main__":
    main()
