import SwiftUI
import MediaForgeCore

struct WorkspaceCatalogView: View {
    @EnvironmentObject private var store: AppStore
    let kind: MediaKind?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if let kind {
                    toolGrid(categoryTools(kind))
                } else {
                    toolGrid(MediaKind.allCases.map { media in
                        ToolCard("\(media.title)处理", description: categoryDescription(media), symbol: media.symbol,
                                 destination: .category(media))
                    })
                    VStack(alignment: .leading, spacing: 12) {
                        Text("音视频工具").font(.system(size: 16, weight: .semibold))
                        toolGrid([utilityCard(.extractAudio), trackCard(.separate), trackCard(.merge)])
                    }
                }
            }
            .padding(2)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .scrollIndicators(.hidden)
    }

    private func toolGrid(_ tools: [ToolCard]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 245), spacing: 15, alignment: .top)], spacing: 15) {
            ForEach(tools) { tool in
                Button {
                    store.workspace = tool.destination
                } label: {
                    VStack(alignment: .leading, spacing: 13) {
                        HStack {
                            Image(systemName: tool.symbol)
                                .font(.system(size: 18, weight: .semibold))
                                .frame(width: 42, height: 42)
                                .foregroundStyle(accent)
                                .background(accent.opacity(0.11), in: RoundedRectangle(cornerRadius: 12))
                            Spacer(minLength: 0)
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 11, weight: .semibold)).foregroundStyle(.tertiary)
                        }
                        VStack(alignment: .leading, spacing: 5) {
                            Text(tool.title).font(.system(size: 15, weight: .semibold))
                            Text(tool.description).font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                    }
                    .padding(18)
                    .frame(maxWidth: .infinity, minHeight: 128, alignment: .topLeading)
                    .background(panel, in: RoundedRectangle(cornerRadius: 15))
                    .overlay(RoundedRectangle(cornerRadius: 15).stroke(rule))
                    .contentShape(RoundedRectangle(cornerRadius: 15))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tool.title)
                .accessibilityHint(tool.description)
            }
        }
    }

    private func categoryTools(_ kind: MediaKind) -> [ToolCard] {
        let conversion = ToolCard("\(kind.title)格式转换", description: "批量选择文件和输出格式。", symbol: "arrow.left.arrow.right",
                                  destination: .conversion(kind))
        switch kind {
        case .video: return [conversion, utilityCard(.compressVideo), utilityCard(.extractAudio), trackCard(.separate), trackCard(.merge)]
        case .audio: return [conversion, utilityCard(.extractAudio), trackCard(.separate), trackCard(.merge)]
        case .image: return [conversion, utilityCard(.compressImage)]
        }
    }

    private func categoryDescription(_ kind: MediaKind) -> String {
        switch kind {
        case .video: return "格式转换、压缩和音轨处理。"
        case .audio: return "格式转换和视频音轨提取。"
        case .image: return "格式转换、压缩和动图处理。"
        }
    }

    private func utilityCard(_ tool: UtilityTool) -> ToolCard {
        ToolCard(tool.title, description: tool.detail, symbol: tool.symbol, destination: .utility(tool))
    }

    private func trackCard(_ tool: TrackTool) -> ToolCard {
        let detail = tool == .separate ? "分别导出无声视频和独立音轨。" : "为视频替换一条外部音轨。"
        return ToolCard(tool.title, description: detail, symbol: tool.symbol, destination: .tracks(tool))
    }
}

private struct ToolCard: Identifiable {
    var id: String { title }
    let title: String
    let description: String
    let symbol: String
    let destination: Workspace

    init(_ title: String, description: String, symbol: String, destination: Workspace) {
        self.title = title
        self.description = description
        self.symbol = symbol
        self.destination = destination
    }
}
