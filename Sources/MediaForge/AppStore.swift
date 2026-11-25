import AppKit
import Darwin
import SwiftUI
import UniformTypeIdentifiers
import MediaForgeCore

enum JobStatus: Equatable {
    case waiting, running, completed, failed, cancelled
    var title: String {
        switch self {
        case .waiting: return "等待处理"
        case .running: return "正在处理"
        case .completed: return "已完成"
        case .failed: return "处理失败"
        case .cancelled: return "已取消"
        }
    }
}

struct ConversionJob: Identifiable {
    let id = UUID()
    let createdAt = Date()
    let input: URL
    let kind: MediaKind
    let bytes: Int64
    var format: OutputFormat
    var utility: UtilityTool?
    var status: JobStatus = .waiting
    var progress: Double?
    var output: URL?
    var error: String?
    var settingsSummary: String?
    var animationContainer: OutputFormat?
    var parameters: EncodingParameters?
    var processingPath: ProcessingPath?

    var mayContainAnimation: Bool { animationContainer != nil || ["gif", "webp", "apng"].contains(input.pathExtension.lowercased()) }
}

extension MediaKind {
    var title: String {
        switch self { case .video: return "视频"; case .audio: return "音频"; case .image: return "图片" }
    }
    var symbol: String {
        switch self { case .video: return "film"; case .audio: return "waveform"; case .image: return "photo" }
    }
}

extension ConversionQuality {
    var title: String {
        switch self { case .compact: return "较小文件"; case .balanced: return "均衡"; case .high: return "高质量" }
    }
}

extension ProcessingPath {
    var title: String {
        switch self {
        case .videoToolbox: return "VideoToolbox 硬件编码"
        case .hardwareDecoding: return "硬件解码 · 软件编码"
        case .software: return "软件处理"
        case .videoCopy: return "视频流直拷"
        }
    }
}

@MainActor
final class AppStore: ObservableObject {
    @Published var jobs: [ConversionJob] = []
    @Published var workspace: Workspace = .home {
        didSet {
            switch workspace {
            case .utility(.extractAudio), .tracks:
                if case .category(let kind) = oldValue { toolCategory = kind }
                else { toolCategory = workspace == .utility(.extractAudio) ? .audio : .video }
            default: break
            }
            selectVisibleJobIfNeeded()
        }
    }
    private(set) var toolCategory: MediaKind = .video
    @Published private var archivedJobs: [ConversionJob] = []
    @Published private(set) var trackSelections: [TrackTool: TrackSelection] = [:]
    @Published private(set) var trackRuns: [TrackRun] = []
    @Published private var utilityPreferences: [UtilityTool: UtilityPreferences] = [:]
    @Published private(set) var activeTrackTool: TrackTool?
    @Published var selectedJobID: UUID?
    @Published var outputDirectory: URL?
    @Published var quality: ConversionQuality = .balanced { didSet { preferences.set(quality.rawValue, forKey: "quality") } }
    @Published var options = ConversionOptions() { didSet { saveOptions() } }
    @Published var selectedPreset: QuickPreset = .source {
        didSet { preferences.set(selectedPreset.rawValue, forKey: "quickPreset") }
    }
    @Published private(set) var videoFormat: OutputFormat = .mp4
    @Published private(set) var audioFormat: OutputFormat = .mp3
    @Published private(set) var imageFormat: OutputFormat = .png
    @Published var toolchain: Toolchain?
    @Published var encoders: Set<String> = []
    @Published private(set) var canHardwareDecode = false
    @Published var hardwareAccelerationEnabled = true {
        didSet { preferences.set(hardwareAccelerationEnabled, forKey: "hardwareAccelerationEnabled") }
    }
    @Published var appearance: AppAppearance = .system {
        didSet { preferences.set(appearance.rawValue, forKey: "appearance") }
    }
    @Published var checkingTools = false
    @Published var toolError: String?
    @Published var isRunning = false
    @Published var stopping = false
    @Published var notice: String?
    @Published var showSettings = false
    @Published var parameterEditor: ParameterTarget?
    @Published var showAnimationLossWarning = false
    @Published var animationLossCount = 0
    @Published var customFFmpegPath: String

