import SwiftUI
import MediaForgeCore

struct UtilityInspectorView: View {
    @EnvironmentObject private var store: AppStore
    let tool: UtilityTool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 19) {
                Label("输出设置", systemImage: "slider.horizontal.3").font(.system(size: 14, weight: .semibold))
                formatPicker
                if tool == .extractAudio {
                    Text("目标格式兼容时直接保留源音轨编码。")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                } else {
                    compressionPicker
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

    private var formatPicker: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("默认输出格式").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            Picker("默认输出格式", selection: Binding(
                get: { store.utilitySettings(for: tool).format },
                set: { store.setUtilityFormat($0, for: tool) }
            )) {
                ForEach(tool.outputFormats, id: \.self) { format in
                    let unavailable = store.toolchain != nil && !store.supports(format, utility: tool)
                    Text(format.displayName + (unavailable ? " · 不可用" : ""))
                        .tag(format).disabled(unavailable)
                }
            }
            .labelsHidden().controlSize(.large)
        }
        .disabled(store.isRunning)
    }

    private var compressionPicker: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("压缩质量").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            Picker("压缩质量", selection: Binding(
                get: { store.utilitySettings(for: tool).quality },
                set: { store.setUtilityQuality($0, for: tool) }
            )) {
                ForEach(ConversionQuality.allCases, id: \.self) { quality in
                    Text(quality.title).tag(quality)
                }
            }
            .pickerStyle(.segmented).labelsHidden()
            Text("保留源尺寸。输出体积取决于源文件和所选格式。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .disabled(store.isRunning)
    }
}
