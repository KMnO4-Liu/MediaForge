import Foundation
import Darwin

/// One operation at a time. Instances may be reused after success, failure, or cancellation.
public final class FFmpegRunner: @unchecked Sendable {
    private let toolchain: Toolchain
    private let hardware: VideoHardwareCapabilities
    private let lock = NSLock()
    private var active: OperationState?

    public init(toolchain: Toolchain, hardware: VideoHardwareCapabilities = VideoHardwareCapabilities()) {
        self.toolchain = toolchain
        self.hardware = hardware
    }

    public func cancel() {
        lock.lock(); let state = active; lock.unlock()
        state?.cancel()
    }

    public func availableEncoders() async throws -> Set<String> {
        try await perform { state in
            let result = try Self.execute(executable: self.toolchain.ffmpeg,
                                          arguments: ["-hide_banner", "-encoders"], state: state, timeout: 10)
            try state.checkCancellation()
            guard result.status == 0 else { throw ConversionError.failed(result.status, result.error) }
            let encoders = Self.parseEncoders(result.output)
            try state.commit { }
            return encoders
        }
    }

    public func supportsVideoToolboxDecoding() async throws -> Bool {
        try await perform { state in
            let result = try Self.execute(executable: self.toolchain.ffmpeg,
                                          arguments: ["-hide_banner", "-hwaccels"], state: state, timeout: 10)
            try state.commit { }
            return result.status == 0 && result.output.split(whereSeparator: \.isWhitespace).contains("videotoolbox")
        }
    }

    @discardableResult
    public func convert(_ request: ConversionRequest,
                        onProcessing: @escaping @Sendable (ProcessingPath) -> Void = { _ in },
                        onProgress: @escaping @Sendable (ConversionProgress) -> Void) async throws -> ProcessingPath {
        try await perform { state in
            try Self.validate(input: request.input, output: request.output)
            try request.options.validate(for: request.format)
            let temporary = request.output.deletingLastPathComponent()
                .appendingPathComponent(".mediaforge-\(UUID().uuidString).\(request.format.fileExtension)")
            // This exact random URL is the only path cleanup can remove.
            defer { if FileManager.default.fileExists(atPath: temporary.path) { try? FileManager.default.removeItem(at: temporary) } }
            var duration: Double?
            var copying = StreamCopy()
            var sourceBitrate: Int?
            var sourceCodec: String?
            if let probe = self.toolchain.ffprobe {
                do {
                    let probeStreams = (request.matchSource && request.format.kind != .image) ||
                        (request.format.kind == .video && (request.options.videoRateMode == .source || self.hardware.canDecode))
                    let fields = probeStreams
                        ? ["-show_entries", "format=duration:stream=codec_type,codec_name,bit_rate:stream_tags=BPS", "-of", "json"]
                        : ["-show_entries", "format=duration", "-of", "default=noprint_wrappers=1:nokey=1"]
                    let result = try Self.execute(executable: probe,
                        arguments: ["-v", "error"] + fields + [request.input.path], state: state, timeout: 15)
                    if result.status == 0 {
                        if probeStreams {
                            let metadata = try JSONDecoder().decode(SourceMetadata.self, from: Data(result.output.utf8))
                            duration = metadata.format?.duration.flatMap(Double.init)
                            copying = metadata.streamCopy(for: request)
                            sourceBitrate = metadata.videoBitrateKbps
                            sourceCodec = metadata.videoCodecName
                        } else {
                            duration = Double(result.output.trimmingCharacters(in: .whitespacesAndNewlines))
                        }
                        if let value = duration, !value.isFinite || value <= 0 { duration = nil }
                    }
                } catch is CancellationError { throw CancellationError() }
                catch { /* Probing is optional: conversion remains available without a duration. */ }
            }
            let inputTiming = AnimationTiming.read(request.input)
            if duration == nil, let inputTiming, inputTiming.total > 0 { duration = inputTiming.total }
            try state.checkCancellation()
            onProgress(ConversionProgress(fraction: duration == nil ? nil : 0, processedSeconds: 0))
            let parser = ProgressParser(duration: duration, callback: onProgress)
            func encode(copying: StreamCopy) throws -> (ProcessResult, ProcessingPath) {
                let acceleration = copying.video ? VideoAcceleration() :
                    self.acceleration(for: request.format, options: request.options, sourceCodec: sourceCodec)
                return try self.encode(acceleration: acceleration, outputs: [temporary], state: state,
                                       copyingVideo: copying.video, onProcessing: onProcessing, onOutput: { parser.consume($0) }) {
                    FFmpegArguments.conversion(request, temporaryOutput: temporary, copying: copying,
                                               sourceBitrate: sourceBitrate, acceleration: $0, inputTiming: inputTiming)
                }
            }
            var (result, path) = try encode(copying: copying)
            if result.status != 0 && copying.enabled {
                try state.checkCancellation()
                if FileManager.default.fileExists(atPath: temporary.path) {
                    try FileManager.default.removeItem(at: temporary)
                }
                (result, path) = try encode(copying: StreamCopy())
            }
            parser.finish()
            try state.checkCancellation()
            guard result.status == 0 else { throw ConversionError.failed(result.status, result.error) }
            guard let values = try? temporary.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true, (values.fileSize ?? 0) > 0 else { throw ConversionError.noOutput }
            if request.format == .webp, request.options.animationMode == .preserve,
               request.options.frameRate == nil, let timing = inputTiming, timing.total > 0 {
                try AnimationTiming.repairWebPDuration(temporary, totalDuration: timing.total)
            }
            try state.checkCancellation()
            // RENAME_EXCL is atomic and refuses an existing destination, including one
            // created during conversion. Unlike check-then-rename it cannot overwrite.
            try state.commit { try Self.publish(temporary, to: request.output) }
            onProgress(ConversionProgress(fraction: duration == nil ? nil : 1, processedSeconds: parser.processedSeconds))
            return path
        }
    }

