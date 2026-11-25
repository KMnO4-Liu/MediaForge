# 验证记录 · MediaForge 0.2.0

日期：2026-11-24。

## 环境

- macOS 15.8，Apple Silicon（arm64）。
- Apple Swift 6.1.2 / clang 17，使用 Command Line Tools（设置进程级 `DEVELOPER_DIR`，未修改系统 Xcode 选择或许可状态）。
- 引擎：由本项目从固定源码构建的 FFmpeg 9.0 + ffprobe 9.0，静态链接，`--enable-gpl --enable-version3`，部署目标 macOS 14.0。

## 引擎构建与审计

- `scripts/build-engine.py --jobs 2`：从固定源码构建 pkgconf、x264、x265、libvpx、libwebp、libogg、libvorbis、Opus、LAME、libaom 与 FFmpeg。中途两次失败均为可诊断的构建/链接问题（vpx target 误判、iconv 未链接），修正构建参数后续跑成功，未修改上游源码。
- 产出的两个可执行文件均为 arm64，`otool -L` 仅含 Apple `/System/Library` 与 `/usr/lib` 依赖，无 Homebrew / `@rpath`。
- `scripts/package-engine-source.py`：生成对应源码归档 `MediaForge-engine-source-9.0.tar.gz`（41,785,973 字节，SHA-256 `1b4d15c7935089f2890881e2caccaeda67898449c842a5463112470a827be10d`），含 46 个许可/通知文件、全部固定源码归档、构建脚本与日志。
- `scripts/verify-helpers.py`：打包前后两次审计通过（哈希、架构、链接、必需编码器、源码归档与构建记录一致）。
- `scripts/build-app.sh`：应用包构建成功，按 helper → 主程序顺序签名，`codesign --verify --deep --strict` 通过（ad-hoc 签名，非 Developer ID）。

## 转换回归（真实媒体，内置引擎）

```bash
MEDIAFORGE_FFMPEG="$PWD/.tools/source-build/prefix/bin/ffmpeg" \
MEDIAFORGE_FFPROBE="$PWD/.tools/source-build/prefix/bin/ffprobe" \
swift run MediaForgeChecks
```

**exit 0，48 组 PASS**，覆盖：

- 参数拒绝、Codable、ABR 与 CRF 互斥、帧率 nil 时保留源 PTS。
- 20 种格式 × 3 档质量的参数与声明编码器、动画策略、扩展名识别。
- 工具发现、符号链接、进度（含 ffprobe 实际中间值 `[0.0, 0.8625, 0.991625, 1.0]`）、未知时长降级。
- 原子不覆盖、并发同名竞争、双管道排空、64 KiB 错误日志、失败清理。
- 顽固进程取消 <3 秒、25 次启动前 Task 取消、busy 拒绝、runner 复用、超时降级。
- **20 种格式的真实转换 + 解码验证**（视频、音频、图片各含动画容器与 AVIF）。
- 真实 H.264 / HEVC / VP9 / AV1 / ProRes 输出并用 ffprobe 校验实际 codec；ALAC 与 WAV/AIFF 16/24/32-bit；Opus/AAC 显式 64/192 kbps 且输出体积响应。
- 实测等比缩小、不放大、仅视频补偶数边。
- 动画：APNG/GIF/WebP 互转，均 3 帧、100/200/300ms 不等间隔时序误差 ≤10ms；实际 alpha 像素；forever/once 元数据；有限循环输入；静态 WebP 输入；`.png` 扩展名的真 APNG。
- 真实失败清理与运行中编码取消。

## 应用自检（已打包）

```bash
dist/MediaForge.app/Contents/MacOS/MediaForge --self-check
```

**exit 0，PASS**：确认使用 `Contents/Helpers` 内置引擎与 ffprobe、20 种默认格式编码器齐全、旧版外部路径设置被迁移忽略、新装应用无需任何配置即可开始、混合容器参数规范化、快捷预设、重复导入去重、`.png` 命名的 APNG 保护、损坏文件失败不中断队列、3 个混合媒体真实转换并解码、源文件未被修改、重名自动编号、已有结果未被覆盖、每任务参数快照、动画损失确认、临时文件清理。

## 已知未覆盖 / 不保证

- **标准 XCTest 未执行**：仓库含 XCTest 源码，但当前 Command Line Tools 缺少 `XCTest` 模块；上述回归由独立可执行程序完成，不是 XCTest 结果。
- **未做 GUI 自动化验收**：应用已构建并启动、进程存在，但拖放、文件选择器、窗口关闭确认、键盘焦点与 VoiceOver 仍需人工验收；本环境无屏幕录制权限，未取得可核验截图。
- 测试使用合成短媒体，不代表真实素材库、超长视频、HDR、多音轨、损坏文件全部变体。
- 未测试 Intel、其他 macOS 版本、网络磁盘、沙盒、跨设备 Gatekeeper、Developer ID 签名或公证。
- 引擎为 arm64 单架构；x265 为 8-bit 构建；未启用硬件编码。
- 许可：对应源码归档已随交付生成；公开分发仍需按 GPL 履行随附源码义务并自行评估专利与 EULA，详见 [ThirdParty/NOTICE.md](ThirdParty/NOTICE.md)。
