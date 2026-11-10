# macOS 版 · 从源码构建

## 依赖

- macOS 13+，Apple Silicon
- Xcode Command Line Tools：`xcode-select --install`（提供 `swiftc` / `codesign` / `iconutil`）
- Python 3（仅用于生成图标和取 ffmpeg，系统自带即可）

## 1. 准备 ffmpeg

本仓库不含二进制。任选一种方式，把可执行文件放到 `macos/bin/ffmpeg`：

**方式 A：imageio-ffmpeg（推荐，最省事）**

```bash
python3 -m pip install --user imageio-ffmpeg
FF=$(python3 -c "import imageio_ffmpeg; print(imageio_ffmpeg.get_ffmpeg_exe())")
mkdir -p macos/bin
cp "$FF" macos/bin/ffmpeg
chmod +x macos/bin/ffmpeg
```

该构建为 arm64，含 `libx265` / `libx264`。确认编码器可用：

```bash
macos/bin/ffmpeg -hide_banner -encoders | grep -E 'libx26[45]'
```

**方式 B：X86_64 / 其它构建**

从 https://ffmpeg.org/download.html 或 Homebrew 取含 `libx265` 的版本，同样放到 `macos/bin/ffmpeg`。Intel Mac 必须换 x86_64 构建，并把 `build.sh` 里的 `-target arm64-apple-macosx13.0` 改为 `x86_64-apple-macosx13.0`。

## 2. 生成应用图标（可选）

```bash
python3 macos/make_icon.py
```

纯 Python 标准库绘制，产物 `macos/AppIcon.icns`。已有图标时 `build.sh` 会直接用，跳过此步也可以（应用仍能运行，只是没有图标）。

## 3. 编译

```bash
cd macos && ./build.sh
```

产物：`macos/视频压缩转换器.app`，自包含内嵌 ffmpeg，ad-hoc 签名，可直接双击运行。

> 首次打开若被 Gatekeeper 拦截：右键 App → 打开 → 再点「打开」。ad-hoc 签名未做 Apple 公证，属正常现象。若需对外分发，建议用开发者 ID 重新签名并公证。

## 4. 跑自测（可选，不需要 GUI）

```bash
cd macos
swiftc -O -D VC_CLI -parse-as-library \
  Sources/App.swift Sources/SelfTestMain.swift \
  -o /tmp/vc-selftest
VC_FFMPEG="$PWD/bin/ffmpeg" /tmp/vc-selftest /path/to/sample.mp4
```

自测会做一次真实转码，打印压缩率、SSIM、输出帧率与 VFR 检测结果。参考结果：

```
SELFTEST probe: 2940x1912 29.97fps 6.10s 12589354 bytes audio=true
SELFTEST OK: 12589354 -> 2686932, saved 78.7%
SELFTEST SSIM: 0.998957 | fps: 29.97 | VFR: 0.000000
```

## 目录说明

```
macos/
├── Sources/App.swift           # 引擎、任务队列、SwiftUI 界面、Dock 拖放
├── Sources/SelfTestMain.swift  # CLI 自测入口（VC_CLI 宏隔离）
├── Info.plist                  # bundle 配置与文档类型注册
├── build.sh                    # 一键编译 + 内嵌 ffmpeg + ad-hoc 签名
├── make_icon.py                # 纯标准库生成 AppIcon.icns
└── bin/ffmpeg                  # 自行放置，已被 .gitignore 忽略
```

## 实现要点

- 整个 `ContentView` 挂 `.onDrop(of: [.fileURL])`，拖入即入队开压；拖到 Dock 图标走 `AppDelegate.application(_:openFiles:)`。
- 后台调用 ffmpeg 必须加 `-nostdin`，否则子进程会等待标准输入而挂起。
- 进度用 `-progress <临时文件>` 定期轮询，比解析 stderr 稳定。
- 恒定帧率：`-fps_mode cfr -r <源帧率> -video_track_timescale 30000`。
- HEVC 输出使用 `-tag:v hvc1`，否则 QuickTime / iOS 不识别。
