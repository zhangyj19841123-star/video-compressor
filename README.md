# 视频压缩转换器 · Video Compressor

> **把视频拖进窗口，松手就开始压缩。** 不改分辨率、不降帧、不掉画质，体积通常缩到原来的 1/3 ~ 1/4。

A free, open-source, drag-and-drop video compressor for macOS and Windows. It keeps resolution, frame rate and near-lossless quality while shrinking file size — fully offline, no upload, no account, no ads.

完全免费、开源，欢迎任何人下载、使用、修改和再分发。

---

## 它解决什么问题

录屏、手机视频、剪辑软件导出的素材动辄几百 MB，发微信、传网盘、做归档都很痛苦。这个工具只做一件事：用更高效的 HEVC 编码把视频重新压制一遍，**画面内容不变，只把容量压下来**。

## 核心功能

| | |
|---|---|
| **拖进去就压** | 整个窗口都是拖放区，也能拖到 macOS Dock 图标；不需要点「开始」按钮 |
| **画质优先** | 默认 HEVC CRF 16（视觉近无损），全片实测 SSIM `0.999323` / PSNR `57.94 dB` |
| **稳定帧率** | 输出强制恒定帧率（CFR）并固定 MP4 时间基，剪辑软件里不会音画不同步 |
| **什么都不改** | 不缩放、不降帧、不改色彩，音轨直接复制不二次编码，原文件永不被修改 |
| **批量队列** | 一次拖入多个视频自动串行处理，显示进度，可随时取消 |
| **完全离线** | 内嵌 ffmpeg，不联网、不上传、无账号、无广告、无遥测 |
| **两个平台** | macOS 原生 SwiftUI 应用；Windows 免安装绿色版，兼容到 Windows 7 x64 |

界面里还可以切换画质档位（CRF 16/18/20/22）、HEVC / H.264 编码、是否保留音轨、是否做 SSIM 画质校验，以及自定义输出目录。

## 实测效果

测试素材：macOS 屏幕录制，`2940×1912` / `29.97 fps` / H.264 + AAC / 2 分 51 秒。

| 指标 | 原始 | 压缩后 |
|---|---|---|
| 体积 | 105 MB（110,031,382 B） | **28.4 MB（29,816,549 B），↓ 72.9%** |
| 分辨率 | 2940×1912 | 2940×1912（不变） |
| 帧率 | 29.97 fps | 29.97 fps（CFR，VFR = 0） |
| 色彩 | BT.709 | BT.709（不变） |
| 音轨 | AAC | AAC（直接复制） |
| 客观画质 | — | SSIM `0.999323`，PSNR `57.94 dB` |

> 屏幕录制类素材（大面积静态区域 + 文字）压缩收益最明显。实拍视频同样有效，但幅度会小一些。

## 下载

成品包在 [Releases](../../releases/latest) 中免费提供，解压即用：

| 平台 | 下载 | 大小 | 说明 |
|---|---|---|---|
| macOS | `视频压缩转换器-macOS.zip` | 22 MB | 原生 `.app`，Apple Silicon（M 系列） |
| Windows | `视频压缩转换器-Windows-Win7x64.zip` | 59 MB | 免安装，Win7 / 8 / 8.1 / 10 / 11 **64 位** |

也可以按 [从源码构建](#从源码构建) 自己编译，不依赖任何预编译包。

## 快速开始

**macOS**
1. 解压 zip，把 `视频压缩转换器.app` 拖进「应用程序」。
2. 首次打开若提示「无法验证开发者」，右键 → 打开 → 再点「打开」（本应用为 ad-hoc 签名，未走 Apple 公证）。
3. 打开后把视频拖进窗口，松手即开始压缩。

**Windows**
1. 解压 zip，**整个文件夹**解压出来再运行（不要只把 `.bat` 单独拖出来）。
2. 双击 `START.bat` 打开窗口，把视频拖进去。
3. 如果公司安全策略拦截了 PowerShell，把视频直接拖到 `Drag videos onto me.bat` 上，效果一样。

输出默认保存在「视频 > 视频压缩输出」，文件名为 `原名_压缩版.mp4`，同名自动加序号。

## 画质档位

界面里可切换，数值来自 8 秒样本的实测标定：

| 档位 | SSIM | 样本体积 | 建议 |
|---|---|---|---|
| CRF 16（默认） | 0.999303 | 1.20 MB | 视觉近无损，画质优先 |
| CRF 18 | 0.999105 | 0.99 MB | 几乎看不出差别 |
| CRF 20 | 0.998846 | 0.83 MB | 网络分发、体积优先 |
| CRF 22 | 0.998533 | 0.69 MB | 文字边缘开始可辨差异 |

再往下压收益很小、画质损失变明显，因此没有提供更激进的档位。

## 为什么能压这么小

H.264 → HEVC（H.265）是编码效率的代际提升：同样的画面，HEVC 用更少的比特就能描述。配合 CRF（恒定质量因子）模式，编码器把比特动态分配给复杂画面、静态区域则大幅省码。

关键在于**没有牺牲任何画面信息**：不缩放、不降帧、不调色、不动音轨，纯粹靠编码效率换体积。默认参数：

```
-c:v libx265 -preset medium -crf 16 -pix_fmt yuv420p -tag:v hvc1
-color_primaries bt709 -color_trc bt709 -colorspace bt709
-c:a copy -fps_mode cfr -r <源帧率> -video_track_timescale 30000
-movflags +faststart
```

`-tag:v hvc1` 保证 QuickTime / iOS / macOS 能识别；`-fps_mode cfr` 与固定时间基保证帧率稳定。

## 系统要求

- **macOS 13+**，Apple Silicon。内嵌 ffmpeg 为 arm64；Intel Mac 需替换为 x86_64 版本后重跑 `build.sh`。
- **Windows 7 x64 / 8 / 8.1 / 10 / 11**，任意 x64 CPU，不需要 AVX、独显或额外运行库。
- Win7 / Win8 自带播放器**不支持 HEVC**，请用 VLC / PotPlayer 播放，或在界面改选「H.264 · 老设备兼容」。

更多问题见 [常见问题](docs/FAQ.md)。

## 从源码构建

仓库里**不包含** ffmpeg 二进制（体积大，且 GitHub 对单文件有 100 MB 限制）。构建前请按各平台说明把 ffmpeg 放到指定位置：

- [macOS 构建说明](macos/README.md) — 编译原生 `.app`、生成图标、跑自测
- [Windows 构建说明](windows/README.md) — 获取 Win7 兼容版 ffmpeg、一键打包含编码/换行处理

## 许可证与合规

本项目采用 **GPL-3.0**，见 [LICENSE](LICENSE)。第三方组件与源码获取说明见 [NOTICE.md](NOTICE.md)。

简单说：可以自由使用、修改、分发，包括商用；但分发编译产物时须同样以 GPL-3.0 开源并提供对应源码。这是内嵌的 ffmpeg（GPLv3）所要求的，也保护这个项目不被闭源套壳。

## 致谢

- [FFmpeg](https://ffmpeg.org/) — 音视频处理核心
- [GyanD/codexffmpeg](https://github.com/GyanD/codexffmpeg) — Windows 版 7.0.2 构建
- [imageio-ffmpeg](https://github.com/imageio/imageio-ffmpeg) — macOS 版 ffmpeg 二进制来源
