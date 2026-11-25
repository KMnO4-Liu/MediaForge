import Foundation

public enum VideoCodec: String, CaseIterable, Sendable, Codable {
    case automatic, h264, hevc, vp9, av1, prores, mpeg1video, mpeg2video, mpeg4
    public var displayName: String {
        switch self {
        case .automatic: return "自动（推荐）"
        case .h264: return "H.264"
        case .hevc: return "HEVC / H.265"
        case .vp9: return "VP9"
        case .av1: return "AV1"
        case .prores: return "Apple ProRes"
        case .mpeg1video: return "MPEG-1"
        case .mpeg2video: return "MPEG-2"
        case .mpeg4: return "MPEG-4 Part 2"
        }
    }
    public var encoder: String {
        switch self {
        case .automatic: return ""
        case .h264: return "libx264"
        case .hevc: return "libx265"
        case .vp9: return "libvpx-vp9"
        case .av1: return "libaom-av1"
        case .prores: return "prores_ks"
        case .mpeg1video, .mpeg2video, .mpeg4: return rawValue
        }
    }

    public var usesStandardFrameRate: Bool { self == .mpeg1video || self == .mpeg2video }

    public var hardwareEncoder: String? {
        switch self {
        case .h264, .hevc, .prores: return rawValue + "_videotoolbox"
        default: return nil
        }
    }

    public var crfRange: ClosedRange<Int>? {
        switch self {
        case .h264, .hevc: return 0...51
        case .vp9, .av1: return 0...63
        default: return nil
        }
    }

    public func recommendedCRF(for quality: ConversionQuality) -> Int? {
        switch self {
        case .h264, .hevc: return quality == .high ? 18 : quality == .balanced ? 23 : 28
        case .vp9, .av1: return quality == .high ? 24 : quality == .balanced ? 32 : 40
        default: return nil
        }
    }

    public func supports(_ mode: VideoRateMode) -> Bool {
        switch mode {
        case .source: return true
        case .abr: return self != .prores && self != .automatic
        case .cbr, .crf: return crfRange != nil
        }
    }
}

public enum VideoRateMode: String, CaseIterable, Sendable, Codable {
    case source, cbr, abr, crf
}
public enum AudioCodec: String, CaseIterable, Sendable, Codable {
    case automatic, aac, alac, ac3, eac3, dts, flac, mp2, mp3, opus, vorbis, pcm
    public var displayName: String { self == .automatic ? "自动（推荐）" : rawValue.uppercased() }

    public var supportsBitrate: Bool { ![.automatic, .alac, .flac, .pcm].contains(self) }

    public var sampleRates: [Int] {
        switch self {
        case .ac3, .eac3, .mp3: return [32000, 44100, 48000]
        case .opus: return [8000, 12000, 16000, 24000, 48000]
        case .mp2: return [16000, 22050, 24000, 32000, 44100, 48000]
        case .dts: return [8000, 11025, 12000, 16000, 22050, 24000, 32000, 44100, 48000]
        case .vorbis: return [22050, 32000, 44100, 48000, 88200, 96000]
        default: return [8000, 11025, 12000, 16000, 22050, 24000, 32000, 44100, 48000, 64000, 88200, 96000]
        }
    }

    public func acceptsSampleRate(_ rate: Int) -> Bool {
        self == .pcm ? (1...Int(Int32.max)).contains(rate) : sampleRates.contains(rate)
    }

    var encoder: String {
        switch self {
        case .dts: return "dca"
        case .mp3: return "libmp3lame"
        case .opus: return "libopus"
        case .vorbis: return "libvorbis"
        default: return rawValue
        }
    }

    public var bitrates: [Int] {
        switch self {
        case .mp2: return [32, 48, 56, 64, 80, 96, 112, 128, 144, 160, 192, 224, 256, 320, 384]
        case .mp3: return [32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320]
        case .ac3: return [32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 384, 448, 512]
        case .dts: return [192, 256, 320, 384, 448, 512]
        default: return [64, 96, 128, 160, 192, 256, 320]
        }
    }

    public func acceptsBitrate(_ value: Int) -> Bool {
        guard supportsBitrate, (8...512).contains(value) else { return false }
        if [.mp2, .mp3, .ac3, .dts].contains(self) { return bitrates.contains(value) }
        return true
    }
}

