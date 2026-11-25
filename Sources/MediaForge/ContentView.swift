import AppKit
import SwiftUI
import MediaForgeCore

struct ContentView: View {
    private static let appIcon = Bundle.main.url(forResource: "AppIcon", withExtension: "icns")
        .flatMap { NSImage(contentsOf: $0) }
    @EnvironmentObject private var store: AppStore
    @State private var dropTargeted = false

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            VStack(spacing: 0) {
                header
                HStack(alignment: .top, spacing: 20) {
                    switch store.workspace {
                    case .home: WorkspaceCatalogView(kind: nil)
                    case .category(let kind): WorkspaceCatalogView(kind: kind)
                    case .conversion:
                        queue.frame(maxWidth: .infinity, maxHeight: .infinity)
                        InspectorView().frame(width: 306)
                    case .utility(let tool):
                        queue.frame(maxWidth: .infinity, maxHeight: .infinity)
                        UtilityInspectorView(tool: tool).frame(width: 306)
                    case .tracks(let tool):
                        TrackWorkspaceView(tool: tool)
                    case .tasks(let filter):
                        TaskCenterView(filter: filter)
                    }
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 22)
                if hasProcessingWorkspace || store.isRunning { footer }
            }
            .background(canvas)
        }
        .frame(minWidth: 950, minHeight: 680)
        .dropDestination(for: URL.self) { urls, _ in
            guard !store.isRunning, store.workspace.acceptsFiles else { return false }
            store.importDroppedFiles(urls)
            return true
        } isTargeted: { dropTargeted = $0 }
        .overlay {
            if dropTargeted && store.workspace.acceptsFiles && !store.isRunning {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(accent, style: StrokeStyle(lineWidth: 3, dash: [10]))
                    .padding(6)
                    .allowsHitTesting(false)
            }
        }
        .sheet(isPresented: $store.showSettings) { ToolSettingsView() }
        .sheet(item: $store.parameterEditor) { target in ParameterSheet(target: target) }
        .confirmationDialog("有 \(store.animationLossCount) 个视频或可能含动画的文件将只导出首帧", isPresented: $store.showAnimationLossWarning, titleVisibility: .visible) {
            Button("仅保留首帧并继续") { store.confirmFirstFrameConversion() }
            Button("返回调整格式", role: .cancel) {}
        } message: {
            Text("其余画面不会写入结果。若要保留动画，请使用 GIF / WebP / APNG 并选择“保留动画”。源文件不会修改。")
        }
        .alert("提示", isPresented: Binding(get: { store.notice != nil }, set: { if !$0 { store.notice = nil } })) {
            Button("知道了", role: .cancel) { store.notice = nil }
        } message: { Text(store.notice ?? "") }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 10) {
                Group {
                    if let icon = Self.appIcon {
                        Image(nsImage: icon).resizable().scaledToFit().frame(width: 47, height: 47)
                    } else {
                        Image(systemName: "arrow.left.arrow.right")
                            .font(.system(size: 19, weight: .bold))
                            .frame(width: 39, height: 39)
                            .foregroundStyle(.white)
                            .background(accent, in: RoundedRectangle(cornerRadius: 9))
                    }
                }
                .frame(width: 39, height: 39)
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text("MediaForge").font(.system(size: 17, weight: .semibold))
                    Text("本地媒体工具").font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 6).padding(.bottom, 22)

            navigationRow(title: "首页", symbol: "square.grid.2x2", workspace: .home)
            sidebarCaption("媒体工具")
            ForEach(MediaKind.allCases, id: \.self) { kind in
                navigationRow(title: "\(kind.title)处理", symbol: kind.symbol, workspace: .category(kind))
            }
            sidebarCaption("任务中心")
            ForEach(TaskFilter.allCases, id: \.self) { filter in
                navigationRow(title: filter.title, symbol: filter.symbol, workspace: .tasks(filter),
                              count: store.taskCount(in: filter))
            }
            Spacer()
            Button { store.showSettings = true } label: {
                HStack(spacing: 8) {
                    Circle().fill(store.toolchain != nil ? accent : Color.orange).frame(width: 6, height: 6)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(store.engineLabel)
                            .font(.system(size: 11, weight: .medium))
                        Text("设置").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "gearshape").foregroundStyle(.secondary)
                }
                .padding(12)
                .background(.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("设置")
        }
        .padding(.horizontal, 16)
        .padding(.top, 45)
        .padding(.bottom, 16)
        .frame(width: 204)
        .background { SidebarMaterial().allowsHitTesting(false) }
        .overlay(alignment: .trailing) { Divider() }
    }

    private func sidebarCaption(_ text: String) -> some View {
        Text(text).font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.leading, 12).padding(.top, 15).padding(.bottom, 4)
    }

    private func navigationRow(title: String, symbol: String, workspace: Workspace, count: Int? = nil) -> some View {
        let selected = activeNavigation == workspace
        return Button { store.workspace = workspace } label: {
            HStack(spacing: 11) {
                Image(systemName: symbol).frame(width: 19)
                Text(title).font(.system(size: 12, weight: selected ? .semibold : .regular))
                Spacer()
                if let count {
                    Text("\(count)").font(.system(size: 10, weight: .medium, design: .monospaced))
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background((selected ? accent : Color.primary).opacity(0.09), in: Capsule())
                }
            }
            .foregroundStyle(selected ? accent : Color.primary)
            .padding(.horizontal, 12).frame(height: 36)
            .background(selected ? accent.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(count.map { "\(title)，\($0) 项" } ?? title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var activeNavigation: Workspace {
        parentCategory.map(Workspace.category) ?? store.workspace
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 8) {
                if let parent = parentCategory {
                    Button {
                        store.workspace = .category(parent)
                    } label: {
                        Label("\(parent.title)处理", systemImage: "chevron.left").font(.system(size: 11, weight: .medium))
                    }
                    .buttonStyle(.plain).foregroundStyle(accent)
                }
                Text(workspaceTitle).font(.system(size: 30, weight: .semibold))
                Text(workspaceDescription)
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            if store.workspace.acceptsFiles {
                Button(action: store.importFiles) { Label(importTitle, systemImage: "plus").padding(.vertical, 5) }
                    .buttonStyle(.borderedProminent).tint(accent)
                    .disabled(store.isRunning)
            }
        }
        .padding(.horizontal, 28).padding(.top, 43).padding(.bottom, 22)
    }

    private var workspaceTitle: String {
        switch store.workspace {
        case .home: return "媒体工作台"
        case .category(let kind): return "\(kind.title)处理"
        case .conversion(let kind): return "\(kind.title)格式转换"
        case .utility(let tool): return tool.title
        case .tracks(let tool): return tool.title
        case .tasks(let filter): return filter.title
        }
    }

    private var workspaceDescription: String {
        switch store.workspace {
        case .home: return "选择工具开始，或将媒体文件拖入窗口。所有处理都在本机完成。"
        case .category: return "选择要使用的工具。"
        case .conversion: return "添加文件后，为单个文件或整个队列选择目标格式。"
        case .utility(let tool): return tool.detail
        case .tracks(.separate): return "从一个视频分别导出画面和第一条音轨"
        case .tracks(.merge): return "使用所选音频替换原视频音轨"
        case .tasks: return "查看本次运行的任务、结果和失败原因。"
        }
    }

    private var importTitle: String {
        switch store.workspace {
        case .tracks(.separate): return "选择视频"
        case .tracks(.merge): return "添加素材"
        default: return "添加文件"
        }
    }

    private var parentCategory: MediaKind? {
        switch store.workspace {
        case .conversion(let kind): return kind
        case .utility(let tool): return tool == .extractAudio ? store.toolCategory : tool.inputKind
        case .tracks: return store.toolCategory
        default: return nil
        }
    }

    private var hasProcessingWorkspace: Bool {
        switch store.workspace {
        case .conversion, .utility, .tracks: return true
        default: return false
        }
    }

    private var queue: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !store.checkingTools && store.toolchain == nil {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("转换引擎未能启动").font(.system(size: 12, weight: .semibold))
                        Text("应用已内置引擎。请在设置中恢复内置引擎；若文件缺失，请重新解压完整应用。")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Button("设置") { store.showSettings = true }.buttonStyle(.borderless).tint(.orange)
                }
                .padding(14).background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
            }
            HStack {
                Text("处理队列").font(.system(size: 14, weight: .semibold))
                Text("\(store.visibleJobs.count)").font(.system(size: 10, design: .monospaced))
                    .padding(.horizontal, 7).padding(.vertical, 3).background(accent.opacity(0.09), in: Capsule())
                Spacer()
                Button("移出已完成任务", action: store.clearFinished)
                    .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary)
                    .disabled(store.isRunning || store.completedCount == 0)
            }
            if store.visibleJobs.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 9) {
                        ForEach(store.visibleJobs) { job in
                            JobRow(job: job, selected: store.selectedJobID == job.id)
                                .onTapGesture { store.selectedJobID = job.id }
                        }
                    }
                    .padding(1)
                }
                .scrollIndicators(.hidden)
                HStack(spacing: 7) {
                    Image(systemName: "plus.circle.dashed")
                    Text("继续拖入文件，或点击右上角添加")
                }
                .font(.system(size: 11)).foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity).padding(.vertical, 12)
            }
        }
    }

    private var emptyState: some View {
        let kind = inputKind
        return VStack(spacing: 13) {
            Spacer()
            Image(systemName: kind.symbol)
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(accent)
                .frame(width: 60, height: 60)
                .background(accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 16))
            Text("拖入\(kind.title)文件")
                .font(.system(size: 18, weight: .semibold))
            Button("浏览文件", action: store.importFiles)
                .buttonStyle(.bordered).controlSize(.large).disabled(store.isRunning)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(panel, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(rule, style: StrokeStyle(lineWidth: 1, dash: [5, 5])))
    }

    private var inputKind: MediaKind {
        if case .utility(let tool) = store.workspace { return tool.inputKind }
        return store.filter ?? .video
    }

    private var footer: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle().fill(accent.opacity(0.15)).frame(width: 34, height: 34)
                Image(systemName: store.isRunning ? "arrow.triangle.2.circlepath" : "checkmark.shield").foregroundStyle(accent)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(footerStatus)
                    .font(.system(size: 12, weight: .medium)).lineLimit(1)
                Text(store.outputDirectory == nil ? "自动保存到源文件旁的 MediaForge 输出 · 保留原文件" : "保留原始文件 · 同名结果自动编号")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if store.isRunning {
                Button(action: store.stop) { Label(store.stopping ? "正在停止" : "停止处理", systemImage: "stop.fill").frame(width: 110).padding(.vertical, 5) }
                    .buttonStyle(.bordered).disabled(store.stopping)
            } else {
                Button(action: store.start) { Label(startTitle, systemImage: "play.fill").frame(width: 110).padding(.vertical, 5) }
                    .buttonStyle(.borderedProminent).tint(accent).disabled(!canStart)
                    .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding(.horizontal, 28).padding(.vertical, 20)
        .background(panel.opacity(0.5))
        .overlay(alignment: .top) { Rectangle().fill(rule).frame(height: 1) }
    }

    private var startTitle: String {
        if case .tracks(let tool) = store.workspace { return tool.actionTitle }
        if case .utility(let tool) = store.workspace { return tool.actionTitle }
        return "开始转换"
    }

    private var canStart: Bool {
        if case .tracks(let tool) = store.workspace { return store.canStartTracks(tool) }
        return store.canStart
    }

    private var footerStatus: String {
        if store.stopping { return "正在停止并清理临时文件…" }
        if let tool = store.activeTrackTool {
            return ["正在处理", tool.title, store.activeTrackPath?.title].compactMap { $0 }.joined(separator: " · ")
        }
        if store.isRunning {
            return ["正在处理", store.activeJob?.input.lastPathComponent ?? "准备中", store.activeJob?.processingPath?.title]
                .compactMap { $0 }.joined(separator: " · ")
        }
        switch store.workspace {
        case .conversion, .utility: return "\(store.pendingCount) 项待处理 · \(store.completedCount) 项已完成"
        case .tracks(let tool):
            let selection = store.trackSelection(for: tool)
            if selection.output != nil { return "处理完成" }
            if selection.video == nil { return "等待添加视频" }
            if tool == .merge && selection.audio == nil { return "等待添加音频" }
            return "已准备好"
        default: return ""
        }
    }
}

