import Foundation

public enum MediaKind: String, CaseIterable, Sendable {
    case video, audio, image
}

public enum OutputFormat: String, CaseIterable, Sendable {
    case mp4, mov, mkv, webm, mp3, m4a, wav, flac, ogg, aiff, png, jpeg, webp, tiff, bmp, gif, opus, aac, apng, avif

    public var supportsAnimation: Bool { [.gif, .webp, .apng].contains(self) }
    public var allowedVideoCodecs: [VideoCodec] {
        switch self {
        case .mp4: return [.automatic, .h264, .hevc, .av1, .mpeg4]
        case .mov: return [.automatic, .h264, .hevc, .prores, .mpeg4]
        case .mkv: return [.automatic, .h264, .hevc, .vp9, .av1, .prores, .mpeg1video, .mpeg2video, .mpeg4]
        case .webm: return [.automatic, .vp9, .av1]
        default: return []
        }
    }
    public func resolvedVideoCodec(options: ConversionOptions) -> VideoCodec {
        guard kind == .video else { return .automatic }
        return options.videoCodec == .automatic ? (self == .webm ? .vp9 : .h264) : options.videoCodec
    }
    public func requiredEncoders(options: ConversionOptions) -> Set<String> {
        if kind == .video { return [resolvedVideoCodec(options: options).encoder, audioEncoder(options: options)] }
        return [encoder(options: options)]
    }

    public var allowedAudioCodecs: [AudioCodec] {
        switch self {
        case .mp4: return [.aac, .alac, .ac3, .eac3, .mp3, .pcm]
        case .mov: return [.aac, .alac, .ac3, .mp3, .pcm]
        case .mkv: return [.aac, .ac3, .dts, .eac3, .flac, .mp2, .mp3, .opus, .vorbis, .alac, .pcm]
        case .webm: return [.opus, .vorbis]
        case .m4a: return [.aac, .alac]
        case .mp3: return [.mp3]
        case .aac: return [.aac]
        case .ogg: return [.vorbis, .opus]
        case .opus: return [.opus]
        case .flac: return [.flac]
        case .wav, .aiff: return [.pcm]
        default: return []
        }
    }

    public func resolvedAudioCodec(options: ConversionOptions) -> AudioCodec {
        if options.audioCodec != .automatic { return options.audioCodec }
        return allowedAudioCodecs.first ?? .automatic
    }

    public func audioEncoder(options: ConversionOptions) -> String {
        let codec = resolvedAudioCodec(options: options)
        if codec == .pcm { return "pcm_s\(options.pcmBitDepth)\(self == .aiff ? "be" : "le")" }
        return codec.encoder
    }

    func encoder(options: ConversionOptions) -> String {
        if kind == .video { return resolvedVideoCodec(options: options).encoder }
        if kind == .audio { return audioEncoder(options: options) }
        if self == .webp && options.animationMode == .preserve { return "libwebp_anim" }
        return requiredEncoder
    }

    public var kind: MediaKind {
        switch self {
        case .mp4, .mov, .mkv, .webm: return .video
        case .mp3, .m4a, .wav, .flac, .ogg, .aiff, .opus, .aac: return .audio
        default: return .image
        }
    }
    public var displayName: String { rawValue.uppercased() }
    public var fileExtension: String { rawValue }
    /// Includes the audio encoder used for an optional audio stream in video outputs.
    public var requiredEncoders: Set<String> {
        switch self {
        case .mp4, .mov, .mkv: return [requiredEncoder, "aac"]
        case .webm: return [requiredEncoder, "libopus"]
        default: return [requiredEncoder]
        }
    }
    public var requiredEncoder: String {
        switch self {
        case .mp4, .mov, .mkv: return "libx264"
        case .webm: return "libvpx-vp9"
        case .mp3: return "libmp3lame"
        case .m4a: return "aac"
        case .wav: return "pcm_s16le"
        case .flac: return "flac"
        case .ogg: return "libvorbis"
        case .aiff: return "pcm_s16be"
        case .png: return "png"
        case .jpeg: return "mjpeg"
        case .webp: return "libwebp"
        case .tiff: return "tiff"
        case .bmp: return "bmp"
        case .gif: return "gif"
        case .opus: return "libopus"
        case .aac: return "aac"
        case .apng: return "apng"
        case .avif: return "libaom-av1"
        }
    }
}

public enum ConversionQuality: String, CaseIterable, Sendable, Codable {
    case compact, balanced, high
}

public struct ConversionRequest: Sendable {
    public let input: URL
    public let output: URL
    public let format: OutputFormat
    public let quality: ConversionQuality
    public let options: ConversionOptions
    public let matchSource: Bool
    public init(input: URL, output: URL, format: OutputFormat, quality: ConversionQuality, options: ConversionOptions = ConversionOptions(),
                matchSource: Bool = false) {
        self.input = input; self.output = output; self.format = format; self.quality = quality; self.options = options
        self.matchSource = matchSource
    }
}

public struct ConversionProgress: Sendable {
    public let fraction: Double?
    public let processedSeconds: Double
    public init(fraction: Double?, processedSeconds: Double) {
        self.fraction = fraction; self.processedSeconds = processedSeconds
    }
}

public enum ProcessingPath: Equatable, Sendable {
    case videoToolbox, hardwareDecoding, software, videoCopy
}

public struct VideoHardwareCapabilities: Sendable {
    let encoders: Set<String>
    let canDecode: Bool

    public init(encoders: Set<String> = [], canDecode: Bool = false) {
        self.encoders = encoders
        self.canDecode = canDecode
    }
}

public enum TrackRequest: Sendable {
    case separate(video: URL, outputFolder: URL)
    case merge(video: URL, audio: URL, output: URL, format: OutputFormat = .mp4,
               options: ConversionOptions = ConversionOptions(), edit: MergeEdit = MergeEdit(), previewStart: Double? = nil)
}

