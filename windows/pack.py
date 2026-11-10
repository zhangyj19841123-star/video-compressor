#!/usr/bin/env python3
"""把 windows/ 源码打包成 Windows 7 x64 可直接使用的免安装 zip。

做三件源码里不便直接维护的事：
  1. 所有文本统一 CRLF（Win7 的 cmd 与记事本对纯 LF 支持很差）
  2. .ps1 / 中文说明加 UTF-8 BOM；.bat 保持无 BOM 且纯 ASCII
  3. 生成 ASCII 名的 START.bat / README-CN.txt 兜底，避免中文名解压乱码

用法：python3 windows/pack.py
产物：windows/dist/视频压缩转换器-Windows-Win7x64.zip
"""
import os
import sys
import time
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
OUT_DIR = os.path.join(HERE, "dist")
OUT = os.path.join(OUT_DIR, "视频压缩转换器-Windows-Win7x64.zip")
ARC_ROOT = "VideoCompressor-Win7x64"
REQUIRED_BIN = ["ffmpeg.exe", "ffprobe.exe", "LICENSE", "README.txt"]


def to_crlf(data):
    data = data.replace(b"\r\n", b"\n").replace(b"\r", b"\n")
    return data.replace(b"\n", b"\r\n")


def norm(rel, bom):
    """读源码文件，去 BOM，转 CRLF，按需重新加 BOM。"""
    with open(os.path.join(HERE, rel), "rb") as f:
        data = f.read()
    if data.startswith(b"\xef\xbb\xbf"):
        data = data[3:]
    data = to_crlf(data)
    return (b"\xef\xbb\xbf" + data) if bom else data


def check_bat(name, data):
    bad = [c for c in data if c > 127]
    if bad or data.startswith(b"\xef\xbb\xbf"):
        raise SystemExit(f"{name} 必须是无 BOM 的纯 ASCII，请检查中文字符")


def main():
    missing = [n for n in REQUIRED_BIN
               if not os.path.isfile(os.path.join(HERE, "bin", n))]
    if missing:
        print("缺少 bin/ 文件:", ", ".join(missing))
        print("请按 windows/README.md 下载 ffmpeg 7.0.2 essentials 并放到 bin/")
        return 1

    ps1 = norm("app.ps1", True)
    start = norm("START.bat", False)
    cn_bat = norm("视频压缩转换器.bat", False)
    drag = norm("Drag videos onto me.bat", False)
    readme = norm("使用说明.txt", True)

    for name, data in [("START.bat", start), ("视频压缩转换器.bat", cn_bat),
                       ("Drag videos onto me.bat", drag)]:
        check_bat(name, data)

    texts = [
        ("START.bat", start),                  # ASCII 主入口
        ("视频压缩转换器.bat", cn_bat),         # 中文别名（UTF-8 标志）
        ("Drag videos onto me.bat", drag),    # 无 GUI 保底
        ("app.ps1", ps1),
        ("README-CN.txt", readme),            # ASCII 名中文说明
    ]
    bins = [("bin/" + n, os.path.join(HERE, "bin", n)) for n in REQUIRED_BIN]

    os.makedirs(OUT_DIR, exist_ok=True)
    t0 = time.time()
    with zipfile.ZipFile(OUT, "w", zipfile.ZIP_DEFLATED, compresslevel=6,
                         allowZip64=True) as z:
        for arc, data in texts:
            info = zipfile.ZipInfo(ARC_ROOT + "/" + arc,
                                   date_time=time.localtime()[:6])
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o644 << 16
            info.create_system = 0
            # Python zipfile 自动为非 ASCII 名设置 UTF-8 标志 (0x800)
            z.writestr(info, data)
        for arc, path in bins:
            z.write(path, ARC_ROOT + "/" + arc)

    with zipfile.ZipFile(OUT) as z:
        bad = z.testzip()
        junk = [n for n in z.namelist() if "__MACOSX" in n or "/._" in n]
    if bad or junk:
        print("打包校验失败:", bad or "含垃圾条目", junk)
        return 1

    print("打包完成:", OUT)
    print(f"大小: {os.path.getsize(OUT) / 1024 / 1024:.1f} MB, "
          f"共 {len(texts) + len(bins)} 个文件, 耗时 {time.time() - t0:.1f}s")
    print("校验: zip 完整、无 __MACOSX、CRLF/BOM 规范")
    return 0


if __name__ == "__main__":
    sys.exit(main())