    private let preferences: UserDefaults
    private var runner: FFmpegRunner?
    private var queueTask: Task<Void, Never>?
    private var toolTask: Task<Void, Never>?
    private var toolsGeneration = UUID()
    private var animationLossWorkspace: Workspace?

    init(preferences: UserDefaults = .standard) {
        self.preferences = preferences
        appearance = preferences.string(forKey: "appearance").flatMap(AppAppearance.init(rawValue:)) ?? .system
        hardwareAccelerationEnabled = preferences.object(forKey: "hardwareAccelerationEnabled") as? Bool ?? true
        // Old developer-tool paths must not override the new bundled engine on upgrade.
        customFFmpegPath = preferences.bool(forKey: "useCustomEngineV2") ? (preferences.string(forKey: "ffmpegPath") ?? "") : ""
        if let path = preferences.string(forKey: "outputDirectory"), FileManager.default.fileExists(atPath: path) {
            outputDirectory = URL(fileURLWithPath: path, isDirectory: true)
        }
        if let raw = preferences.string(forKey: "quality"), let value = ConversionQuality(rawValue: raw) { quality = value }
        if let data = preferences.data(forKey: "conversionOptionsV2"), let saved = try? JSONDecoder().decode(ConversionOptions.self, from: data) {
            options = saved
            selectedPreset = .custom
        }
        if let raw = preferences.string(forKey: "quickPreset"), let preset = QuickPreset(rawValue: raw) {
            selectedPreset = preset
        }
        if selectedPreset == .source { quality = .high }
        if let raw = preferences.string(forKey: "videoFormat"), let value = OutputFormat(rawValue: raw), value.kind == .video { videoFormat = value }
        if let raw = preferences.string(forKey: "audioFormat"), let value = OutputFormat(rawValue: raw), value.kind == .audio { audioFormat = value }
        if let raw = preferences.string(forKey: "imageFormat"), let value = OutputFormat(rawValue: raw), value.kind == .image { imageFormat = value }
        checkTools()
    }

    private func saveOptions() {
        if let data = try? JSONEncoder().encode(options) { preferences.set(data, forKey: "conversionOptionsV2") }
    }

    var filter: MediaKind? { workspace.mediaKind }
    var visibleJobs: [ConversionJob] { jobs(in: workspace) }
    var selectedJob: ConversionJob? { visibleJobs.first { $0.id == selectedJobID } }
    private var waitingJobs: [ConversionJob] { visibleJobs.filter { $0.status == .waiting } }
    var pendingCount: Int { waitingJobs.count }
    var completedCount: Int { visibleJobs.filter { $0.status == .completed }.count }
    var canStart: Bool { !isRunning && isReadyToEncode && pendingCount > 0 }
    var activeJob: ConversionJob? { jobs.first { $0.status == .running } }
    var activeTrackPath: ProcessingPath? { trackRuns.last?.status == .running ? trackRuns.last?.processingPath : nil }

    func tasks(in filter: TaskFilter) -> [TaskEntry] {
        let entries = (jobs + archivedJobs).map(TaskEntry.conversion) + trackRuns.map(TaskEntry.tracks)
        return entries.filter { filter.includes($0.status) }.sorted { $0.createdAt > $1.createdAt }
    }

    func taskCount(in filter: TaskFilter) -> Int {
        jobs.lazy.filter { filter.includes($0.status) }.count +
            archivedJobs.lazy.filter { filter.includes($0.status) }.count +
            trackRuns.lazy.filter { filter.includes($0.status) }.count
    }

    var hardwareVideoCodecs: [VideoCodec] {
        VideoCodec.allCases.filter { codec in codec.hardwareEncoder.map(encoders.contains) == true }
    }

    var videoHardware: VideoHardwareCapabilities {
        guard hardwareAccelerationEnabled else { return VideoHardwareCapabilities() }
        return VideoHardwareCapabilities(encoders: Set(hardwareVideoCodecs.compactMap(\.hardwareEncoder)), canDecode: canHardwareDecode)
    }

    private var isReadyToEncode: Bool { !checkingTools && toolchain != nil }