public struct TrackTrim: Sendable, Equatable {
    public var start: Double
    public var end: Double?

    public init(start: Double = 0, end: Double? = nil) {
        self.start = start
        self.end = end
    }
}

public struct MergeEdit: Sendable, Equatable {
    public var video = TrackTrim()
    public var audio = TrackTrim()
    /// Positive values delay the trimmed audio on the edited video timeline.
    public var audioOffset: Double = 0
    public init() {}

    public func validate(videoDuration: Double? = nil, audioDuration: Double? = nil) throws {
        for (trim, duration, name) in [(video, videoDuration, "视频"), (audio, audioDuration, "音频")] {
            guard trim.start.isFinite, (0...86400).contains(trim.start),
                  duration.map({ trim.start < $0 }) ?? true,
                  trim.end.map({ $0.isFinite && $0 <= 86400 && $0 > trim.start && $0 <= (duration ?? 86400) + 0.001 }) ?? true else {
                throw ConversionError.invalidOptions("\(name)的入点和出点必须在素材时长内，且出点晚于入点。")
            }
        }
        guard audioOffset.isFinite, abs(audioOffset) <= 86400 else {
            throw ConversionError.invalidOptions("音频偏移须在 ±86400 秒内。")
        }
        if let videoEnd = video.end ?? videoDuration, audioOffset >= videoEnd - video.start {
            throw ConversionError.invalidOptions("音频起点超出了裁剪后的视频。请将音频向左移动。")
        }
        if let audioEnd = audio.end ?? audioDuration, audioOffset + audioEnd - audio.start <= 0 {
            throw ConversionError.invalidOptions("音频片段在视频开始前已经结束。请将音频向右移动。")
        }
    }
}

public enum MediaFile {
    public static func kind(for url: URL) -> MediaKind? {
        switch url.pathExtension.lowercased() {
        case "mp4", "mov", "mkv", "webm", "avi", "m4v", "mpg", "mpeg", "mts", "m2ts", "ts", "vob", "wmv", "flv", "3gp", "ogv": return .video
        case "mp3", "m4a", "wav", "flac", "ogg", "oga", "aif", "aiff", "aac", "opus", "wma", "caf", "alac", "amr": return .audio
        case "png", "jpg", "jpeg", "webp", "tif", "tiff", "bmp", "gif", "heic", "heif", "avif", "apng", "jxl", "ico": return .image
        default: return nil
        }
    }
}

public enum ConversionError: LocalizedError {
    case invalidOptions(String)
    case toolNotFound
    case invalidTool(URL)
    case inputMissing(URL)
    case sameInputAndOutput
    case outputExists(URL)
    case outputDirectoryMissing(URL)
    case runnerBusy
    case failed(Int32, String)
    case noOutput
    case toolTimedOut(String)

    public var errorDescription: String? {
        switch self {
        case .invalidOptions(let message): return "转换参数无效：\(message)"
        case .toolNotFound: return "未找到 FFmpeg。请安装 FFmpeg，或在设置中选择可执行文件。"
        case .invalidTool(let url): return "FFmpeg 文件不存在或不可执行：\(url.path)"
        case .inputMissing(let url): return "输入文件不存在或不是普通文件：\(url.lastPathComponent)"
        case .sameInputAndOutput: return "输入和输出不能是同一个文件。请选择其他输出位置。"
        case .outputExists(let url): return "输出文件已存在，不会覆盖：\(url.lastPathComponent)"
        case .outputDirectoryMissing(let url): return "输出文件夹不存在：\(url.path)"
        case .runnerBusy: return "已有转换正在运行，请等待完成。"
        case .failed(let status, let log): return "FFmpeg 退出（代码 \(status)）。\n\(log)"
        case .noOutput: return "FFmpeg 未生成输出文件。"
        case .toolTimedOut(let tool): return "\(tool) 响应超时。请检查所选工具是否正常。"
        }
    }
}

public struct Toolchain: Sendable {
    public let ffmpeg: URL
    public let ffprobe: URL?
    public init(ffmpeg: URL, ffprobe: URL?) { self.ffmpeg = ffmpeg; self.ffprobe = ffprobe }

    public static func discover(customFFmpeg: URL? = nil) throws -> Toolchain {
        try discover(customFFmpeg: customFFmpeg, environment: ProcessInfo.processInfo.environment,
                     standardDirectories: ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"])
    }

    // Injectable search locations keep discovery tests independent of the host installation.
    static func discover(customFFmpeg: URL?, environment: [String: String], standardDirectories: [String]) throws -> Toolchain {
        let paths = standardDirectories + (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        let directories = paths.filter { $0.hasPrefix("/") }.map { URL(fileURLWithPath: $0, isDirectory: true) }
        let selected: URL
        if let customFFmpeg {
            guard executable(customFFmpeg) else { throw ConversionError.invalidTool(customFFmpeg) }
            selected = customFFmpeg.standardizedFileURL
        } else if let candidate = directories.map({ $0.appendingPathComponent("ffmpeg") }).first(where: executable) {
            selected = candidate
        } else { throw ConversionError.toolNotFound }
        let adjacent = selected.deletingLastPathComponent().appendingPathComponent("ffprobe")
        let probe = ([adjacent] + directories.map { $0.appendingPathComponent("ffprobe") }).first(where: executable)
        return Toolchain(ffmpeg: selected, ffprobe: probe)
    }

    private static func executable(_ url: URL) -> Bool {
        guard url.isFileURL, FileManager.default.isExecutableFile(atPath: url.path),
              let values = try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.isRegularFileKey]), values.isRegularFile == true else { return false }
        return true
    }
}


