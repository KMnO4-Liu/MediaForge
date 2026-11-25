import Foundation
import MediaForgeCore

/// Command-line-toolchain checks. Run `swift run MediaForgeChecks` without XCTest.
/// Set MEDIAFORGE_FFMPEG to additionally convert and decode all 16 real formats.
@main
struct MediaForgeChecks {
    static func main() async {
        do {
            try await fakeToolChecks()
            if let path = ProcessInfo.processInfo.environment["MEDIAFORGE_FFMPEG"], !path.isEmpty {
                try await realToolChecks(URL(fileURLWithPath: path))
            } else { print("SKIP real FFmpeg checks (set MEDIAFORGE_FFMPEG)") }
            print("PASS all MediaForge checks")
        } catch {
            print("FAIL \(error.localizedDescription)")
            exit(1)
        }
    }

    static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw CheckFailure(message) }
    }

    static func fakeToolChecks() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        for format in OutputFormat.allCases {
            try require(MediaFile.kind(for: fixture.url("input.\(format.fileExtension.uppercased())")) == format.kind, "format recognition: \(format)")
            for quality in ConversionQuality.allCases {
                let request = fixture.request(format: format, quality: quality)
                let args = FFmpegArguments.conversion(request, temporaryOutput: fixture.url("private.\(format.fileExtension)"))
                try require(format.requiredEncoders(options: request.options).allSatisfy(args.contains), "declared encoders: \(format)")
                try require(args.contains("-n") && !args.contains("-y"), "overwrite disabled")
                if format.kind == .image { try require(args.contains("-frames:v") == !format.supportsAnimation, "animation policy: \(format)") }
                if format.kind == .video { try require(args.contains("pad=ceil(iw/2)*2:ceil(ih/2)*2"), "odd dimension padding") }
                if format.kind == .audio { try require(args.contains("-vn"), "video to audio") }
            }
        }
        try optionChecks()
        print("PASS 20 formats × 3 qualities, declared encoders, animation policy, media recognition")

        let ffmpeg = try fixture.tool("ffmpeg", "for arg do last=\"$arg\"; done\nprintf 'out_time_us=5000000\\nprogress=continue\\n'\nprintf converted > \"$last\"")
        let probe = try fixture.tool("ffprobe", "printf '10\\n'")
        let discovered = try Toolchain.discover(customFFmpeg: ffmpeg)
        try require(discovered.ffmpeg == ffmpeg && discovered.ffprobe == probe, "custom and adjacent discovery")
        let link = fixture.url("ffmpeg-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: ffmpeg)
        try require(tryDiscover(link), "symlink executable discovery")
        let request = fixture.request()
        var invalidOptions = ConversionOptions(); invalidOptions.videoCodec = .prores
        let invalidRequest = ConversionRequest(input: request.input, output: fixture.url("invalid-options.mp4"), format: .mp4, quality: .balanced, options: invalidOptions)
        do {
            try await FFmpegRunner(toolchain: Toolchain(ffmpeg: fixture.url("must-not-launch"), ffprobe: nil)).convert(invalidRequest) { _ in }
            throw CheckFailure("runner did not reject incompatible codec before launching")
        } catch ConversionError.invalidOptions { }
        let progress = ProgressBox()
        let runner = FFmpegRunner(toolchain: discovered)
        try await runner.convert(request) { progress.append($0) }
        let result = try String(contentsOf: request.output, encoding: .utf8)
        try require(result == "converted", "successful atomic output")
        try require(progress.values.contains { $0.fraction == 0.5 } && progress.values.last?.fraction == 1, "duration progress")
        try fixture.requireNoTemporaryFiles()
        do { try await runner.convert(request) { _ in }; throw CheckFailure("existing output was accepted") }
        catch ConversionError.outputExists { }
        let preserved = try String(contentsOf: request.output, encoding: .utf8)
        try require(preserved == "converted", "existing output preservation")
        do {
            let same = ConversionRequest(input: request.input, output: request.input, format: .mp4, quality: .balanced)
            try await runner.convert(same) { _ in }; throw CheckFailure("same path accepted")
        } catch ConversionError.sameInputAndOutput { }
        do {
            let missing = ConversionRequest(input: fixture.url("missing"), output: fixture.url("new.mp4"), format: .mp4, quality: .balanced)
            try await runner.convert(missing) { _ in }; throw CheckFailure("missing input accepted")
        } catch ConversionError.inputMissing { }
        let unknown = ProgressBox()
        try await FFmpegRunner(toolchain: Toolchain(ffmpeg: ffmpeg, ffprobe: nil))
            .convert(fixture.request(name: "unknown")) { unknown.append($0) }
        try require(unknown.values.allSatisfy { $0.fraction == nil }, "unknown duration")
        print("PASS discovery, symlinks, progress, unknown duration, existing/same/missing input safety")

        let racingRequest = fixture.request(name: "racing")
        let racingTool = try fixture.tool("racing-tool", "for arg do last=\"$arg\"; done\nprintf user-data > '\(racingRequest.output.path)'\nprintf converted > \"$last\"")
        do {
            try await FFmpegRunner(toolchain: Toolchain(ffmpeg: racingTool, ffprobe: nil)).convert(racingRequest) { _ in }
            throw CheckFailure("racing destination overwritten")
        } catch ConversionError.outputExists { }
        let racingResult = try String(contentsOf: racingRequest.output, encoding: .utf8)
        try require(racingResult == "user-data", "racing output preservation")
        try fixture.requireNoTemporaryFiles()
        let noisy = try fixture.tool("noisy-tool", "for arg do last=\"$arg\"; done\nprintf partial > \"$last\"\ni=0\nwhile [ $i -lt 3000 ]; do\nprintf 'xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx\\n' >&2\nprintf 'out_time_us=1000000\\nprogress=continue\\n'\ni=$((i + 1))\ndone\nprintf FINAL_ERROR >&2\nexit 7")
        do {
            try await FFmpegRunner(toolchain: Toolchain(ffmpeg: noisy, ffprobe: nil)).convert(fixture.request(name: "failure")) { _ in }
            throw CheckFailure("failure accepted")
        } catch ConversionError.failed(let status, let log) {
            try require(status == 7 && log.utf8.count <= 65_536 && log.hasSuffix("FINAL_ERROR"), "bounded error tail")
        }
        try fixture.requireNoTemporaryFiles()
        print("PASS atomic no-overwrite race, simultaneous pipe draining, bounded failure log and cleanup")

        let stubborn = try fixture.tool("stubborn-tool", "for arg do last=\"$arg\"; done\nprintf partial > \"$last\"\ntrap '' TERM\nprintf 'out_time_us=1\\nprogress=continue\\n'\nwhile :; do :; done")
        let cancellationRunner = FFmpegRunner(toolchain: Toolchain(ffmpeg: stubborn, ffprobe: nil))
        let start = Date()
        do {
            try await cancellationRunner.convert(fixture.request(name: "cancelled")) {
                if $0.processedSeconds > 0 { cancellationRunner.cancel() }
            }
            throw CheckFailure("cancellation accepted as success")
        } catch is CancellationError { }
        try require(Date().timeIntervalSince(start) < 3, "prompt stubborn-process cancellation")
        try fixture.requireNoTemporaryFiles()
        let encoderTool = try fixture.tool("encoder-tool", "printf ' V..... libx264 encoder\\n A..... aac audio\\n'")
        let encoderRunner = FFmpegRunner(toolchain: Toolchain(ffmpeg: encoderTool, ffprobe: nil))
        for _ in 0..<25 {
            let task = Task { try await encoderRunner.availableEncoders() }
            task.cancel()
            do { _ = try await task.value; throw CheckFailure("pre-launch task cancellation ignored") } catch is CancellationError { }
        }
        let encoders = try await encoderRunner.availableEncoders()
        try require(encoders == ["libx264", "aac"], "runner reusable after cancellation / encoder parsing")
        print("PASS SIGTERM-resistant cancellation, cleanup, 25 pre-launch task cancellations, runner reuse")

        let runningTool = try fixture.tool("running-tool", "printf 'out_time_us=1\\nprogress=continue\\n'\nexec /bin/sleep 30")
        let runningRunner = FFmpegRunner(toolchain: Toolchain(ffmpeg: runningTool, ffprobe: nil))
        let (startedEvents, startedContinuation) = AsyncStream<Void>.makeStream()
        let runningTask = Task {
            try await runningRunner.convert(fixture.request(name: "task-cancelled")) {
                if $0.processedSeconds > 0 { startedContinuation.yield(()) }
            }
        }
        var iterator = startedEvents.makeAsyncIterator()
        _ = await iterator.next()
        do { _ = try await runningRunner.availableEncoders(); throw CheckFailure("concurrent use was accepted") }
        catch ConversionError.runnerBusy { }
        let taskCancelStart = Date()
        runningTask.cancel()
        do { _ = try await runningTask.value; throw CheckFailure("running task cancellation ignored") }
        catch is CancellationError { }
        startedContinuation.finish()
        try require(Date().timeIntervalSince(taskCancelStart) < 3, "running Task.cancel took too long")
        try fixture.requireNoTemporaryFiles()
        print("PASS running Task.cancel and concurrent-operation rejection")

        let sleepingTool = try fixture.tool("sleeping-tool", "exec /bin/sleep 30")
        let timedRunner = FFmpegRunner(toolchain: Toolchain(ffmpeg: sleepingTool, ffprobe: nil))
        let deadlineStart = Date()
        do { _ = try await timedRunner.availableEncoders(); throw CheckFailure("encoder timeout ignored") }
        catch ConversionError.toolTimedOut { }
        try require(Date().timeIntervalSince(deadlineStart) < 13, "encoder timeout took too long")
        let fallback = ProgressBox()
        let probeStart = Date()
        try await FFmpegRunner(toolchain: Toolchain(ffmpeg: ffmpeg, ffprobe: sleepingTool))
            .convert(fixture.request(name: "timed-probe")) { fallback.append($0) }
        try require(Date().timeIntervalSince(probeStart) < 18 && fallback.values.allSatisfy { $0.fraction == nil }, "probe timeout fallback")
        print("PASS encoder 10-second timeout and probe 15-second unknown-duration fallback")
    }

    static func tryDiscover(_ url: URL) -> Bool { (try? Toolchain.discover(customFFmpeg: url)) != nil }

    static func realToolChecks(_ tool: URL) async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let probe = tool.deletingLastPathComponent().appendingPathComponent("ffprobe")
        let runner = FFmpegRunner(toolchain: Toolchain(ffmpeg: tool, ffprobe: FileManager.default.isExecutableFile(atPath: probe.path) ? probe : nil))
        let encoders = try await runner.availableEncoders()
        for format in OutputFormat.allCases {
            try require(format.requiredEncoders.isSubset(of: encoders), "real tool missing encoders for \(format)")
        }
        let source = fixture.url("source.mkv")
        try run(tool, ["-hide_banner", "-loglevel", "error", "-nostdin", "-n", "-f", "lavfi", "-i", "testsrc=size=65x49:rate=12", "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=44100", "-t", "0.5", "-c:v", "ffv1", "-c:a", "pcm_s16le", source.path])
        let sourceImage = fixture.url("source.png")
        let sourceAudio = fixture.url("source.wav")
        try run(tool, ["-hide_banner", "-loglevel", "error", "-nostdin", "-n", "-i", source.path, "-frames:v", "1", "-update", "1", sourceImage.path])
        try run(tool, ["-hide_banner", "-loglevel", "error", "-nostdin", "-n", "-i", source.path, "-vn", "-c:a", "pcm_s16le", sourceAudio.path])
        for format in OutputFormat.allCases {
            let output = fixture.url("real.\(format.fileExtension)")
            let input = format.kind == .image ? sourceImage : format.kind == .audio ? sourceAudio : source
            let request = ConversionRequest(input: input, output: output, format: format, quality: .balanced)
            let progress = ProgressBox()
            try await runner.convert(request) { progress.append($0) }
            try require(!progress.values.isEmpty, "real conversion progress")
            try run(tool, ["-hide_banner", "-loglevel", "error", "-nostdin", "-i", output.path, "-f", "null", "-"])
            if format.kind == .image {
                let frames = fixture.url("\(format.rawValue)-frames.txt")
                try run(tool, ["-hide_banner", "-loglevel", "error", "-nostdin", "-n", "-i", output.path, "-map", "0:v:0", "-f", "framemd5", frames.path])
                let lines = try String(contentsOf: frames, encoding: .utf8).split(separator: "\n").filter { !$0.hasPrefix("#") }
                try require(lines.count == 1, "real single frame output: \(format)")
            }
            try fixture.requireNoTemporaryFiles()
            print("PASS real \(format.displayName): conversion + decode\(format.kind == .image ? " + exactly one frame" : "")")
        }
        let extracted = fixture.url("extracted.m4a")
        try await runner.convert(ConversionRequest(input: source, output: extracted, format: .m4a, quality: .high)) { _ in }
        try run(tool, ["-hide_banner", "-loglevel", "error", "-nostdin", "-i", extracted.path, "-f", "null", "-"])
        print("PASS real video → M4A audio extraction + decode")
        try await advancedChecks(tool: tool, probe: probe, fixture: fixture, source: source, runner: runner)
        // Audio-only inputs must produce a friendly FFmpeg failure for video outputs.
        let audio = fixture.url("real.wav")
        let invalid = ConversionRequest(input: audio, output: fixture.url("audio-to-video.mp4"), format: .mp4, quality: .balanced)
        do { try await runner.convert(invalid) { _ in }; throw CheckFailure("audio-to-video unexpectedly succeeded") }
        catch ConversionError.failed { }
        try fixture.requireNoTemporaryFiles()
        // A longer source ensures cancellation is exercised after real encoding starts.
        let longSource = fixture.url("long-source.mkv")
        try run(tool, ["-hide_banner", "-loglevel", "error", "-nostdin", "-n", "-f", "lavfi", "-i", "testsrc2=size=640x480:rate=30", "-t", "8", "-c:v", "ffv1", longSource.path])
        let knownDurationProgress = ProgressBox()
        let knownDurationOutput = fixture.url("known-duration.mp4")
        try await runner.convert(ConversionRequest(input: longSource, output: knownDurationOutput, format: .mp4, quality: .high)) { knownDurationProgress.append($0) }
        let fractions = knownDurationProgress.values.compactMap(\.fraction)
        try require(fractions.first == 0 && fractions.last == 1, "real ffprobe duration gives initial zero and final one")
        try require(fractions.contains { $0 > 0 && $0 < 1 }, "real ffprobe duration gives intermediate fraction: \(fractions)")
        print("PASS real ffprobe duration progress: \(fractions)")
        let cancelled = ConversionRequest(input: longSource, output: fixture.url("real-cancelled.mp4"), format: .mp4, quality: .high)
        let cancellationStart = Date()
        do {
            try await runner.convert(cancelled) { if $0.processedSeconds > 0 { runner.cancel() } }
            throw CheckFailure("real cancellation ignored")
        } catch is CancellationError { }
        try require(Date().timeIntervalSince(cancellationStart) < 8, "real cancellation was not prompt")
        try require(!FileManager.default.fileExists(atPath: cancelled.output.path), "cancelled output published")
        try fixture.requireNoTemporaryFiles()
        print("PASS real audio-to-video failure cleanup and running-encoder cancellation")
    }

    /// Test-only process helper sends both streams to files, so large diagnostics cannot deadlock.
    static func run(_ executable: URL, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = executable; process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.standardError
        try process.run(); process.waitUntilExit()
        if process.terminationStatus != 0 { throw CheckFailure("fixture/decode command exited \(process.terminationStatus)") }
    }
}