    private func jobs(in workspace: Workspace) -> [ConversionJob] {
        switch workspace {
        case .conversion(let kind): return jobs.filter { $0.kind == kind && $0.utility == nil }
        case .utility(let tool): return jobs.filter { $0.utility == tool }
        default: return []
        }
    }

    func openTask(_ entry: TaskEntry, retry: Bool = false) {
        switch entry {
        case .conversion(let job):
            if retry { self.retry(job.id) }
            workspace = job.utility.map(Workspace.utility) ?? .conversion(job.kind)
            selectedJobID = job.id
        case .tracks(let run):
            guard !isRunning else { return }
            trackSelections[run.tool] = TrackSelection(video: run.video, audio: run.audio, output: run.output, merge: run.merge)
            workspace = .tracks(run.tool)
        }
    }

    private func selectVisibleJobIfNeeded() {
        if selectedJob == nil { selectedJobID = visibleJobs.first?.id }
    }

    func formats(for kind: MediaKind) -> [OutputFormat] {
        OutputFormat.allCases.filter { $0.kind == kind }
    }

    func supports(_ format: OutputFormat, utility: UtilityTool? = nil) -> Bool {
        let settings = effectiveOptions(for: format, from: utility == nil ? nil : ConversionOptions())
        return toolchain != nil && format.requiredEncoders(options: settings).isSubset(of: encoders)
    }

    func defaultFormat(for kind: MediaKind) -> OutputFormat {
        switch kind { case .video: return videoFormat; case .audio: return audioFormat; case .image: return imageFormat }
    }

    func setDefault(_ format: OutputFormat, for kind: MediaKind) {
        guard !isRunning, format.kind == kind else { return }
        switch kind { case .video: videoFormat = format; case .audio: audioFormat = format; case .image: imageFormat = format }
        preferences.set(format.rawValue, forKey: "\(kind.rawValue)Format")
        for index in jobs.indices where jobs[index].utility == nil && jobs[index].kind == kind && jobs[index].status == .waiting && jobs[index].format.kind == kind {
            jobs[index].format = format
        }
    }

    func utilitySettings(for tool: UtilityTool) -> UtilityPreferences {
        utilityPreferences[tool] ?? UtilityPreferences(format: tool.initialFormat)
    }

    func setUtilityFormat(_ format: OutputFormat, for tool: UtilityTool) {
        guard !isRunning, tool.outputFormats.contains(format) else { return }
        var settings = utilitySettings(for: tool)
        settings.format = format
        utilityPreferences[tool] = settings
        for index in jobs.indices where jobs[index].utility == tool && jobs[index].status == .waiting {
            jobs[index].format = format
        }
    }

    func setUtilityQuality(_ quality: ConversionQuality, for tool: UtilityTool) {
        guard !isRunning, tool != .extractAudio else { return }
        var settings = utilitySettings(for: tool)
        settings.quality = quality
        utilityPreferences[tool] = settings
    }

    func setFormat(_ format: OutputFormat, for id: UUID) {
        guard !isRunning, let index = jobs.firstIndex(where: { $0.id == id }), jobs[index].status == .waiting else { return }
        let job = jobs[index]
        if let utility = job.utility {
            guard utility.outputFormats.contains(format) else { return }
        } else {
            guard format.kind == job.kind || (job.kind == .video && (format.kind == .audio || format.supportsAnimation)) else { return }
        }
        jobs[index].format = format
    }

    func importFiles() {
        switch workspace {
        case .home, .category, .conversion:
            let urls = pickFiles(title: "添加视频、音频或图片", message: "支持批量选择，文件会按媒体类型归入对应分类。", multiple: true)
            importDroppedFiles(urls)
        case .utility(let tool):
            addFiles(pickFiles(title: "添加\(tool.inputKind.title)文件", message: tool.detail, multiple: true), for: tool)
        case .tracks(.separate):
            chooseTrackInput(.video, for: .separate)
        case .tracks(.merge):
            let urls = pickFiles(title: "添加合并素材", message: "选择一个视频和一个音频，可以分次添加。", multiple: true)
            addTrackFiles(urls, for: .merge)
        case .tasks: break
        }
    }

