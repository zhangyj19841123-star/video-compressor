# 第三方组件与许可声明

## 本项目代码

Copyright (C) 2026 VideoCompressor contributors

本仓库中的 Swift / PowerShell / 批处理 / Python / 脚本文档以 **GNU General Public License v3.0 or later (GPL-3.0-or-later)** 授权，全文见 [LICENSE](LICENSE)。

## 内嵌的 FFmpeg

本项目的预编译成品包内嵌 FFmpeg 可执行文件。FFmpeg 以 GPL 兼容方式构建（包含 libx265 / libx264），因此整体分发适用 **GPL-3.0**。

| 平台 | 使用版本 | 来源 | 许可证 |
|---|---|---|---|
| macOS | ffmpeg 9.0（arm64，imageio-ffmpeg 构建） | https://github.com/imageio/imageio-ffmpeg | GPL-3.0-or-later |
| Windows | ffmpeg **7.0.2 essentials**（x86_64） | https://github.com/GyanD/codexffmpeg/releases/tag/7.0.2 | GPL-3.0-or-later |

FFmpeg 官方源码与构建说明：https://ffmpeg.org/download.html
上述二进制发行包内均附有 `LICENSE` 与 `README.txt`，**成品包中原样保留**，请勿删除。

### 为什么 Windows 固定用 7.0.2

新版 FFmpeg（8.x）Windows 构建改用 UCRT64 工具链，导入表依赖 `api-ms-win-crt-*` / `ucrtbase.dll`，原生 Windows 7 不自带这些运行库，无法直接运行。7.0.2 essentials 只依赖 `msvcrt.dll` 与系统 DLL，可在未装任何 VC++ / UCRT 运行库的原生 Win7 x64 上直接运行。因此**不要随意升级 Windows 引擎版本**，除非确认新构建仍不依赖 UCRT。

## 分发者的义务

如果你重新分发本项目的**预编译成品包**（含 ffmpeg 二进制），请一并：

1. 保留包内的 `LICENSE` 与 `README.txt`；
2. 以 GPL-3.0 提供对应完整源码（最简单的方式是附上本仓库地址及对应 commit / tag）；
3. 说明对 ffmpeg 所做的任何修改（本项目未修改 ffmpeg，仅原样内嵌）；
4. 不附加限制下游用户权利的额外条款。

仅分发本仓库源码、或仅内部自用，不受上述二进制分发条款约束。

## 图标

`AppIcon.icns` 由仓库内 `macos/make_icon.py` 现场生成（纯 Python 标准库绘制），不含第三方素材。

## 商标

本项目与 Apple、Microsoft、FFmpeg 及上述各上游项目无隶属或背书关系。产品名称仅为功能描述。