private struct JobRow: View {
    @EnvironmentObject private var store: AppStore
    let job: ConversionJob
    let selected: Bool

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: job.kind.symbol).font(.system(size: 19)).foregroundStyle(accent)
                    .frame(width: 42, height: 48).background(accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 6) {
                    Text(job.input.lastPathComponent).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                        .help(job.input.path)
                    HStack(spacing: 6) {
                        Text(job.input.pathExtension.uppercased())
                        Text("·")
                        Text(ByteCountFormatter.string(fromByteCount: job.bytes, countStyle: .file))
                        Text("·")
                        Text(job.status.title).foregroundStyle(job.status.tint)
                    }
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.right").font(.system(size: 10)).foregroundStyle(.tertiary)
                Menu {
                    formatActions(job.utility?.outputFormats ?? store.formats(for: job.kind))
                    if job.kind == .video && job.utility == nil {
                        Divider()
                        Menu("提取音频") {
                            formatActions(store.formats(for: .audio))
                        }
                        Menu("导出动画") {
                            formatActions(store.formats(for: .image).filter(\.supportsAnimation))
                        }
                    }
                } label: {
                    Text(job.format.displayName)
                        .font(.system(size: 11, weight: .semibold)).frame(minWidth: 43)
                }
                .menuStyle(.borderlessButton).fixedSize()
                .disabled(store.isRunning || job.status != .waiting)
                .help("选择此文件的输出格式")
                if job.status == .waiting {
                    Button {
                        store.editParameters(for: job)
                    } label: {
                        Label("参数", systemImage: "slider.horizontal.3")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .buttonStyle(.borderless).tint(accent)
                    .disabled(store.isRunning)
                    .help("调整此文件的输出参数")
                    .accessibilityLabel("参数设置，\(job.input.lastPathComponent)")
                }
                Button { store.selectedJobID = job.id } label: {
                    Image(systemName: selected ? "info.circle.fill" : "info.circle")
                }
                .buttonStyle(.plain).foregroundStyle(selected ? accent : .secondary)
                .help("查看文件详情和错误")
                .accessibilityLabel("查看 \(job.input.lastPathComponent) 的详情")
                if let output = job.output, job.status == .completed {
                    Button { store.reveal(output) } label: { Image(systemName: "folder") }
                        .buttonStyle(.plain).help("在 Finder 中显示")
                } else if (job.status == .failed || job.status == .cancelled) && !store.isRunning {
                    Button { store.retry(job.id) } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.plain).help("重新加入队列")
                } else {
                    Button { store.remove(job.id) } label: { Image(systemName: "xmark").font(.system(size: 10)) }
                        .buttonStyle(.plain).foregroundStyle(.secondary).disabled(store.isRunning).help("从队列移除，不删除文件")
                }
            }
            if job.status == .running {
                HStack {
                    if let progress = job.progress {
                        ProgressView(value: progress).tint(accent)
                        Text("\(Int(progress * 100))%").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).frame(width: 32)
                    } else {
                        ProgressView().controlSize(.mini)
                        Text("处理中，正在等待时长信息…")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                        Spacer()
                    }
                }
            }
        }
        .padding(13)
        .background(selected ? accent.opacity(0.07) : panel, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(selected ? accent.opacity(0.45) : rule))
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .contextMenu {
            Button("显示源文件") { store.reveal(job.input) }
            if let output = job.output { Button("显示转换结果") { store.reveal(output) } }
            if job.status == .failed || job.status == .cancelled {
                Button("重试") { store.retry(job.id) }.disabled(store.isRunning)
            }
            Button("从队列移除") { store.remove(job.id) }.disabled(store.isRunning)
        }
    }

    private func formatActions(_ formats: [OutputFormat]) -> some View {
        ForEach(formats, id: \.self) { format in
            let unavailable = store.toolchain != nil && !store.supports(format, utility: job.utility)
            Button(format.displayName + (unavailable ? "（缺少编码器）" : "")) {
                store.setFormat(format, for: job.id)
            }
            .disabled(unavailable)
        }
    }

}

