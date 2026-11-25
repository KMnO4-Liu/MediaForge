# 引擎来源与构建参考（Source-built engine）

日期：2026-11-24。本应用内置的 ffmpeg / ffprobe 9.0 由本项目从固定源码构建；完整对应源码归档与哈希见 [NOTICE.md](<NOTICE.md>) 与 [EngineSource/source-manifest.json](<EngineSource/source-manifest.json>)。早期从第三方预编译包取得的可执行文件仅保留在工作区 `LegacyPrebuilt/` 作回归对照，**不随应用分发、也不是默认打包输入**。

## 固定输入

每个输入的发布 URL、SHA-256、版本或 commit 记录在 [EngineSource/source-manifest.json](<EngineSource/source-manifest.json>)。概要：

| 组件 | 版本/固定点 | 角色 | 许可 |
|---|---|---|---|
| FFmpeg | 9.0 官方发行源码 | ffmpeg + ffprobe 主程序 | GPL-3.0-or-later（构建启用 `--enable-version3`） |
| x264 | commit `b35605ace3ddf7c1a5d67a2eb553f034aef41d55` | H.264 编码 | GPL |
| x265 | 4.1 | HEVC 编码 | GPL |
| libvpx | 1.15.2 | VP9 编解码 | BSD |
| libwebp | 1.6 | WebP 静态/动画 | BSD |
| libaom | 3.12.1, commit `10aece4157eb79315da205f39e19bf6ab3ee30d0` | AV1 编解码 | BSD + 专利条款 |
| Opus | 1.5.2 | Opus 编解码 | BSD |
| LAME | 3.100 | MP3 编码 | LGPL |
| libogg | 1.3.6 | Ogg 封装/依赖 | BSD |
| libvorbis | 1.3.7 | Vorbis 编解码 | BSD |
| pkgconf | 固定发行版 | 构建工具（不进入产物） | ISC 类 |
| CMake | 3.31.8 官方 macOS universal 包 | 构建工具（不进入产物，不入归档；仅记录固定 URL 与校验） | BSD-3-Clause |

未启用 libvmaf、libass、OpenSSL、`--enable-nonfree`，也未链接任何 Homebrew 或 `@rpath` 库。ProRes、PNG/APNG、GIF、FLAC、AAC、PCM 为 FFmpeg 原生实现；VideoToolbox/AudioToolbox 为 Apple 系统框架。

## 构建配方

- 获取与编译：`scripts/build-engine.py`（`--prepare` 只下载校验；`--through NAME` 阶段停止；构建标记支持中断续跑）
- 对应源码打包：`scripts/package-engine-source.py`
- 打包前审计：`scripts/verify-helpers.py`（哈希、arm64、仅系统库、必需编码器、源码归档哈希与二进制构建记录一致）

所有下载使用 HTTPS 和精确 SHA-256，并在解包前校验；配方不安装系统软件、不接受 Xcode 许可、不调用 brew/pip、不修改 PATH、不执行远程安装脚本。CMake FetchContent 被断开，可选远程 ML/测试依赖被禁用。

可复现性指输入与步骤固定可审计，不保证跨 SDK/编译器版本或主机路径得到字节完全一致的产物。

## 许可文本来源

- [GPLv2 全文](<FFmpeg/COPYING.GPLv2>)、[GPLv3 全文](<FFmpeg/COPYING.GPLv3>)（取自 FFmpeg 9.0 源码树，哈希见 `EngineSource/license-index.json`）
- [FFmpeg 上游许可概览](<FFmpeg/FFmpeg-LICENSE.md>)
- 各库完整版权/许可/专利通知：`EngineSource/licenses/`，索引 `EngineSource/license-index.json`

上游项目主页：FFmpeg <https://ffmpeg.org/>、x264 <https://www.videolan.org/developers/x264.html>、x265 <https://www.x265.org/>、libvpx/libwebp <https://www.webmproject.org/>、AOM <https://aomedia.googlesource.com/aom>、Opus <https://opus-codec.org/>、Vorbis <https://xiph.org/vorbis/>、LAME <https://lame.sourceforge.io/>。
