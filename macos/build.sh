#!/bin/bash
# 重新编译原生 macOS 应用（需要 Xcode / Command Line Tools）
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
APP="$HERE/视频压缩转换器.app"
RES="$APP/Contents/Resources"
MAC="$APP/Contents/MacOS"

# ffmpeg 需自行放置，见 README.md（本仓库不含二进制）
if [ ! -x "$HERE/bin/ffmpeg" ]; then
  echo "缺少 macos/bin/ffmpeg，请先按 README.md 准备（本仓库不含二进制）。" >&2
  exit 1
fi

# 没有图标就现场生成一个（纯 Python 标准库，无外部素材）
if [ ! -f "$HERE/AppIcon.icns" ] && command -v python3 >/dev/null 2>&1; then
  echo "生成应用图标…"
  python3 "$HERE/make_icon.py" || true
fi

mkdir -p "$RES" "$MAC"
rm -f "$MAC/launcher" "$MAC/VideoCompressor"
cp "$HERE/Info.plist" "$APP/Contents/Info.plist"
cp "$HERE/bin/ffmpeg" "$RES/ffmpeg"
chmod +x "$RES/ffmpeg"
if [ -f "$HERE/AppIcon.icns" ]; then cp "$HERE/AppIcon.icns" "$RES/AppIcon.icns"; fi

echo "编译原生窗口应用…"
swiftc -O -swift-version 5 -parse-as-library \
  -target arm64-apple-macosx13.0 \
  -framework SwiftUI -framework AppKit -framework UniformTypeIdentifiers \
  "$HERE/Sources/App.swift" -o "$MAC/VideoCompressor"

echo "签名（本机运行）…"
codesign --force --sign - "$APP" 2>/dev/null || true
echo "构建完成：$APP"