    public func trackDuration(_ input: URL, video: Bool) async throws -> Double? {
        try await perform { state in
            try self.trackMetadata(input, video: video, state: state)?.duration
        }
    }

    public func audioSpectrum(_ input: URL) async throws -> Data {
        try await perform { state in
            let output = FileManager.default.temporaryDirectory.appendingPathComponent("MediaForge-Spectrum-\(UUID().uuidString).png")
            defer { try? FileManager.default.removeItem(at: output) }
            let result = try Self.execute(executable: self.toolchain.ffmpeg,
                arguments: ["-hide_banner", "-loglevel", "error", "-nostdin", "-n", "-i", input.path,
                            "-filter_complex", "[0:a:0]aformat=channel_layouts=mono,aresample=8000,showspectrumpic=s=1000x80:legend=0:color=viridis[spectrum]",
                            "-map", "[spectrum]", "-frames:v", "1", "-c:v", "png", "-update", "1", output.path],
                state: state, timeout: 30)
            try state.checkCancellation()
            guard result.status == 0 else { throw ConversionError.failed(result.status, result.error) }
            return try Data(contentsOf: output)
        }
    }

    private func trackMetadata(_ input: URL, video: Bool, state: OperationState) throws -> (duration: Double?, bitrate: Int?, codec: String?)? {
        guard let probe = toolchain.ffprobe else { return nil }
        do {
            let result = try Self.execute(executable: probe, arguments: ["-v", "error", "-select_streams", video ? "V:0" : "a:0",
                "-show_entries", "stream=duration,bit_rate,codec_name:stream_tags=BPS:format=duration", "-of", "json", input.path], state: state, timeout: 10)
            guard result.status == 0 else { return nil }
            let data = try JSONDecoder().decode(SourceMetadata.self, from: Data(result.output.utf8))
            guard let stream = data.streams.first else { return nil }
            let duration = [stream.duration, data.format?.duration].compactMap { $0.flatMap(Double.init) }.first { $0.isFinite && $0 > 0 }
            return (duration, stream.bitrateKbps, stream.codec_name)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return nil
        }
    }

