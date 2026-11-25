# MediaForge 0.2

一个使用 **SwiftUI + 内置 FFmpeg** 的 macOS 本地媒体转换应用。**打开即可转换**：引擎已随应用内置，不需要安装 Homebrew、下载插件或配置终端。

- **平台：** macOS 14+，Apple Silicon（arm64）。Intel Mac 需自行从源码构建。
- **引擎：** 内置本机构建的 FFmpeg 9.0 + ffprobe 9.0（GPL-3.0-or-later），静态链接、仅依赖 Apple 系统库。
- **界面：** 中文界面，支持浅色、深色和跟随系统，可在「设置 → 外观」切换。视频 / 音频 / 图片分类，支持拖放和批量导入。
- **隐私：** 转换全程本地，不上传文件，不需要网络。只有点击文档链接才会打开浏览器。
- **安全：** 不覆盖源文件或已有结果；重名自动编号；先写临时文件、成功后原子提交；失败或取消清理临时文件。

按[从源码构建](#从源码构建)的步骤打包后，运行 `open dist/MediaForge.app`。默认打包方式使用本机 ad-hoc 签名。

### 最基本的用法

1. 从首页或左侧选择 **视频处理**、**音频处理** 或 **图片处理**，然后点相应的工具卡片。
2. 拖入媒体或按 ⌘O 添加文件，再选择输出格式。普通转换的批量导入按媒体类型进入对应队列，压缩和音轨提取有各自的队列。结果默认保存到每个源文件旁的 **MediaForge 输出** 文件夹。
3. 在左侧 **任务中心** 查看本次运行的任务、失败原因与已完成结果。可以返回队列重试失败任务，或在 Finder 中显示已完成的文件。

右侧快捷预设只调整编码与质量，输出格式由分类默认值或文件行单独决定。默认的 **与源文件相同** 保留原始尺寸与帧率，兼容的音视频流直接保留，其他情况按高质量编码。用右侧 **参数设置** 编辑默认参数，或用文件行的 **参数** 单独调整。编辑窗口按输出类型显示视频、音频、图片或动画选项，编码器按目标容器与当前引擎筛选。

## 功能

| 功能 | 说明 |
|---|---|
| 批量队列 | 串行执行，单个文件失败不影响后续；可重试、移除、清除已完成 |
| 进度与停止 | 有 ffprobe 时显示百分比；停止会尽快终止当前进程并清理临时文件 |
| 目标格式 | 默认格式按视频、音频、图片设置。视频任务的格式菜单提供 **提取音频** 和 **导出动画** 子菜单 |
| 压缩 | 视频和图片各有独立工具，支持选择输出格式与压缩质量 |
| 提取音频 | 从视频导出第一条音轨，目标格式兼容时直接保留源编码 |
| 音视频分离 | 选择一个含音轨的视频，导出无声 MP4 和独立 M4A |
| 音视频合并 | 时间线支持吸附、缩放和拖动播放头看画面，可移动视频轨与带频谱的音频轨，或输入精确偏移。支持 MP4、MOV、MKV、WebM 和独立编码参数，输出以裁剪后的视频长度为准 |
| 动画保留 | GIF / WebP / APNG 之间互转，保留帧与帧间时序 |
| 分辨率 | 原始 / 480p / 720p / 1080p / 2160p / 自定义边界；等比缩小、不放大、不拉伸 |
| 帧率 | 保持源时序，或指定 10–60 fps（带抽帧/补帧提示） |
| 视频编码 | H.264、HEVC、VP9、AV1、Apple ProRes、MPEG-1、MPEG-2、MPEG-4 Part 2（按容器限定） |
| 硬件加速 | 默认使用 VideoToolbox 加速兼容视频的解码及 H.264、HEVC、ProRes 编码，硬件处理失败时自动转用软件处理。CRF 使用软件编码。可在「设置 → 转换引擎」关闭，在「任务中心」查看实际处理方式 |
| 音频编码 | AAC、ALAC、AC-3、E-AC-3、DTS、FLAC、MP2、MP3、Opus、Vorbis、PCM（按容器限定） |
| 编码参数 | 独立的视频码率设置支持默认（参考源视频）、CBR、ABR 和 CRF。MP4、MOV、MKV、WAV 和 AIFF 支持 PCM，采样率可用常见预设或自定义 Hz |
| 保存位置 | 默认源文件旁，也可指定文件夹；不覆盖、不删除原文件 |
| 参数记忆 | 输出位置、默认格式、预设和高级参数会记住 |
| 引擎信息 | 设置页显示内置引擎状态、可用编码器、开源许可与来源 |

## 目标格式（20 种）

| 类别 | 格式 |
|---|---|
| 视频 | MP4、MOV、MKV、WebM |
| 音频 | MP3、M4A、WAV、FLAC、OGG、AIFF、Opus、AAC |
| 图片 | PNG、JPEG、WebP、TIFF、BMP、GIF、APNG、AVIF |

可导入的扩展名（不等于一定能解码）：

- 视频：MP4、MOV、MKV、WebM、AVI、M4V、MPG、MPEG、MTS、M2TS、TS、VOB、WMV、FLV、3GP、OGV
- 音频：MP3、M4A、WAV、FLAC、OGG、OGA、AIF、AIFF、AAC、Opus、WMA、CAF、ALAC、AMR
- 图片：PNG、JPG、JPEG、WebP、TIF、TIFF、BMP、GIF、APNG、HEIC、HEIF、AVIF、JXL、ICO

## 动画说明（请读）

- 支持 GIF、动画 WebP、APNG 三者互转，也可从视频导出这三类动画。
- 保留所有帧与帧间时序。**循环次数不继承源文件**，由设置决定（默认无限循环，可选仅播放一次）。
- 指定帧率会对动画抽帧或补帧，详情面板会明确提示；不指定则保留源时序。
- 动画导出为静图或静态格式时，应用会先警告“只保留首帧”，需确认才继续。
- 精度限制：GIF 时间量化到 10ms、透明度为二值；WebP 时间精度 1ms；APNG 保留 alpha 与较高时间精度。libwebp 可能合并视觉相同的帧，但总展示时长会被修正。
- 已知缺陷修复：FFmpeg 9 的 WebP 动画编码器会把最后一帧时长写成平均值，本应用会修正该字段。
- 视频→动画不含音轨。

## 明确的限制

- 不支持 DRM 解密；不承诺“市面上所有格式”。
- 视频只处理第一条视频流与第一条音轨；字幕、多音轨、章节、附件不保证保留。
- 视频输出为 8-bit YUV 4:2:0（ProRes 为 10-bit 4:2:2）；奇数宽高会补边至偶数。无 HDR 色调映射、无专业色彩管理、不保证元数据保真。
- AVIF 为静态输出，不承诺 HDR / ICC / alpha 的完整保留。
- 图片输出不做多页 TIFF 等结构保留。
- 没有暂停续传、崩溃恢复或持久化历史。强制结束应用或断电可能留下 `.mediaforge-*` 临时文件；确认无转换运行后可手动删除。
- 输出目录应为可写的本地文件夹；特殊网络文件系统的原子提交未验证。
- 当前未启用 App Sandbox，也没有 iOS 版本（iOS 不能运行外部 FFmpeg 进程）。

## 许可证与对应源码

MediaForge 的自有源码采用 **GPL-3.0-or-later**，见 [LICENSE](LICENSE)。第三方组件保留各自的许可证与版权声明。

内置的 ffmpeg / ffprobe 由本项目从固定源码构建，许可为 **GPL-3.0-or-later**，静态链接 x264、x265、libvpx、libwebp、libaom、Opus、LAME、libogg、libvorbis。

**分发本应用时必须随附匹配的对应源码归档** `MediaForge-engine-source-9.0.tar.gz`（约 42 MB）。它包含全部原始源码归档、固定 SHA-256 清单、构建脚本、构建记录、完整日志与许可通知。应用内 `Contents/Resources/ThirdParty/` 也保存了来源、许可与构建审计。

提供真实对应源码解决了此前只有第三方预编译二进制的来源缺口，但**不是**法律或专利的全面豁免。公开分发前请自行评估 GPL 义务、EULA 兼容性、编解码专利与签名/公证。详见 [ThirdParty/NOTICE.md](ThirdParty/NOTICE.md)。

## 从源码构建

需要 Swift 6.0+、macOS SDK 与 Xcode 或 Command Line Tools。

```bash
swift build --product MediaForge      # 仅编译
swift run MediaForge                  # 开发运行（使用 .tools 或系统 FFmpeg）
bash scripts/build-app.sh             # 生成 dist/MediaForge.app（需要内置引擎，见下）
```

若本机没有已构建的引擎，先执行（约 20–40 分钟，需网络下载固定源码）：

```bash
DEVELOPER_DIR=/Library/Developer/CommandLineTools /usr/bin/python3 scripts/build-engine.py --jobs 2
DEVELOPER_DIR=/Library/Developer/CommandLineTools /usr/bin/python3 scripts/package-engine-source.py
DEVELOPER_DIR=/Library/Developer/CommandLineTools MEDIAFORGE_REPLACE_APP=1 bash scripts/build-app.sh
```

完整 Xcode 中可用 **File → Open** 打开 `Package.swift`，选择 `MediaForge` 产品运行。

### 测试

```bash
# 不依赖 XCTest 的引擎/参数/动画/安全回归（约 1 分钟）
MEDIAFORGE_FFMPEG="$PWD/.tools/source-build/prefix/bin/ffmpeg" \
MEDIAFORGE_FFPROBE="$PWD/.tools/source-build/prefix/bin/ffprobe" \
swift run MediaForgeChecks

# 已打包应用的自检：验证内置引擎、分类队列、分离合并与动画确认
dist/MediaForge.app/Contents/MacOS/MediaForge --self-check
```

Command Line Tools 环境运行 `swift test` 可能报 `no such module 'XCTest'`，这不影响应用构建；请用上面的独立检查程序或安装完整 Xcode。

最近一次构建与验收结果见 [VERIFICATION.md](VERIFICATION.md)。

## 代码结构

```text
Sources/
  MediaForge/
    MediaForgeApp.swift          应用入口、退出确认
    MediaForgeEntry.swift        --self-check 诊断入口
    AppSelfCheck.swift           内置引擎与队列的端到端自检
    AppStore.swift               队列状态、导入、输出编号、启动/停止
    ConversionPreferences.swift  预设、容器参数规范化、任务摘要
    InspectorView.swift          设置面板与高级参数
    ContentView.swift            主界面、任务行、空状态
    ToolSettingsView.swift       引擎信息、许可入口
    EngineLocator.swift          内置引擎定位（优先 Contents/Helpers）
    ImportMediaHints.swift       APNG 等导入识别
    WindowCloseGuard.swift       转换中关闭窗口确认
  MediaForgeCore/
    MediaModels.swift            格式、工具发现、错误
    ConversionOptions.swift      编码器/分辨率/码率/动画模型与校验
    FFmpegArguments.swift        FFmpeg 参数构造
    AnimationTiming.swift        GIF/APNG/WebP 时长解析与 WebP 修复
    FFmpegRunner.swift           进程、取消、进度、原子提交
Tests/
  MediaForgeCoreTests/           XCTest（需要完整 Xcode）
  MediaForgeChecks/              无 XCTest 的可执行回归
scripts/
  build-engine.py, package-engine-source.py   源码构建与对应源码打包
  verify-helpers.py, build-app.sh             引擎审计与应用打包
  make-icon.swift                            应用图标
ThirdParty/                      来源、许可、构建记录（LegacyPrebuilt 仅工作区保留）
```

引擎用 `Process.executableURL` 与参数数组启动，不拼接 shell 命令；标准输出与错误并发读取并有界保留；成功结果用 `renamex_np(RENAME_EXCL)` 原子提交，转换期间他人创建同名文件也不会被覆盖。