    func importDroppedFiles(_ urls: [URL]) {
        switch workspace {
        case .conversion: addFiles(urls)
        case .utility(let tool): addFiles(urls, for: tool)
        case .home, .category:
            let first = jobs.count
            addFiles(urls)
            if let job = jobs.dropFirst(first).first { workspace = .conversion(job.kind) }
        case .tracks(let tool): addTrackFiles(urls, for: tool)
        case .tasks: break
        }
    }

    private func pickFiles(title: String, message: String, multiple: Bool) -> [URL] {
        let panel = NSOpenPanel()
        panel.title = title
        panel.message = message
        panel.allowsMultipleSelection = multiple
        panel.canChooseDirectories = false
        return panel.runModal() == .OK ? panel.urls : []
    }

    func chooseTrackInput(_ kind: MediaKind, for tool: TrackTool) {
        let urls = pickFiles(title: "选择\(kind.title)文件", message: "", multiple: false)
        addTrackFiles(urls, for: tool, expected: kind)
    }

    func trackSelection(for tool: TrackTool) -> TrackSelection { trackSelections[tool] ?? TrackSelection() }

    func updateMerge(_ update: (inout MergeSettings) -> Void) {
        guard !isRunning else { return }
        var selection = trackSelection(for: .merge)
        update(&selection.merge)
        selection.output = nil
        trackSelections[.merge] = selection
    }

    func setMergeFormat(_ format: OutputFormat) {
        guard format.kind == .video else { return }
        updateMerge {
            $0.format = format
            $0.options = effectiveOptions(for: format, from: $0.options)
        }
    }

    func addTrackFiles(_ urls: [URL], for tool: TrackTool, expected: MediaKind? = nil) {
        guard !isRunning, !urls.isEmpty else { return }
        var selection = trackSelection(for: tool)
        var added: Set<MediaKind> = []
        var skipped: [String] = []
        for original in urls {
            let url = original.standardizedFileURL.resolvingSymlinksInPath()
            guard url.isFileURL, let kind = MediaFile.kind(for: url),
                  expected == nil || expected == kind,
                  kind == .video || (kind == .audio && tool == .merge),
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                  added.insert(kind).inserted else {
                skipped.append(original.lastPathComponent)
                continue
            }
            if kind == .video { selection.video = url } else { selection.audio = url }
        }
        if !added.isEmpty {
            if added.contains(.video) { selection.merge.edit.video = TrackTrim() }
            if added.contains(.audio) { selection.merge.edit.audio = TrackTrim() }
            selection.merge.edit.audioOffset = 0
            selection.output = nil
            trackSelections[tool] = selection
        }
        if !skipped.isEmpty {
            let requirement = tool == .separate ? "请选择一个视频文件" : "请选择一个视频和一个音频文件"
            notice = "\(requirement)。以下文件未添加：\n" + skipped.joined(separator: "\n")
        }
    }

    func removeTrackInput(_ kind: MediaKind, for tool: TrackTool) {
        guard !isRunning else { return }
        var selection = trackSelection(for: tool)
        if kind == .video {
            selection.video = nil
            selection.merge.edit.video = TrackTrim()
        } else {
            selection.audio = nil
            selection.merge.edit.audio = TrackTrim()
        }
        selection.merge.edit.audioOffset = 0
        selection.output = nil
        trackSelections[tool] = selection
    }

    func canStartTracks(_ tool: TrackTool) -> Bool {
        let selection = trackSelection(for: tool)
        return !isRunning && isReadyToEncode && selection.video != nil && (tool == .separate || selection.audio != nil)
    }