    @discardableResult
    public func processTracks(_ request: TrackRequest,
                              onProcessing: @escaping @Sendable (ProcessingPath) -> Void = { _ in }) async throws -> ProcessingPath {
        try await perform { state in
            let video: URL
            let audio: URL?
            let destination: URL
            switch request {
            case let .separate(input, folder):
                video = input
                audio = nil
                destination = folder
            case let .merge(input, soundtrack, output, _, _, _, _):
                video = input
                audio = soundtrack
                destination = output
            }
            try Self.validate(input: video, output: destination)
            if let audio { try Self.validate(input: audio, output: destination) }
            let stage = destination.deletingLastPathComponent()
                .appendingPathComponent(".mediaforge-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false)
            defer { try? FileManager.default.removeItem(at: stage) }
            let outputs: [URL]
            let arguments: (VideoAcceleration) -> [String]
            let acceleration: VideoAcceleration
            switch request {
            case .separate:
                let picture = stage.appendingPathComponent("video.mp4")
                let soundtrack = stage.appendingPathComponent("audio.m4a")
                outputs = [picture, soundtrack]
                let sourceCodec = self.hardware.canDecode ? try self.trackMetadata(video, video: true, state: state)?.codec : nil
                acceleration = self.acceleration(for: .mp4, options: ConversionOptions(), sourceCodec: sourceCodec)
                arguments = { FFmpegArguments.trackSeparation(video: video, videoOutput: picture, audioOutput: soundtrack, acceleration: $0) }
            case let .merge(_, soundtrack, _, format, options, edit, previewStart):
                guard format.kind == .video else { throw ConversionError.invalidOptions("合并需要选择视频输出格式。") }
                try options.validate(for: format)
                try edit.validate()
                let pictureInfo = try self.trackMetadata(video, video: true, state: state)
                let soundInfo = edit != MergeEdit() ? try self.trackMetadata(soundtrack, video: false, state: state) : nil
                try edit.validate(videoDuration: pictureInfo?.duration, audioDuration: soundInfo?.duration)
                if let previewStart {
                    let end = edit.video.end ?? pictureInfo?.duration
                    guard previewStart.isFinite, (0...86400).contains(previewStart),
                          end.map({ previewStart < $0 - edit.video.start }) ?? true else {
                        throw ConversionError.invalidOptions("预览起点必须在裁剪后的视频范围内。")
                    }
                }
                let output = stage.appendingPathComponent("video").appendingPathExtension(format.fileExtension)
                outputs = [output]
                let duration = (edit.video.end ?? pictureInfo?.duration).map { $0 - edit.video.start }
                acceleration = self.acceleration(for: format, options: options, sourceCodec: pictureInfo?.codec)
                arguments = { FFmpegArguments.trackMerge(video: video, audio: soundtrack, output: output, format: format,
                    options: options, edit: edit, sourceBitrate: pictureInfo?.bitrate, duration: duration,
                    previewStart: previewStart, acceleration: $0) }
            }
            let (result, path) = try self.encode(acceleration: acceleration, outputs: outputs, state: state, onProcessing: onProcessing, arguments: arguments)
            try state.checkCancellation()
            guard result.status == 0 else {
                if result.error.contains("matches no streams") && audio == nil {
                    throw ConversionError.invalidOptions("分离需要源文件同时包含画面和音轨。")
                }
                throw ConversionError.failed(result.status, result.error)
            }
            for output in outputs {
                guard let values = try? output.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                      values.isRegularFile == true, (values.fileSize ?? 0) > 0 else { throw ConversionError.noOutput }
            }
            // Publish both separated files together by renaming their containing folder.
            let stagedResult = audio == nil ? stage : outputs[0]
            try state.commit { try Self.publish(stagedResult, to: destination) }
            return path
        }
    }

    private func acceleration(for format: OutputFormat, options: ConversionOptions, sourceCodec: String?) -> VideoAcceleration {
        guard format.kind == .video else { return VideoAcceleration() }
        let codec = format.resolvedVideoCodec(options: options)
        let decode = hardware.canDecode && ["h264", "hevc", "prores"].contains(sourceCodec ?? "")
        let encoder = options.resolvedVideoRateMode == .crf ? nil : codec.hardwareEncoder
        return VideoAcceleration(decode: decode, encoder: encoder.flatMap { hardware.encoders.contains($0) ? $0 : nil })
    }

    private func encode(acceleration: VideoAcceleration, outputs: [URL], state: OperationState, copyingVideo: Bool = false,
                        onProcessing: (ProcessingPath) -> Void, onOutput: ((Data) -> Void)? = nil,
                        arguments: (VideoAcceleration) -> [String]) throws -> (ProcessResult, ProcessingPath) {
        let path = acceleration.processingPath(copyingVideo: copyingVideo)
        onProcessing(path)
        let result = try Self.execute(executable: toolchain.ffmpeg, arguments: arguments(acceleration), state: state, onOutput: onOutput)
        guard acceleration.enabled && result.status != 0 else { return (result, path) }
        try state.checkCancellation()
        for output in outputs where FileManager.default.fileExists(atPath: output.path) {
            try FileManager.default.removeItem(at: output)
        }
        onProcessing(.software)
        let fallback = try Self.execute(executable: toolchain.ffmpeg, arguments: arguments(VideoAcceleration()), state: state, onOutput: onOutput)
        return (fallback, .software)
    }

    private func perform<T>(_ work: @escaping @Sendable (OperationState) throws -> T) async throws -> T {
        try Task.checkCancellation()
        let state = try begin()
        defer { end(state) }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    do { try state.checkCancellation(); continuation.resume(returning: try work(state)) }
                    catch {
                        // Cancellation wins over process launch, exit, or I/O errors.
                        if state.isCancelled { continuation.resume(throwing: CancellationError()) }
                        else { continuation.resume(throwing: error) }
                    }
                }
            }
        } onCancel: { state.cancel() }
    }

    private func begin() throws -> OperationState {
        lock.lock(); defer { lock.unlock() }
        guard active == nil else { throw ConversionError.runnerBusy }
        let state = OperationState(); active = state; return state
    }
    private func end(_ state: OperationState) {
        lock.lock(); defer { lock.unlock() }
        if active === state { active = nil }
    }

    private static func validate(input: URL, output: URL) throws {
        let resolvedInput = input.standardizedFileURL.resolvingSymlinksInPath()
        guard resolvedInput != output.standardizedFileURL.resolvingSymlinksInPath() else { throw ConversionError.sameInputAndOutput }
        guard input.isFileURL,
              let values = try? resolvedInput.resourceValues(forKeys: [.isRegularFileKey]), values.isRegularFile == true else {
            throw ConversionError.inputMissing(input)
        }
        // lstat also detects a dangling symlink, which fileExists intentionally follows.
        var info = stat()
        if lstat(output.path, &info) == 0 { throw ConversionError.outputExists(output) }
        let parent = output.deletingLastPathComponent()
        var directory: ObjCBool = false
        guard output.isFileURL, FileManager.default.fileExists(atPath: parent.path, isDirectory: &directory), directory.boolValue else {
            throw ConversionError.outputDirectoryMissing(parent)
        }
    }

    private static func publish(_ temporary: URL, to output: URL) throws {
        guard Darwin.renamex_np(temporary.path, output.path, UInt32(RENAME_EXCL)) != 0 else { return }
        let code = errno
        if code == EEXIST { throw ConversionError.outputExists(output) }
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [NSFilePathErrorKey: output.path])
    }

    static func parseEncoders(_ text: String) -> Set<String> {
        Set(text.split(separator: "\n").compactMap { line -> String? in
            let columns = line.split(whereSeparator: { $0.isWhitespace })
            guard columns.count >= 2, columns[0].count == 6,
                  let first = columns[0].first, "VAS".contains(first), columns[1] != "=" else { return nil }
            return String(columns[1])
        })
    }

    private struct ProcessResult { let status: Int32; let output: String; let error: String }

    private static func execute(executable: URL, arguments: [String], state: OperationState,
                                timeout: TimeInterval? = nil, onOutput: ((Data) -> Void)? = nil) throws -> ProcessResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments // Never use a shell or interpolate a command string.
        process.standardInput = FileHandle.nullDevice
        let stdout = Pipe(), stderr = Pipe()
        process.standardOutput = stdout; process.standardError = stderr
        let output = BoundedData(limit: 1_048_576), errors = BoundedData(limit: 65_536)
        let readers = DispatchGroup()
        do { try state.launch(process) }
        catch {
            try? stdout.fileHandleForWriting.close(); try? stderr.fileHandleForWriting.close()
            try? stdout.fileHandleForReading.close(); try? stderr.fileHandleForReading.close()
            throw error
        }
        let deadline = DispatchWorkItem { [weak state, weak process] in
            guard let process else { return }
            state?.timeout(process)
        }
        if let timeout { DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + timeout, execute: deadline) }
        defer { deadline.cancel() }
        // Close our copies so EOF arrives as soon as the child closes its descriptors.
        try? stdout.fileHandleForWriting.close(); try? stderr.fileHandleForWriting.close()
        for (pipe, buffer, callback) in [(stdout, output, onOutput), (stderr, errors, nil)] {
            readers.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                defer { try? pipe.fileHandleForReading.close(); readers.leave() }
                let descriptor = pipe.fileHandleForReading.fileDescriptor
                let flags = fcntl(descriptor, F_GETFL)
                _ = fcntl(descriptor, F_SETFL, flags | O_NONBLOCK)
                var bytes = [UInt8](repeating: 0, count: 16_384)
                while !state.isCancelled {
                    var event = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
                    let ready = Darwin.poll(&event, 1, 100)
                    if ready < 0 { if errno == EINTR { continue }; break }
                    if ready == 0 {
                        // Custom shell wrappers can leave descendants holding a pipe.
                        // Once the tracked child exits, do not wait indefinitely for EOF.
                        if !process.isRunning { break }
                        continue
                    }
                    let count = Darwin.read(descriptor, &bytes, bytes.count)
                    if count > 0 {
                        let data = Data(bytes.prefix(count))
                        buffer.append(data); callback?(data)
                    } else if count == 0 { break }
                    else if errno != EAGAIN && errno != EINTR { break }
                }
            }
        }
        process.waitUntilExit()
        readers.wait()
        let timedOut = state.detach(process)
        try state.checkCancellation()
        if timedOut { throw ConversionError.toolTimedOut(executable.lastPathComponent) }
        return ProcessResult(status: process.terminationStatus, output: output.string, error: errors.string)
    }
}

