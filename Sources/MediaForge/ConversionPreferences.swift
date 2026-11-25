import Foundation
import MediaForgeCore

struct EncodingParameters {
    var options = ConversionOptions()
    var quality: ConversionQuality = .balanced
    var matchSource = false
}

struct ParameterTarget: Identifiable {
    let id = UUID()
    let jobID: UUID?
    let format: OutputFormat
    let title: String
    let initial: EncodingParameters
    var isMerge = false
}

enum QuickPreset: String, CaseIterable {
    case source, balanced, small, highQuality, custom
    var title: String {
        switch self {
        case .source: return "与源文件相同"
        case .balanced: return "日常推荐"
        case .small: return "压缩分享"
        case .highQuality: return "高质量"
        case .custom: return "自定义"
        }
    }

    var detail: String {
        switch self {
        case .source: return "保留原始尺寸与帧率。音视频编码兼容时直接保留，其余按高质量编码。"
        case .balanced, .highQuality: return "保留原始尺寸与帧率 · 自动匹配编码器 · 保留动画"
        case .small: return "较小文件 · 画面不超过 1280 × 720 · 保留动画"
        case .custom: return "正在使用自定义编码参数。"
        }
    }
}

@MainActor
extension AppStore {
    func encoding(for job: ConversionJob) -> EncodingParameters {
        var result: EncodingParameters
        if let parameters = job.parameters {
            result = parameters
        } else if let utility = job.utility {
            result = EncodingParameters(quality: utilitySettings(for: utility).quality, matchSource: utility == .extractAudio)
        } else {
            result = EncodingParameters(options: options, quality: quality, matchSource: selectedPreset == .source)
        }
        result.options = effectiveOptions(for: job.format, from: result.options)
        return result
    }

    func editParameters(for job: ConversionJob) {
        guard !isRunning, job.status == .waiting else { return }
        parameterEditor = ParameterTarget(jobID: job.id, format: job.format, title: job.input.lastPathComponent,
                                          initial: encoding(for: job))
    }

    func editDefaultParameters(for format: OutputFormat) {
        guard !isRunning else { return }
        let initial = EncodingParameters(options: effectiveOptions(for: format), quality: quality)
        parameterEditor = ParameterTarget(jobID: nil, format: format, title: "默认设置 · 应用于未单独设置的任务", initial: initial)
    }

    func editMergeParameters() {
        guard !isRunning else { return }
        let merge = trackSelection(for: .merge).merge
        parameterEditor = ParameterTarget(jobID: nil, format: merge.format, title: "音视频合并",
                                          initial: EncodingParameters(options: merge.options, quality: .high), isMerge: true)
    }

    func saveParameters(_ parameters: EncodingParameters, for target: ParameterTarget) throws {
        guard !isRunning else { return }
        let format = target.format
        let edited = parameters.options
        try edited.validate(for: format)
        let missing = format.requiredEncoders(options: edited).subtracting(encoders)
        if toolchain != nil && !missing.isEmpty {
            throw ConversionError.invalidOptions("当前引擎缺少 \(missing.sorted().joined(separator: "、"))。")
        }
        if target.isMerge {
            guard trackSelection(for: .merge).merge.format == format else { return }
            updateMerge { $0.options = edited }
        } else if let id = target.jobID {
            guard let index = jobs.firstIndex(where: { $0.id == id && $0.status == .waiting && $0.format == format }) else { return }
            jobs[index].parameters = parameters
        } else {
            var updated = options
            if format.kind == .video {
                updated.videoCodec = edited.videoCodec
                updated.videoBitrateKbps = edited.videoBitrateKbps
                updated.videoRateMode = edited.videoRateMode
                updated.videoCRF = edited.videoCRF
                updated.videoCRFPreset = edited.videoCRFPreset
            }
            if format.kind != .audio {
                updated.resolution = edited.resolution
                updated.customWidth = edited.customWidth
                updated.customHeight = edited.customHeight
                updated.frameFit = edited.frameFit
                if format.kind == .video || format.supportsAnimation { updated.frameRate = edited.frameRate }
            }
            if format.kind != .image {
                updated.audioCodec = edited.audioCodec
                updated.audioSampleRate = edited.audioSampleRate
                updated.audioBitrateKbps = edited.audioBitrateKbps
                if format.resolvedAudioCodec(options: edited) == .pcm { updated.pcmBitDepth = edited.pcmBitDepth }
            } else if format.supportsAnimation {
                updated.animationMode = edited.animationMode
                updated.animationLoop = edited.animationLoop
            }
            options = updated
            quality = parameters.quality
            selectedPreset = .custom
        }
    }

    func applyPreset(_ preset: QuickPreset) {
        guard !isRunning else { return }
        selectedPreset = preset
        guard preset != .custom else { return }
        var next = ConversionOptions()
        switch preset {
        case .balanced: quality = .balanced
        case .small: quality = .compact; next.resolution = .p720
        case .source, .highQuality: quality = .high
        case .custom: break
        }
        options = next
    }