public enum FrameFit: String, CaseIterable, Sendable, Codable {
    case fit, pad, crop
    public var displayName: String {
        switch self {
        case .fit: return "等比缩放"
        case .pad: return "完整显示 · 补黑边"
        case .crop: return "填满画面 · 居中裁剪"
        }
    }
}
public enum ResolutionPreset: String, CaseIterable, Sendable, Codable {
    case original, p480, p720, p1080, p2160, custom
    public var displayName: String {
        switch self {
        case .original: return "原始尺寸"
        case .p480: return "480p（854 × 480）"
        case .p720: return "720p（1280 × 720）"
        case .p1080: return "1080p（1920 × 1080）"
        case .p2160: return "2160p（3840 × 2160）"
        case .custom: return "自定义边界"
        }
    }
}
public enum AnimationMode: String, CaseIterable, Sendable, Codable {
    case preserve, firstFrame
    public var displayName: String { self == .preserve ? "保留动画" : "仅第一帧" }
}
public enum AnimationLoop: String, CaseIterable, Sendable, Codable {
    case forever, once
    public var displayName: String { self == .forever ? "无限循环" : "仅播放一次" }
}
public struct ConversionOptions: Sendable, Equatable, Codable {
    public var videoCodec: VideoCodec = .automatic
    public var audioCodec: AudioCodec = .automatic
    public var resolution: ResolutionPreset = .original
    public var customWidth: Int = 1920
    public var customHeight: Int = 1080
    public var videoBitrateKbps: Int? = nil
    public var videoRateMode: VideoRateMode? = nil
    public var videoCRF: Int? = nil
    public var videoCRFPreset: ConversionQuality? = nil
    public var audioBitrateKbps: Int? = nil
    public var frameRate: Int? = nil
    public var frameFit: FrameFit? = nil
    public var audioSampleRate: Int? = nil
    public var animationMode: AnimationMode = .preserve
    /// Source loop counts are not inherited. Decode one cycle and explicitly set output playback.
    public var animationLoop: AnimationLoop = .forever
    public var pcmBitDepth: Int = 16
    public init() {}

    public var resolvedVideoRateMode: VideoRateMode {
        videoRateMode ?? (videoBitrateKbps == nil ? .source : .abr)
    }

    public func resolvedVideoCRF(for codec: VideoCodec) -> Int? {
        if let preset = videoCRFPreset { return codec.recommendedCRF(for: preset) }
        return videoCRF
    }

    var bounds: (Int, Int)? {
        switch resolution {
        case .original: return nil
        case .p480: return (854, 480)
        case .p720: return (1280, 720)
        case .p1080: return (1920, 1080)
        case .p2160: return (3840, 2160)
        case .custom: return (customWidth, customHeight)
        }
    }
    /// Reject meaningful unsupported settings, rather than silently discarding them.
    public func validate(for format: OutputFormat) throws {
        func reject(_ message: String) throws { throw ConversionError.invalidOptions(message) }
        if videoCodec != .automatic && !format.allowedVideoCodecs.contains(videoCodec) { try reject("\(format.displayName) 不支持 \(videoCodec.displayName)。") }
        if audioCodec != .automatic && !format.allowedAudioCodecs.contains(audioCodec) { try reject("\(format.displayName) 不支持 \(audioCodec.displayName) 音频。") }
        let resolvedAudio = format.resolvedAudioCodec(options: self)
        if let audioSampleRate, !resolvedAudio.acceptsSampleRate(audioSampleRate) || format.kind == .image {
            try reject("此输出不支持所选音频采样率。")
        }
        if resolution == .custom && (!(1...16384).contains(customWidth) || !(1...16384).contains(customHeight)) { try reject("自定义宽高必须为 1–16384。") }
        if format.kind == .audio && resolution != .original { try reject("音频输出不支持分辨率。") }
        let video = format.resolvedVideoCodec(options: self)
        let rateMode = resolvedVideoRateMode
        if rateMode != .source && (format.kind != .video || !video.supports(rateMode)) {
            try reject("所选编码器不支持此视频码率模式。")
        }
        if rateMode == .abr || rateMode == .cbr {
            guard let bitrate = videoBitrateKbps, (1...500_000).contains(bitrate) else {
                try reject("视频码率必须为 1–500000 kbps。")
                return
            }
        }
        if rateMode == .crf {
            guard let range = video.crfRange, let crf = resolvedVideoCRF(for: video), range.contains(crf) else {
                try reject("CRF 数值超出所选编码器的范围。")
                return
            }
        }
        if let bitrate = audioBitrateKbps {
            if !resolvedAudio.acceptsBitrate(bitrate) { try reject("所选音频编码器不支持 \(bitrate) kbps。") }
            if resolvedAudio == .mp2, let rate = audioSampleRate, rate < 32000, bitrate > 160 { try reject("MP2 在低于 32 kHz 时最高支持 160 kbps。") }
        }
        if let fps = frameRate {
            if !(1...240).contains(fps) { try reject("帧率必须为 1–240 fps。") }
            if format.kind == .audio || (format.kind == .image && (!format.supportsAnimation || animationMode == .firstFrame)) { try reject("此输出不支持帧率。") }
            if format.resolvedVideoCodec(options: self).usesStandardFrameRate && ![24, 25, 30, 50, 60].contains(fps) {
                try reject("MPEG-1 / MPEG-2 支持 24、25、30、50 或 60 fps。")
            }
        }
        if ![16, 24, 32].contains(pcmBitDepth) { try reject("PCM 位深必须为 16、24 或 32。") }
        if pcmBitDepth != 16 && resolvedAudio != .pcm { try reject("位深仅适用于 PCM 编码。") }
        if animationMode != .preserve && format.kind != .image { try reject("动画模式仅适用于图片输出。") }
    }
}