private struct SourceMetadata: Decodable {
    struct Stream: Decodable {
        let codec_name: String?
        let codec_type: String?
        let bit_rate: String?
        let duration: String?
        let tags: [String: String]?

        var bitrateKbps: Int? {
            for value in [bit_rate, tags?["BPS"]].compactMap({ $0 }) {
                if let bits = Int(value), (1...500_000_000).contains(bits) {
                    return max(1, (bits + 500) / 1000)
                }
            }
            return nil
        }
    }

    struct Container: Decodable {
        let duration: String?
    }

    let streams: [Stream]
    let format: Container?

    private var video: Stream? { streams.first { $0.codec_type == "video" } }
    var videoCodecName: String? { video?.codec_name }

    var videoBitrateKbps: Int? { video?.bitrateKbps }

    func streamCopy(for request: ConversionRequest) -> StreamCopy {
        let audio = streams.first { $0.codec_type == "audio" }?.codec_name
        let options = request.options
        let format = request.format
        let sourceCodec = video?.codec_name
        let compatible = format.allowedVideoCodecs.contains { $0 != .automatic && $0.rawValue == sourceCodec }
        let keepSourceCodec = request.matchSource && options.videoCodec == .automatic
        let sameCodec = options.videoRateMode == .source && format.resolvedVideoCodec(options: options).rawValue == sourceCodec
        let copyVideo = options.bounds == nil && options.frameRate == nil && options.resolvedVideoRateMode == .source &&
            compatible && (keepSourceCodec || sameCodec)
        let copyAudio = request.matchSource && options.audioBitrateKbps == nil && options.audioSampleRate == nil && options.audioCodec == .automatic &&
            audio.map { Self.compatibleAudioCodecs(for: format).contains($0) } == true
        return StreamCopy(video: copyVideo, audio: copyAudio)
    }