    /// A mixed queue can contain different containers. Unsupported codec preferences
    /// fall back to that container's default, while irrelevant controls are cleared.
    /// The UI exposes the resolved settings for each job before it is run.
    func effectiveOptions(for format: OutputFormat, from source: ConversionOptions? = nil) -> ConversionOptions {
        var result = source ?? options
        if format.kind == .video {
            if result.videoCodec != .automatic && !format.allowedVideoCodecs.contains(result.videoCodec) { result.videoCodec = .automatic }
            let codec = format.resolvedVideoCodec(options: result)
            if !codec.supports(result.resolvedVideoRateMode) {
                result.videoRateMode = nil
                result.videoBitrateKbps = nil
                result.videoCRF = nil
                result.videoCRFPreset = nil
            } else if let crf = result.videoCRF, let range = codec.crfRange {
                result.videoCRF = min(max(crf, range.lowerBound), range.upperBound)
            }
        } else {
            result.videoCodec = .automatic
            result.videoBitrateKbps = nil
            result.videoRateMode = nil
            result.videoCRF = nil
            result.videoCRFPreset = nil
        }
        if !format.allowedAudioCodecs.contains(result.audioCodec) { result.audioCodec = .automatic }
        let audio = format.resolvedAudioCodec(options: result)
        if let bitrate = result.audioBitrateKbps, !audio.acceptsBitrate(bitrate) { result.audioBitrateKbps = nil }
        if let rate = result.audioSampleRate, format.kind == .image || !audio.acceptsSampleRate(rate) { result.audioSampleRate = nil }
        if audio == .mp2, let rate = result.audioSampleRate, rate < 32000, (result.audioBitrateKbps ?? 0) > 160 { result.audioBitrateKbps = nil }
        if format.resolvedVideoCodec(options: result).usesStandardFrameRate, let fps = result.frameRate,
           ![24, 25, 30, 50, 60].contains(fps) { result.frameRate = nil }
        if format.kind != .image { result.animationMode = .preserve }
        if format.kind == .audio {
            result.resolution = .original
            result.frameRate = nil
        } else if format.kind == .image && (!format.supportsAnimation || result.animationMode == .firstFrame) {
            result.frameRate = nil
        }
        if audio != .pcm { result.pcmBitDepth = 16 }
        return result
    }

    func settingsDescription(format: OutputFormat, options: ConversionOptions, matchSource: Bool = false) -> String {
        var parts: [String] = []
        if matchSource && format.kind != .image {
            parts.append("兼容时保留源编码，必要时高质量转码")
        } else if format.kind == .video {
            parts.append(format.resolvedVideoCodec(options: options).displayName)
            switch options.resolvedVideoRateMode {
            case .source: parts.append(options.videoRateMode == .source ? "参考源视频码率" : "自动码率")
            case .cbr, .abr:
                if let rate = options.videoBitrateKbps { parts.append("\(options.resolvedVideoRateMode.rawValue.uppercased()) \(rate) kbps") }
            case .crf:
                if let crf = options.resolvedVideoCRF(for: format.resolvedVideoCodec(options: options)) { parts.append("CRF \(crf)") }
            }
        }
        if !matchSource && format.kind != .image {
            let audio = format.resolvedAudioCodec(options: options)
            parts.append(audio == .pcm ? "\(options.pcmBitDepth)-bit PCM" : audio.displayName)
        }
        if format.kind != .audio {
            parts.append(options.resolution == .custom ? "不超过 \(options.customWidth) × \(options.customHeight)" : options.resolution.displayName)
            if let fps = options.frameRate ?? (format.resolvedVideoCodec(options: options).usesStandardFrameRate ? 25 : nil) {
                parts.append("\(fps) fps")
            }
        }
        if let rate = options.audioBitrateKbps { parts.append("音频 \(rate) kbps") }
        if let rate = options.audioSampleRate { parts.append("\(rate) Hz") }
        if format.kind == .image {
            if format.supportsAnimation && options.animationMode == .preserve {
                parts.append("保留动画帧 · \(options.animationLoop.displayName)")
            } else { parts.append("仅导出首帧") }
        }
        return parts.joined(separator: " · ")
    }

    func animationMessage(for job: ConversionJob) -> String? {
        guard job.format.kind == .image else { return nil }
        let settings = encoding(for: job).options
        if job.format.supportsAnimation && settings.animationMode == .preserve {
            let timing = settings.frameRate.map { "按 \($0) fps 重新采样帧率" } ?? "保留帧间时序"
            return "保留所有帧，\(timing)；\(settings.animationLoop.displayName)。不继承源文件的循环次数。" + (job.kind == .video ? " 输出动画不含音频。" : "")
        }
        if job.mayContainAnimation || job.kind == .video {
            return "当前将仅导出第一帧，后续画面不会保留。要保留动画，请选 GIF / WebP / APNG 并启用保留动画。"
        }
        return "静态图片输出；如果源文件包含多帧，只保留首帧。"
    }

    var engineLabel: String {
        guard let toolchain else { return checkingTools ? "正在准备引擎" : "引擎不可用" }
        return EngineLocator.isBundled(toolchain) ? "内置引擎已就绪" : "外部引擎已就绪"
    }

    var outputLocationLabel: String { outputDirectory?.lastPathComponent ?? "源文件旁 · MediaForge 输出" }

    func openLicenses() {
        let folder = Bundle.main.resourceURL?.appendingPathComponent("ThirdParty", isDirectory: true)
        if let folder, FileManager.default.fileExists(atPath: folder.path) { reveal(folder) }
        else { notice = "开发环境请查看项目 ThirdParty 目录；打包的应用内包含许可与引擎来源说明。" }
    }
}
