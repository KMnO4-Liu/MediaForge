import SwiftUI
import MediaForgeCore

struct TrackWorkspaceView: View {
    @EnvironmentObject private var store: AppStore
    let tool: TrackTool

    private var selection: TrackSelection { store.trackSelection(for: tool) }

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            inputs
            settings
        }
    }

    private var inputs: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 13) {
                Text(tool == .separate ? "源视频" : "合并素材").font(.system(size: 14, weight: .semibold))
                inputRow(.video, url: selection.video)
                if tool == .merge {
                    inputRow(.audio, url: selection.audio)
                    if let video = selection.video {
                        MergeTimelineView(video: video, audio: selection.audio)
                    }
                }
                if store.activeTrackTool == tool {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text(store.stopping ? "正在停止…" : "正在处理素材…")
                    }
                    .font(.system(size: 12))
                    .padding(.vertical, 8)
                }
                if let output = selection.output {
                    resultPanel(output)
                }
            }
            .padding(1)
        }
        .scrollIndicators(.hidden)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 20) {
            Label("输出设置", systemImage: "slider.horizontal.3").font(.system(size: 14, weight: .semibold))
            if tool == .merge {
                mergeOutputSettings
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("输出格式").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    Text("MP4（画面） · M4A（音频）").font(.system(size: 12))
                    Text("两个文件保存在同一个结果文件夹。")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            OutputDestinationView()
            if !store.checkingTools && store.toolchain == nil {
                Button("配置转换引擎") { store.showSettings = true }
                    .buttonStyle(.borderless).tint(.orange)
            }
        }
        .padding(20)
        .frame(width: 306, alignment: .leading)
        .background(panel, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(rule))
    }

    private var mergeOutputSettings: some View {
        let merge = selection.merge
        return VStack(alignment: .leading, spacing: 9) {
            Text("视频格式").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            Picker("视频格式", selection: Binding(get: { selection.merge.format }, set: store.setMergeFormat)) {
                ForEach(store.formats(for: .video), id: \.self) { Text($0.displayName).tag($0) }
            }
            .labelsHidden().controlSize(.large)
            Text(store.settingsDescription(format: merge.format, options: merge.options))
                .font(.system(size: 11)).foregroundStyle(.secondary)
            Button(action: store.editMergeParameters) {
                Label("参数设置", systemImage: "slider.horizontal.3")
            }
            .buttonStyle(.bordered)
        }
        .disabled(store.isRunning)
    }

    private func inputRow(_ kind: MediaKind, url: URL?) -> some View {
        HStack(spacing: 13) {
            Label(kind.title, systemImage: kind.symbol)
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(accent)
                .frame(width: 70, alignment: .leading)
            VStack(alignment: .leading, spacing: 5) {
                if let url {
                    Text(url.lastPathComponent).font(.system(size: 12, weight: .medium))
                        .lineLimit(1).truncationMode(.middle).help(url.path)
                } else {
                    Text("拖入\(kind.title)文件或点击选择").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            Button(url == nil ? "选择\(kind.title)" : "更换\(kind.title)") {
                store.chooseTrackInput(kind, for: tool)
            }
            .buttonStyle(.bordered)
            if url != nil {
                Button {
                    store.removeTrackInput(kind, for: tool)
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .accessibilityLabel("移除\(kind.title)")
            }
        }
        .padding(16)
        .background(panel, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(rule))
        .disabled(store.isRunning)
    }

    private func resultPanel(_ output: URL) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("处理完成", systemImage: "checkmark.circle.fill")
                .font(.system(size: 13, weight: .semibold)).foregroundStyle(accent)
            if tool == .separate {
                resultFile(output.appendingPathComponent("video.mp4"), title: "无声视频", symbol: "film")
                resultFile(output.appendingPathComponent("audio.m4a"), title: "独立音频", symbol: "waveform")
            } else {
                resultFile(output, title: "合并视频", symbol: "film")
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(panel, in: RoundedRectangle(cornerRadius: 12))
    }

    private func resultFile(_ url: URL, title: String, symbol: String) -> some View {
        HStack(spacing: 10) {
            Label(title, systemImage: symbol).font(.system(size: 12))
            Text(url.lastPathComponent).font(.system(size: 11)).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle).help(url.path)
            Spacer(minLength: 8)
            Button("在 Finder 中显示") { store.reveal(url) }
                .buttonStyle(.borderless).font(.system(size: 11))
        }
    }
}