    private static func compatibleAudioCodecs(for format: OutputFormat) -> Set<String> {
        switch format {
        case .wav: return ["pcm_s16le", "pcm_s24le", "pcm_s32le"]
        case .aiff: return ["pcm_s16be", "pcm_s24be", "pcm_s32be"]
        default: return Set(format.allowedAudioCodecs.map(\.rawValue))
        }
    }
}

private final class OperationState: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    private var committed = false
    private var timedOut = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func checkCancellation() throws { if isCancelled { throw CancellationError() } }
    func launch(_ process: Process) throws {
        lock.lock(); defer { lock.unlock() }
        if cancelled { throw CancellationError() }
        self.process = process
        timedOut = false
        do { try process.run() } catch { self.process = nil; throw error }
    }
    func detach(_ process: Process) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if self.process === process { self.process = nil }
        return timedOut
    }
    func timeout(_ process: Process) {
        lock.lock(); defer { lock.unlock() }
        guard self.process === process, process.isRunning else { return }
        timedOut = true
        Darwin.kill(process.processIdentifier, SIGKILL)
    }
    func cancel() {
        lock.lock(); defer { lock.unlock() }
        guard !committed else { return }
        cancelled = true
        guard let process, process.isRunning else { return }
        process.terminate()
        // A stubborn encoder must not leave cancellation waiting indefinitely.
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.3) { [weak self, weak process] in
            guard let self, let process else { return }
            self.lock.lock(); defer { self.lock.unlock() }
            if self.process === process, process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
        }
    }
    func commit(_ action: () throws -> Void) throws {
        lock.lock(); defer { lock.unlock() }
        if cancelled { throw CancellationError() }
        try action()
        committed = true
    }
}