    func addFiles(_ urls: [URL], for utility: UtilityTool? = nil) {
        guard !isRunning else { notice = "请等待当前批次完成，或停止后再添加文件。"; return }
        var skipped: [String] = []
        var known = Set(jobs.filter { $0.utility == utility }.map { $0.input.path })
        for original in urls {
            let url = original.standardizedFileURL.resolvingSymlinksInPath()
            guard url.isFileURL, let kind = MediaFile.kind(for: url),
                  utility == nil || utility?.inputKind == kind,
                  let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true else {
                skipped.append(original.lastPathComponent)
                continue
            }
            guard known.insert(url.path).inserted else { continue }
            // Keep animation-capable inputs in an animation-capable container by default.
            let animationFormat = kind == .image ? ImportMediaHints.animationContainer(for: url) : nil
            let initialFormat = utility.map { utilitySettings(for: $0).format } ?? animationFormat ?? defaultFormat(for: kind)
            jobs.append(ConversionJob(input: url, kind: kind, bytes: Int64(values.fileSize ?? 0), format: initialFormat,
                                      utility: utility, animationContainer: animationFormat))
        }
        selectVisibleJobIfNeeded()
        if !skipped.isEmpty {
            let reason = utility.map { "此工具接受可读取的\($0.inputKind.title)文件" } ?? "未知扩展名、目录或文件不可读"
            notice = "以下文件未添加（\(reason)）：\n" + skipped.prefix(10).joined(separator: "\n") + (skipped.count > 10 ? "\n…另有 \(skipped.count - 10) 项" : "")
        }
    }

    func chooseOutputDirectory() {
        let panel = NSOpenPanel()
        panel.title = "选择转换结果保存位置"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = outputDirectory
        if panel.runModal() == .OK, let url = panel.url {
            outputDirectory = url
            preferences.set(url.path, forKey: "outputDirectory")
        }
    }

    func useSourceDirectory() {
        guard !isRunning else { return }
        outputDirectory = nil
        preferences.removeObject(forKey: "outputDirectory")
    }

