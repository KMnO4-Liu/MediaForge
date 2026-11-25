# MediaForge 0.2.0 — 内置引擎说明（第三方软件声明）

本应用把 **FFmpeg 9.0 与 ffprobe 9.0** 直接内置在 `MediaForge.app/Contents/Helpers/`，无需用户安装 Homebrew、修改 PATH 或另行配置。两个可执行文件由本项目**从固定源码在本机构建**，不是从第三方网站下载的预编译包。

本页是许可与来源说明，不是法律意见，也不构成对任何具体发行方式的合规认证。商业使用本身不被 GPL 禁止；分发时必须履行相应义务（见下文）。

## 版本与许可

| 程序 | 构建 | 许可 |
|---|---|---|
| ffmpeg | 9.0, macOS arm64，静态链接，`--enable-gpl --enable-version3` | GPL-3.0-or-later |
| ffprobe | 9.0, 同一源码树、同一构建 | GPL-3.0-or-later |

FFmpeg/ffprobe 版权归 FFmpeg 开发者（ffmpeg: 2000–2026；ffprobe: 2007–2026）及众多贡献者所有，按“不提供任何担保”的方式分发。部分代码基于 Independent JPEG Group 的工作。MediaForge 未修改上游源码；打包时仅复制本机构建产物并为 macOS 本地执行重新签名。重新签名会改变文件哈希，构建记录中的哈希识别的是**签名前**的构建产物。

## 静态链接的第三方库

以下库被静态链接进两个可执行文件，均使用版本固定的官方源码构建：

- x264（固定 commit `b35605ace3ddf7c1a5d67a2eb553f034aef41d55`，GPL）、x265 4.1（GPL）
- libvpx 1.15.2（BSD）、libwebp 1.6（BSD）、libaom 3.12.1（固定 commit `10aece4157eb79315da205f39e19bf6ab3ee30d0`，BSD + 专利条款）
- Opus 1.5.2（BSD）、LAME 3.100（LGPL）、libogg 1.3.6（BSD）、libvorbis 1.3.7（BSD）

没有启用 libvmaf、libass、OpenSSL、`--enable-nonfree` 或任何未列出的外部编解码库；ProRes、PNG/APNG、GIF、FLAC、AAC、PCM 由 FFmpeg 原生实现。构建只链接 Apple 系统库（`/System/Library`、`/usr/lib`），`otool -L` 中不存在 Homebrew、`@rpath` 或其它第三方 dylib。MediaForge 使用 LAME；其项目主页为 <https://lame.sourceforge.io/>（历史归属页 <https://www.mp3dev.org/>）。

完整许可文本、每个组件的版权/专利通知及索引见 `EngineSource/licenses/` 与 `EngineSource/license-index.json`；GPLv2、GPLv3 全文见 `FFmpeg/`。

## 对应源码（Corresponding Source）

完整的对应源码与可审计构建配方打包为：

- **`MediaForge-engine-source-9.0.tar.gz`**
- SHA-256：`1b4d15c7935089f2890881e2caccaeda67898449c842a5463112470a827be10d`
- 记录：`EngineSource/source-archive.json`、`EngineSource/SOURCE-DELIVERY.md`

该归档包含 FFmpeg 9.0 及上述每个静态链接库的**原始未修改源码归档**、全部构建脚本（`build-engine.py`、`package-engine-source.py`、`verify-helpers.py`）、固定输入清单（URL 与 SHA-256）、构建命令/环境记录、生成的配置与链接审计、完整构建日志及许可通知。归档内 `ThirdParty/EngineSource/README.md` 给出从归档重建两个可执行文件的步骤。

**分发义务：** 若向他人提供本应用，必须让该归档以等效、可访问的方式随应用一并提供，并保留其许可与通知。不得只分发二进制而扣留此归档。公开分发者还需自行评估其实际交付方式下的 GPL 安装信息要求、应用与辅助程序的关系、EULA 兼容性、各地编解码专利以及签名/公证。提供真实对应源码解决了此前“只有预编译二进制、无对应源码”的具体缺口，但**不是**法律或专利的全面豁免。

可复现指输入与步骤固定可审计，不保证跨 SDK/编译器版本或不同主机路径得到字节完全相同的输出。

## 构建环境与限制

- 构建机：macOS 15.8、Apple Silicon（arm64）、Apple Command Line Tools clang 17，部署目标 macOS 14.0。
- x264/x265 外部汇编路径被禁用；x265 为 8-bit 构建；系统 VideoToolbox/AudioToolbox 仍可用。
- 支持 Intel Mac？**否**。当前只有 arm64 产物。
- 未做 Apple Developer ID 签名或公证，跨设备打开可能触发 Gatekeeper 提示。
- 支持通过 VideoToolbox 硬件解码和进行 H.264、HEVC、ProRes 硬件编码，运行时根据设备和编码设置选择。

## 归档内容索引

- `EngineSource/README.md`：来源、重建步骤与许可义务
- `EngineSource/source-manifest.json`：每个输入的确切 URL、SHA-256、版本/commit
- `EngineSource/engine-manifest.json`：两个二进制的构建哈希、系统依赖列表
- `EngineSource/ffmpeg-version.txt` / `ffprobe-version.txt`：完整构建配置
- `EngineSource/ffmpeg-linkage.txt` / `ffprobe-linkage.txt`：dylib 审计
- `EngineSource/ffmpeg-encoders.txt` / `ffmpeg-decoders.txt`：本次构建包含的编解码器
- `EngineSource/build-commands.json`、`build-configurations/`、`build-environment.json`：构建证据
- `EngineSource/license-index.json`、`licenses/`：许可全文索引
- `FFmpeg/COPYING.GPLv2`、`FFmpeg/COPYING.GPLv3`、`FFmpeg/FFmpeg-LICENSE.md`：GPL 全文与上游许可概览
- `bundled-engine-audit.json`（打包时生成）：实际随包复制后的哈希/架构/链接审计
