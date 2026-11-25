import SwiftUI
import MediaForgeCore

struct InspectorView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Label("转换设置", systemImage: "slider.horizontal.3").font(.system(size: 14, weight: .semibold))
                presetSection
                formatSection
                if let kind = store.filter {
                    Button {
                        store.editDefaultParameters(for: store.defaultFormat(for: kind))
                    } label: {
                        Label("参数设置", systemImage: "slider.horizontal.3")
                    }
                    .buttonStyle(.bordered)
                    .disabled(store.isRunning)
                }
                OutputDestinationView()
                if let job = store.selectedJob { JobDetailsView(job: job) }
            }
            .padding(20)
        }
        .scrollIndicators(.hidden)
        .background(panel, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(rule))
    }

    private var presetSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            caption("快捷预设")
            presetButton(.source)
            HStack(spacing: 6) {
                ForEach([QuickPreset.balanced, .small, .highQuality], id: \.self) { preset in
                    presetButton(preset)
                }
            }
            Text(store.selectedPreset.detail)
                .font(.system(size: 10)).foregroundStyle(.secondary).lineSpacing(4)
        }
        .disabled(store.isRunning)
    }

    private func presetButton(_ preset: QuickPreset) -> some View {
        let selected = store.selectedPreset == preset
        return Button { store.applyPreset(preset) } label: {
            Text(preset.title).font(.system(size: 11, weight: .medium))
                .frame(maxWidth: .infinity).padding(.vertical, 10)
                .background(selected ? accent.opacity(0.12) : canvas, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(selected ? accent.opacity(0.5) : rule))
                .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var formatSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            caption("默认输出格式")
            if let kind = store.filter {
                VStack(alignment: .leading, spacing: 6) {
                    Label(kind.title, systemImage: kind.symbol)
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    Picker("\(kind.title)默认输出格式", selection: Binding(get: { store.defaultFormat(for: kind) }, set: { store.setDefault($0, for: kind) })) {
                        ForEach(store.formats(for: kind), id: \.self) { format in
                            Text(format.displayName + (store.toolchain != nil && !store.supports(format) ? " · 不可用" : ""))
                                .tag(format).disabled(store.toolchain != nil && !store.supports(format))
                        }
                    }.labelsHidden().controlSize(.large)
                }
            }
            if store.filter == .image {
                Text("新导入的 GIF / WebP / APNG 默认保留原容器，避免丢失动画。")
                    .font(.system(size: 10)).foregroundStyle(.tertiary).lineSpacing(4)
            }
        }.disabled(store.isRunning)
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
    }
}

struct JobDetailsView: View {
    @EnvironmentObject private var store: AppStore
    let job: ConversionJob

    var body: some View {
        let parameters = store.encoding(for: job)
        let options = parameters.options
        let preferredVideoCodec = job.parameters?.options.videoCodec ?? store.options.videoCodec
        Divider()
        VStack(alignment: .leading, spacing: 10) {
            Text("所选任务 · 实际输出设置").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            Text(job.input.lastPathComponent).font(.system(size: 11, weight: .medium)).textSelection(.enabled)
            Text(job.status == .waiting ? store.settingsDescription(format: job.format, options: options, matchSource: parameters.matchSource) : (job.settingsSummary ?? job.status.title))
                .font(.system(size: 10)).foregroundStyle(.secondary).lineSpacing(4).textSelection(.enabled)
            if job.status == .waiting, let message = store.animationMessage(for: job) {
                Label(message, systemImage: job.format.supportsAnimation && options.animationMode == .preserve ? "sparkles.tv" : "exclamationmark.triangle")
                    .font(.system(size: 10)).foregroundStyle(job.format.supportsAnimation && options.animationMode == .preserve ? accent : .orange)
                    .lineSpacing(4)
            }
            if job.kind == .video && job.format.kind == .audio {
                Label("只提取第一条音轨，不保留视频画面。", systemImage: "waveform")
                    .font(.system(size: 10)).foregroundStyle(accent)
            }
            if job.utility == nil, job.format.kind == .video, preferredVideoCodec != .automatic,
               !job.format.allowedVideoCodecs.contains(preferredVideoCodec), job.status == .waiting {
                Text("此容器不支持所选偏好编码器，已使用容器推荐编码器。")
                    .font(.system(size: 10)).foregroundStyle(.orange)
            }
            if let error = job.error {
                Text("失败原因").font(.system(size: 11, weight: .semibold)).foregroundStyle(.red)
                Text(error).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                Button("复制错误") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(error, forType: .string)
                }.controlSize(.small)
            }
        }
    }
}

struct OutputDestinationView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("保存到").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            Button(action: store.chooseOutputDirectory) {
                HStack(spacing: 9) {
                    Image(systemName: "folder").foregroundStyle(accent)
                    Text(store.outputLocationLabel).font(.system(size: 11)).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(.secondary)
                }
                .padding(12).background(canvas, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(rule))
            }
            .buttonStyle(.plain).help(store.outputDirectory?.path ?? "自动在每个源文件所在目录创建 MediaForge 输出 文件夹")
            if store.outputDirectory != nil {
                Button("恢复自动保存到源文件旁", action: store.useSourceDirectory)
                    .buttonStyle(.borderless).font(.system(size: 10))
            }
            Text("不覆盖原文件；已有同名结果自动编号。")
                .font(.system(size: 10)).foregroundStyle(.tertiary)
        }.disabled(store.isRunning)
    }
}