struct CheckFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

private final class ProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [ConversionProgress] = []
    func append(_ value: ConversionProgress) { lock.lock(); storage.append(value); lock.unlock() }
    var values: [ConversionProgress] { lock.lock(); defer { lock.unlock() }; return storage }
}

final class Fixture {
    let directory: URL
    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("MediaForgeChecks-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("input".utf8).write(to: url("input ; $(echo unsafe).mov"))
    }
    func url(_ name: String) -> URL { directory.appendingPathComponent(name) }
    func tool(_ name: String, _ body: String) throws -> URL {
        let path = url(name)
        try Data(("#!/bin/sh\n" + body + "\n").utf8).write(to: path)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path.path)
        return path
    }
    func request(name: String = "output", format: OutputFormat = .mp4, quality: ConversionQuality = .balanced) -> ConversionRequest {
        ConversionRequest(input: url("input ; $(echo unsafe).mov"), output: url("\(name).\(format.fileExtension)"), format: format, quality: quality)
    }
    func requireNoTemporaryFiles() throws {
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        try MediaForgeChecks.require(!names.contains { $0.hasPrefix(".mediaforge-") }, "temporary output leaked")
    }
    func cleanup() {
        guard directory.lastPathComponent.hasPrefix("MediaForgeChecks-"),
              directory.deletingLastPathComponent().standardizedFileURL == FileManager.default.temporaryDirectory.standardizedFileURL else { return }
        try? FileManager.default.removeItem(at: directory)
    }
}
