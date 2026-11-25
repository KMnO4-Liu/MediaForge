import SwiftUI
import MediaForgeCore

struct ToolSettingsView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var showCustomEngine = false

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack {
                Image(systemName: "gearshape").font(.system(size: 24)).foregroundStyle(accent)
                VStack(alignment: .leading, spacing: 4) {
                    Text("设置").font(.title2.bold())
                    Text("MediaForge 0.2 · 全程本地转换").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            GroupBox("外观") {
                Picker("界面模式", selection: $store.appearance) {
                    ForEach(AppAppearance.allCases, id: \.self) { appearance in
                        Text(appearance.title).tag(appearance)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: .infinity)
                .padding(10)
            }
            Text("应用已内置 FFmpeg 和 ffprobe，无需安装 Homebrew、下载插件或配置终端。文件始终留在本机，转换不需要网络。")
                .font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(5)
            GroupBox("转换引擎") {
                VStack(alignment: .leading, spacing: 12) {
                    Label(store.engineLabel, systemImage: store.toolchain == nil ? "exclamationmark.circle" : "checkmark.circle.fill")
                        .foregroundStyle(store.toolchain == nil ? .orange : accent)
                    if let chain = store.toolchain {
                        Text(chain.ffmpeg.path).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                        Text("默认可用格式：\(OutputFormat.allCases.filter { $0.requiredEncoders(options: ConversionOptions()).isSubset(of: store.encoders) }.count) / \(OutputFormat.allCases.count)")
                            .font(.system(size: 12, weight: .medium))
                        Text("视频编码：" + VideoCodec.allCases.filter { $0 != .automatic && store.encoders.contains($0.encoder) }.map(\.displayName).joined(separator: "、"))
                            .font(.system(size: 11)).foregroundStyle(.secondary).lineSpacing(4)
                        if chain.ffprobe == nil {
                            Label("当前外部引擎缺少 ffprobe，部分文件仅显示不定进度。", systemImage: "info.circle")
                                .font(.system(size: 11)).foregroundStyle(.orange)
                        }
                    }
                    Toggle("使用 VideoToolbox 硬件加速", isOn: $store.hardwareAccelerationEnabled)
                        .disabled(store.isRunning)
                    let hardware = store.hardwareVideoCodecs.map(\.displayName).joined(separator: "、")
                    Text(hardware.isEmpty ? "当前引擎未提供 VideoToolbox 视频编码器。"
                         : "当前引擎支持硬件编码：\(hardware)。CRF 使用软件编码。")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    if let error = store.toolError {
                        ScrollView { Text(error).font(.system(size: 11)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                            .frame(maxHeight: 90)
                    }
                    HStack {
                        Button("恢复内置引擎", action: store.resetToolPath)
                        Button("重新检测", action: store.checkTools)
                    }.disabled(store.isRunning || store.checkingTools)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(10)
            }
            DisclosureGroup("高级：使用其他 FFmpeg", isExpanded: $showCustomEngine) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("一般不需要更换。外部版本可能缺少编码器或动画支持；仅选择你信任的可执行文件，ffprobe 应放在同一目录。")
                        .font(.system(size: 11)).foregroundStyle(.secondary).lineSpacing(4)
                    Button("选择外部 FFmpeg…", action: store.chooseFFmpeg)
                        .disabled(store.isRunning || store.checkingTools)
                }.padding(.top, 10)
            }.font(.system(size: 12))
            Divider()
            HStack {
                Button("开源许可与引擎来源", action: store.openLicenses)
                Spacer()
                Link("FFmpeg 项目 ↗", destination: URL(string: "https://ffmpeg.org")!)
            }.font(.system(size: 11))
            Text("格式兼容性也取决于源编码及文件完整性。不支持 DRM 解密、专有 RAW 导入或专业 HDR 色彩保真。此开发版本尚未经过 Apple 公证。")
                .font(.system(size: 10)).foregroundStyle(.tertiary).lineSpacing(4)
        }
        .padding(28).frame(width: 590)
        .background(canvas)
    }
}