    func chooseFFmpeg() {
        let panel = NSOpenPanel()
        panel.title = "选择 FFmpeg 可执行文件"
        panel.message = "软件将运行此程序。请仅选择从可信来源取得的 FFmpeg，不要选择安装包或脚本。"
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            customFFmpegPath = url.path
            preferences.set(url.path, forKey: "ffmpegPath")
            preferences.set(true, forKey: "useCustomEngineV2")
            checkTools()
        }
    }

    func resetToolPath() {
        customFFmpegPath = ""
        preferences.removeObject(forKey: "ffmpegPath")
        preferences.set(false, forKey: "useCustomEngineV2")
        checkTools()
    }

    func checkTools() {
        guard !isRunning else { return }
        toolTask?.cancel()
        let generation = UUID()
        toolsGeneration = generation
        checkingTools = true
        toolchain = nil
        encoders = []
        canHardwareDecode = false
        toolError = nil
        let customURL = customFFmpegPath.isEmpty ? nil : URL(fileURLWithPath: customFFmpegPath)
        toolTask = Task { [weak self] in
            do {
                let chain = try EngineLocator.resolve(customFFmpeg: customURL)
                async let available = FFmpegRunner(toolchain: chain).availableEncoders()
                async let decoder = try? FFmpegRunner(toolchain: chain).supportsVideoToolboxDecoding()
                let (detected, canDecode) = try await (available, decoder)
                guard let self, self.toolsGeneration == generation else { return }
                self.toolchain = chain
                self.encoders = detected
                self.canHardwareDecode = canDecode ?? false
                self.checkingTools = false
            } catch {
                guard let self, self.toolsGeneration == generation else { return }
                self.toolError = error.localizedDescription
                self.checkingTools = false
            }
        }
    }

    func start() {
        switch workspace {
        case .conversion, .utility: startBatch(in: workspace, allowAnimationLoss: false)
        case .tracks(let tool): startTracks(tool)
        case .home, .category, .tasks: break
        }
    }

    func confirmFirstFrameConversion() {
        showAnimationLossWarning = false
        if let workspace = animationLossWorkspace { startBatch(in: workspace, allowAnimationLoss: true) }
    }

    private func startTracks(_ tool: TrackTool) {
        let selection = trackSelection(for: tool)
        guard canStartTracks(tool), let chain = toolchain, let video = selection.video else { return }
        let merge = selection.merge
        let required = tool == .merge ? merge.format.requiredEncoders(options: merge.options) : OutputFormat.mp4.requiredEncoders
        let missing = required.subtracting(encoders)
        guard missing.isEmpty else {
            notice = "当前 FFmpeg 缺少所需编码器：\(missing.sorted().joined(separator: "、"))。"
            return
        }
        let chosenDirectory = outputDirectory
        trackSelections[tool]?.output = nil
        activeTrackTool = tool
        let index = trackRuns.count
        trackRuns.append(TrackRun(tool: tool, video: video, audio: selection.audio, merge: merge))
        runQueue { store in
            do {
                let directory = try store.prepareOutputDirectory(for: video, chosen: chosenDirectory)
                let stem = video.deletingPathExtension().lastPathComponent
                let output: URL
                let request: TrackRequest
                switch tool {
                case .separate:
                    output = store.uniqueOutput(stem: stem + "_separated", directory: directory)
                    request = .separate(video: video, outputFolder: output)
                case .merge:
                    guard let audio = selection.audio else { return }
                    output = store.uniqueOutput(stem: stem + "_merged", fileExtension: merge.format.fileExtension, directory: directory)
                    request = .merge(video: video, audio: audio, output: output, format: merge.format, options: merge.options, edit: merge.edit)
                }
                let runner = FFmpegRunner(toolchain: chain, hardware: store.videoHardware)
                store.runner = runner
                let path = try await runner.processTracks(request) { [weak store] path in
                    Task { @MainActor [weak store] in
                        guard let store, store.trackRuns[index].status == .running else { return }
                        store.trackRuns[index].processingPath = path
                    }
                }
                store.trackSelections[tool]?.output = output
                store.trackRuns[index].processingPath = path
                store.trackRuns[index].output = output
                store.trackRuns[index].status = .completed
            } catch is CancellationError {
                store.trackRuns[index].status = .cancelled
            } catch {
                store.trackRuns[index].error = error.localizedDescription
                store.trackRuns[index].status = .failed
                store.notice = error.localizedDescription
            }
        }
    }

    private func startBatch(in workspace: Workspace, allowAnimationLoss: Bool) {
        guard !isRunning, isReadyToEncode, let chain = toolchain else { return }
        let waitingJobs = jobs(in: workspace).filter { $0.status == .waiting }
        guard !waitingJobs.isEmpty else { return }
        let batch = waitingJobs.map { (job: $0, encoding: encoding(for: $0)) }
        do {
            for item in batch { try item.encoding.options.validate(for: item.job.format) }
        } catch {
            notice = error.localizedDescription
            return
        }
        if !allowAnimationLoss {
            let losing = batch.filter { item in
                let job = item.job
                return job.format.kind == .image && (job.mayContainAnimation || job.kind == .video) &&
                    (!job.format.supportsAnimation || item.encoding.options.animationMode == .firstFrame)
            }
            if !losing.isEmpty {
                animationLossWorkspace = workspace
                animationLossCount = losing.count
                showAnimationLossWarning = true
                return
            }
        }
        if let directory = outputDirectory, !FileManager.default.isWritableFile(atPath: directory.path) {
            notice = "输出目录不可写，请重新选择保存位置。"
            return
        }
        let batchDirectory = outputDirectory
        let unsupported = batch.compactMap { item -> String? in
            let missing = item.job.format.requiredEncoders(options: item.encoding.options).subtracting(encoders)
            guard !missing.isEmpty else { return nil }
            return "\(item.job.input.lastPathComponent) → \(item.job.format.displayName)（\(missing.sorted().joined(separator: ", "))）"
        }
        guard unsupported.isEmpty else {
            notice = "当前 FFmpeg 缺少部分目标编码器。请调整这些任务的参数：\n" + unsupported.joined(separator: "\n")
            return
        }
        runQueue { store in
            for item in batch {
                if store.stopping || Task.isCancelled { break }
                let id = item.job.id
                guard let index = store.jobs.firstIndex(where: { $0.id == id }) else { continue }
                let input = item.job.input
                let format = item.job.format
                let configuration = item.encoding
                store.jobs[index].settingsSummary = store.settingsDescription(format: format, options: configuration.options,
                                                                             matchSource: configuration.matchSource)
                store.jobs[index].status = .running
                store.jobs[index].progress = nil
                store.jobs[index].error = nil
                store.jobs[index].output = nil
                store.jobs[index].processingPath = nil
                do {
                    let directory = try store.prepareOutputDirectory(for: input, chosen: batchDirectory)
                    let stem = input.deletingPathExtension().lastPathComponent + "_converted"
                    let output = store.uniqueOutput(stem: stem, fileExtension: format.fileExtension, directory: directory)
                    let runner = FFmpegRunner(toolchain: chain, hardware: store.videoHardware)
                    store.runner = runner
                    let request = ConversionRequest(input: input, output: output, format: format, quality: configuration.quality,
                                                    options: configuration.options, matchSource: configuration.matchSource)
                    let path = try await runner.convert(request, onProcessing: { [weak store] path in
                        Task { @MainActor [weak store] in
                            guard let store, let i = store.jobs.firstIndex(where: { $0.id == id }), store.jobs[i].status == .running else { return }
                            store.jobs[i].processingPath = path
                        }
                    }) { [weak store] progress in
                        Task { @MainActor [weak store] in
                            guard let store, let i = store.jobs.firstIndex(where: { $0.id == id }),
                                  store.jobs[i].status == .running, store.jobs[i].progress != progress.fraction else { return }
                            store.jobs[i].progress = progress.fraction
                        }
                    }
                    store.jobs[index].status = .completed
                    store.jobs[index].processingPath = path
                    store.jobs[index].progress = 1
                    store.jobs[index].output = output
                } catch is CancellationError {
                    store.jobs[index].status = .cancelled
                    store.jobs[index].progress = nil
                } catch {
                    store.jobs[index].status = .failed
                    store.jobs[index].error = error.localizedDescription
                    store.jobs[index].progress = nil
                }
                store.runner = nil
            }
        }
    }

    private func runQueue(_ work: @escaping @MainActor (AppStore) async -> Void) {
        isRunning = true
        stopping = false
        queueTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.runner = nil
                self.activeTrackTool = nil
                self.stopping = false
                self.queueTask = nil
                self.isRunning = false
            }
            await work(self)
        }
    }

    func stop() {
        guard isRunning else { return }
        stopping = true
        runner?.cancel()
        queueTask?.cancel()
    }

    func retry(_ id: UUID) {
        guard !isRunning, let index = jobs.firstIndex(where: { $0.id == id }), [.failed, .cancelled].contains(jobs[index].status) else { return }
        jobs[index].status = .waiting
        jobs[index].error = nil
        jobs[index].progress = nil
    }

    func remove(_ id: UUID) {
        guard !isRunning else { return }
        if let completed = jobs.first(where: { $0.id == id && $0.status == .completed }) {
            archivedJobs.append(completed)
        }
        jobs.removeAll { $0.id == id }
        selectVisibleJobIfNeeded()
    }

    func clearFinished() {
        guard !isRunning else { return }
        let completed = visibleJobs.filter { $0.status == .completed }
        archivedJobs.append(contentsOf: completed)
        let ids = Set(completed.map(\.id))
        jobs.removeAll { ids.contains($0.id) }
        selectVisibleJobIfNeeded()
    }

    func reveal(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }

    private func prepareOutputDirectory(for input: URL, chosen: URL?) throws -> URL {
        let directory = chosen ?? input.deletingLastPathComponent().appendingPathComponent("MediaForge 输出", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard FileManager.default.isWritableFile(atPath: directory.path) else {
            throw NSError(domain: "MediaForge", code: 1, userInfo: [NSLocalizedDescriptionKey: "保存位置不可写：\(directory.path)。请重新选择输出文件夹。"])
        }
        return directory
    }

    private func uniqueOutput(stem: String, fileExtension: String? = nil, directory: URL) -> URL {
        func url(named name: String) -> URL {
            let url = directory.appendingPathComponent(name)
            return fileExtension.map { url.appendingPathExtension($0) } ?? url
        }
        var candidate = url(named: stem)
        var count = 2
        // lstat: a dangling symlink must also be treated as taken, matching the
        // engine's exclusive commit, which refuses any existing directory entry.
        while pathIsOccupied(candidate) {
            candidate = url(named: "\(stem)_\(count)")
            count += 1
        }
        return candidate
    }

    private func pathIsOccupied(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0
    }
}
