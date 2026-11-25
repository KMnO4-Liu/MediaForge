import Foundation
import MediaForgeCore

enum UtilityTool: CaseIterable, Hashable {
    case compressVideo, compressImage, extractAudio

    var title: String {
        switch self {
        case .compressVideo: return "压缩视频"
        case .compressImage: return "压缩图片"
        case .extractAudio: return "提取音频"
        }
    }

    var inputKind: MediaKind {
        switch self {
        case .compressVideo, .extractAudio: return .video
        case .compressImage: return .image
        }
    }

    var outputKind: MediaKind { self == .extractAudio ? .audio : inputKind }

    var initialFormat: OutputFormat {
        switch self {
        case .compressVideo: return .mp4
        case .compressImage: return .webp
        case .extractAudio: return .m4a
        }
    }

    var outputFormats: [OutputFormat] {
        if self == .compressImage { return [.webp, .jpeg, .avif, .png, .apng, .gif] }
        return OutputFormat.allCases.filter { $0.kind == outputKind }
    }

    var actionTitle: String { self == .extractAudio ? "开始提取" : "开始压缩" }
    var symbol: String {
        switch self {
        case .compressVideo: return "arrow.down.right.and.arrow.up.left"
        case .compressImage: return "arrow.down.right.and.arrow.up.left"
        case .extractAudio: return "waveform"
        }
    }

    var detail: String {
        switch self {
        case .compressVideo: return "调节编码质量以减小视频体积。"
        case .compressImage: return "以 WebP、JPEG 等格式减小图片体积。"
        case .extractAudio: return "从视频中导出第一条音轨。"
        }
    }
}

struct UtilityPreferences {
    var format: OutputFormat
    var quality: ConversionQuality = .compact
}

enum TrackTool: Hashable {
    case separate, merge

    var title: String { self == .separate ? "音视频分离" : "音视频合并" }
    var symbol: String { self == .separate ? "arrow.triangle.branch" : "arrow.triangle.merge" }
    var actionTitle: String { self == .separate ? "开始分离" : "开始合并" }
}

enum TaskFilter: CaseIterable {
    case all, failed, completed

    var title: String {
        switch self {
        case .all: return "任务列表"
        case .failed: return "失败任务"
        case .completed: return "已完成"
        }
    }

    var symbol: String {
        switch self {
        case .all: return "list.bullet.rectangle"
        case .failed: return "exclamationmark.circle"
        case .completed: return "checkmark.circle"
        }
    }

    func includes(_ status: JobStatus) -> Bool {
        switch self {
        case .all: return true
        case .failed: return status == .failed
        case .completed: return status == .completed
        }
    }
}

enum Workspace: Equatable {
    case home, category(MediaKind), conversion(MediaKind), utility(UtilityTool), tracks(TrackTool), tasks(TaskFilter)

    var mediaKind: MediaKind? {
        if case .conversion(let kind) = self { return kind }
        return nil
    }

    var acceptsFiles: Bool {
        switch self {
        case .home, .category, .conversion, .utility, .tracks: return true
        case .tasks: return false
        }
    }
}

struct TrackSelection {
    var video: URL?
    var audio: URL?
    var output: URL?
    var merge = MergeSettings()
}

struct MergeSettings {
    var edit = MergeEdit()
    var format: OutputFormat = .mp4
    var options = ConversionOptions()
}

struct TrackRun: Identifiable {
    let id = UUID()
    let createdAt = Date()
    let tool: TrackTool
    let video: URL
    let audio: URL?
    var merge = MergeSettings()
    var status: JobStatus = .running
    var processingPath: ProcessingPath?
    var output: URL?
    var error: String?
}

enum TaskEntry: Identifiable {
    case conversion(ConversionJob)
    case tracks(TrackRun)

    var id: UUID {
        switch self {
        case .conversion(let job): return job.id
        case .tracks(let run): return run.id
        }
    }

    var createdAt: Date {
        switch self {
        case .conversion(let job): return job.createdAt
        case .tracks(let run): return run.createdAt
        }
    }

    var status: JobStatus {
        switch self {
        case .conversion(let job): return job.status
        case .tracks(let run): return run.status
        }
    }
}
