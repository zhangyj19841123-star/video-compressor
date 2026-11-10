# Windows 版 · 使用与打包

## 直接运行（不打包也行）

把 `bin/ffmpeg.exe`、`bin/ffprobe.exe` 放好后，双击 `START.bat` 即可打开图形界面。源码里的文本文件已经按 Windows 规范处理好（CRLF / BOM），clone 后可直接用。

## 1. 准备 ffmpeg（关键：版本必须选对）

**请下载 [ffmpeg 7.0.2 essentials](https://github.com/GyanD/codexffmpeg/releases/tag/7.0.2) 的 `ffmpeg-7.0.2-essentials_build.zip`**，把其中 `bin/ffmpeg.exe`、`bin/ffprobe.exe` 放到本目录的 `bin/` 下。

### 为什么固定 7.0.2，不能随便升级

新版 FFmpeg（8.x）的 Windows 构建改用 UCRT64 工具链，导入表依赖 `api-ms-win-crt-*` / `ucrtbase.dll`，**原生 Windows 7 不自带这些运行库**，程序会直接报缺 DLL。7.0.2 essentials 只依赖 `msvcrt.dll` 与系统自带 DLL，在未装任何 VC++ / UCRT 运行库的原生 Win7 x64 上可直接运行。

如需验证某个构建是否 Win7-safe，检查导入表里有没有这些字符串：

```bash
python3 -c "b=open('bin/ffmpeg.exe','rb').read(); print([s for s in [b'api-ms-win-crt', b'ucrtbase', b'vcruntime', b'msvcp'] if s in b] or 'OK: no UCRT / VC++ dependency')"
```

输出 `OK` 才可用于 Win7。同时把发行包里的 `LICENSE`、`README.txt` 一并复制到 `bin/`，GPLv3 要求分发二进制时保留它们。

## 2. 一键打包

```bash
python3 windows/pack.py
```

产物：`dist/视频压缩转换器-Windows-Win7x64.zip`（GitHub Releases 上发布的同一份包使用 ASCII 名 `VideoCompressor-Windows-Win7x64.zip`，内容一致）。`pack.py` 会自动：

- 把所有 `.bat` / `.ps1` / `.txt` 统一转成 **CRLF**
- 给 `app.ps1` 与中文说明加 **UTF-8 BOM**（PowerShell 2.0 与 Win7 记事本按 ANSI 解释无 BOM 的 UTF-8 会乱码）
- 保证 `.bat` **不带 BOM 且为纯 ASCII**（BOM 会被 cmd 当成命令字符）
- 生成 ASCII 名的 `START.bat` 与 `README-CN.txt`，避免不同语言版 Windows 解压中文名乱码
- 用干净的 zip 打包（不含 `__MACOSX` / AppleDouble 垃圾文件）

> 仓库里的源码统一为 LF / 无 BOM，`pack.py` 负责转换成 Windows 发布格式。请勿绕过它直接把源码目录压缩分发。

## 3. 成品包结构

```
VideoCompressor-Win7x64/
├── START.bat                    # 主入口（ASCII 名，双击这个）
├── 视频压缩转换器.bat            # 同一个启动器的中文别名
├── Drag videos onto me.bat      # 保底：拖视频到它上面，纯 cmd，不需要 PowerShell
├── app.ps1                      # WinForms 界面 + 转码队列
├── README-CN.txt                # 中文使用说明
└── bin/
    ├── ffmpeg.exe
    ├── ffprobe.exe
    ├── LICENSE
    └── README.txt
```

## 兼容性设计

| 目标 | 做法 |
|---|---|
| Windows 7 起可用 | PowerShell 2.0 + .NET 3.5 + WinForms 均为系统自带；不引入任何需安装的运行库 |
| 被安全策略拦截 PowerShell 时仍可用 | `Drag videos onto me.bat` 纯 cmd 保底，完全不依赖 .NET |
| 任意 x64 CPU | 不要求 AVX / 独显 / 硬件编码，纯软件编码 |
| 音轨不兼容 | `-c:a copy` 失败时自动重试 `-c:a aac -b:a 192k` |
| 不同语言版 Windows | 主启动器与说明用 ASCII 名，中文名带 UTF-8 标志作别名 |
| Win7/8 播放器不支持 HEVC | 界面可切 H.264；说明里提示用 VLC / PotPlayer |

## 目录说明

```
windows/
├── app.ps1                     # GUI 主体：拖放、队列、进度、档位、SSIM 校验
├── START.bat                   # 启动 GUI
├── 视频压缩转换器.bat           # 中文别名
├── Drag videos onto me.bat     # 无 GUI 保底脚本
├── 使用说明.txt                 # 成品包内中文说明的源文件
├── pack.py                     # 一键打包（编码/换行/zip）
└── bin/                        # 自行放置 exe，已被 .gitignore 忽略
```

## 实现要点

- 压缩参数与 macOS 版完全一致，保证两个平台输出结果可对齐。
- `-fps_mode cfr -r <源帧率> -video_track_timescale 30000` 强制恒定帧率并固定时间基。
- 串行队列避免多任务并发抢占 CPU；进度由 ffmpeg `-progress <文件>` 轮询。
- 后台调用 ffmpeg 加 `-nostdin`，防止子进程等待标准输入挂起。