private final class BoundedData: @unchecked Sendable {
    private let limit: Int
    private var data = Data()
    init(limit: Int) { self.limit = limit }
    // One writer per instance; the owning DispatchGroup joins before reading.
    func append(_ chunk: Data) {
        data.append(chunk)
        if data.count > limit { data.removeFirst(data.count - limit) }
    }
    var string: String { String(decoding: data, as: UTF8.self) }
}

final class ProgressParser {
    private let duration: Double?
    private let callback: @Sendable (ConversionProgress) -> Void
    private var pending = Data()
    private(set) var processedSeconds: Double = 0
    init(duration: Double?, callback: @escaping @Sendable (ConversionProgress) -> Void) {
        self.duration = duration.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }; self.callback = callback
    }
    func consume(_ data: Data) {
        pending.append(data)
        while let newline = pending.firstIndex(of: 10) {
            let line = String(decoding: pending[..<newline], as: UTF8.self)
            pending.removeSubrange(...newline)
            parse(line)
        }
        // Malformed or hostile tools cannot grow an unbounded partial line.
        if pending.count > 65_536 { pending.removeAll(keepingCapacity: false) }
    }
    func finish() {
        if !pending.isEmpty { parse(String(decoding: pending, as: UTF8.self)); pending.removeAll() }
    }
    private func parse(_ line: String) {
        let parts = line.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "=", maxSplits: 1)
        guard parts.count == 2 else { return }
        switch parts[0] {
        case "out_time_us", "out_time_ms":
            // FFmpeg's legacy out_time_ms is also expressed in MICROseconds.
            if let value = Double(parts[1]), value.isFinite { processedSeconds = max(processedSeconds, value / 1_000_000, 0) }
        case "out_time":
            let components = parts[1].split(separator: ":").compactMap { Double($0) }
            if components.count == 3 {
                let seconds = components[0] * 3600 + components[1] * 60 + components[2]
                if seconds.isFinite { processedSeconds = max(processedSeconds, seconds, 0) }
            }
        case "progress":
            let fraction = duration.map { min(max(processedSeconds / $0, 0), 1) }
            callback(ConversionProgress(fraction: fraction, processedSeconds: processedSeconds))
        default: break
        }
    }
}
