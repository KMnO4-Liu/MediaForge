import SwiftUI

struct TaskCenterView: View {
    @EnvironmentObject private var store: AppStore
    let filter: TaskFilter

    var body: some View {
        let entries = store.tasks(in: filter)
        if entries.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: filter.symbol)
                    .font(.system(size: 28, weight: .medium)).foregroundStyle(accent)
                Text(emptyMessage)
                    .font(.system(size: 16, weight: .semibold))
                if filter == .all {
                    Button("浏览工具") { store.workspace = .home }.buttonStyle(.bordered)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(panel, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(rule))
        } else {
            ScrollView {
                LazyVStack(spacing: 9) {
                    ForEach(entries) { entry in
                        switch entry {
                        case .conversion(let job):
                            taskRow(entry, title: job.input.lastPathComponent,
                                    detail: [job.utility?.title ?? "\(job.kind.title)转换", job.format.displayName, job.processingPath?.title]
                                        .compactMap { $0 }.joined(separator: " · "),
                                    symbol: job.kind.symbol, output: job.output, error: job.error, progress: job.progress)
                        case .tracks(let run):
                            taskRow(entry, title: run.video.lastPathComponent,
                                    detail: [run.tool.title, run.processingPath?.title].compactMap { $0 }.joined(separator: " · "),
                                    symbol: run.tool.symbol, output: run.output, error: run.error, progress: nil)
                        }
                    }
                }
                .padding(1)
            }
        }
    }

    private var emptyMessage: String {
        switch filter {
        case .all: return "暂无任务"
        case .failed: return "暂无失败任务"
        case .completed: return "暂无已完成任务"
        }
    }

    private func taskRow(_ entry: TaskEntry, title: String, detail: String, symbol: String, output: URL?, error: String?, progress: Double?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .medium))
                    .frame(width: 38, height: 38)
                    .foregroundStyle(accent)
                    .background(accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 11))
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                    Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Text(entry.status.title).font(.system(size: 11, weight: .medium)).foregroundStyle(entry.status.tint)
                if let output {
                    Button("在 Finder 中显示") { store.reveal(output) }.buttonStyle(.bordered)
                } else if entry.status == .failed || entry.status == .cancelled {
                    Button("重新处理") { store.openTask(entry, retry: true) }.buttonStyle(.bordered)
                        .disabled(store.isRunning)
                } else if entry.status == .waiting {
                    Button("打开队列") { store.openTask(entry) }.buttonStyle(.bordered)
                }
            }
            if entry.status == .running {
                if let progress { ProgressView(value: progress).tint(accent) }
                else { ProgressView().controlSize(.small) }
            }
            if let error {
                DisclosureGroup("查看失败原因") {
                    Text(error).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 4)
                }
                .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .padding(13)
        .background(panel, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(rule))
    }
}

extension JobStatus {
    var tint: Color {
        switch self {
        case .completed, .running: return accent
        case .failed: return .red
        case .cancelled: return .orange
        case .waiting: return .secondary
        }
    }
}
