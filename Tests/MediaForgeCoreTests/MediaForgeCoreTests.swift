import XCTest
@testable import MediaForgeCore

final class MediaForgeCoreTests: XCTestCase {
    func testFormatsAndMediaRecognition() {
        XCTAssertEqual(OutputFormat.allCases.count, 20)
        for format in OutputFormat.allCases {
            XCTAssertEqual(MediaFile.kind(for: URL(fileURLWithPath: "file.\(format.fileExtension.uppercased())")), format.kind)
            XCTAssertFalse(format.requiredEncoder.isEmpty)
            XCTAssertEqual(format.displayName, format.rawValue.uppercased())
        }
        for ext in ["jpg", "tif", "HEIC", "avif"] { XCTAssertEqual(MediaFile.kind(for: URL(fileURLWithPath: "a.\(ext)")), .image) }
        for ext in ["opus", "aac", "aif"] { XCTAssertEqual(MediaFile.kind(for: URL(fileURLWithPath: "a.\(ext)")), .audio) }
        XCTAssertNil(MediaFile.kind(for: URL(fileURLWithPath: "a.txt")))
    }

    func testArgumentsUseDeclaredEncoderAndSingleFrameImages() {
        for format in OutputFormat.allCases {
            for quality in ConversionQuality.allCases {
                let request = ConversionRequest(input: URL(fileURLWithPath: "/tmp/input ; $(touch nope).mov"), output: URL(fileURLWithPath: "/tmp/final.\(format.fileExtension)"), format: format, quality: quality)
                let temporary = URL(fileURLWithPath: "/tmp/private.\(format.fileExtension)")
                let args = FFmpegArguments.conversion(request, temporaryOutput: temporary)
                for encoder in format.requiredEncoders(options: request.options) { XCTAssertTrue(args.contains(encoder)) }
                if format.kind == .video { XCTAssertTrue(args.contains("pad=ceil(iw/2)*2:ceil(ih/2)*2")) }
                XCTAssertEqual(args.last, temporary.path)
                XCTAssertTrue(args.contains(request.input.path))
                XCTAssertFalse(args.contains("-y"))
                XCTAssertTrue(args.contains("-n"))
                XCTAssertEqual(args[args.firstIndex(of: "-progress")! + 1], "pipe:1")
                if format.kind == .audio {
                    XCTAssertTrue(args.contains("-vn")); XCTAssertTrue(args.contains("0:a:0"))
                }
                if format.kind == .image {
                    if format.supportsAnimation { XCTAssertFalse(args.contains("-frames:v")) }
                    else { XCTAssertEqual(args[args.firstIndex(of: "-frames:v")! + 1], "1") }
                    XCTAssertTrue(args.contains("-an"))
                }
            }
        }
    }

    func testCRFQualityPresetsAndCustomValues() throws {
        let input = URL(fileURLWithPath: "/tmp/source.mov")
        let output = URL(fileURLWithPath: "/tmp/output.webm")
        var options = ConversionOptions()
        options.videoRateMode = .crf
        options.videoCRF = 19
        let savedCustom = try JSONEncoder().encode(options)
        let restoredCustom = try JSONDecoder().decode(ConversionOptions.self, from: savedCustom)
        XCTAssertNil(restoredCustom.videoCRFPreset)
        XCTAssertEqual(restoredCustom.resolvedVideoCRF(for: .vp9), 19)

        for (preset, h264, vp9) in [(ConversionQuality.high, 18, 24), (.balanced, 23, 32), (.compact, 28, 40)] {
            options.videoCRFPreset = preset
            XCTAssertEqual(options.resolvedVideoCRF(for: .h264), h264)
            try options.validate(for: .webm)
            let request = ConversionRequest(input: input, output: output, format: .webm, quality: .balanced, options: options)
            let arguments = FFmpegArguments.conversion(request, temporaryOutput: output)
            XCTAssertEqual(arguments.drop(while: { $0 != "-crf" }).dropFirst().first, String(vp9))
        }
        options.videoCRFPreset = nil
        options.videoCRF = 64
        XCTAssertThrowsError(try options.validate(for: .webm))
    }

    func testDiscoveryCustomAdjacentAndSearchPaths() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let ffmpeg = try fixture.tool("ffmpeg", "exit 0")
        let probe = try fixture.tool("ffprobe", "exit 0")
        let custom = try Toolchain.discover(customFFmpeg: ffmpeg)
        XCTAssertEqual(custom.ffmpeg, ffmpeg)
        XCTAssertEqual(custom.ffprobe, probe)
        let fromPath = try Toolchain.discover(customFFmpeg: nil, environment: ["PATH": fixture.directory.path], standardDirectories: [])
        XCTAssertEqual(fromPath.ffmpeg, ffmpeg)
        let standard = try Toolchain.discover(customFFmpeg: nil, environment: [:], standardDirectories: [fixture.directory.path])
        XCTAssertEqual(standard.ffprobe, probe)
        XCTAssertThrowsError(try Toolchain.discover(customFFmpeg: fixture.directory, environment: [:], standardDirectories: []))
        XCTAssertThrowsError(try Toolchain.discover(customFFmpeg: fixture.url("missing"), environment: [:], standardDirectories: []))
        XCTAssertThrowsError(try Toolchain.discover(customFFmpeg: nil, environment: [:], standardDirectories: []))
        let nonExecutable = fixture.url("not-executable")
        try Data("hello".utf8).write(to: nonExecutable)
        XCTAssertThrowsError(try Toolchain.discover(customFFmpeg: nonExecutable, environment: [:], standardDirectories: []))
    }

    func testDiscoveryAcceptsHomebrewStyleSymlinks() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let actual = try fixture.tool("real-ffmpeg", "exit 0")
        let link = fixture.url("ffmpeg")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: actual)
        XCTAssertEqual(try Toolchain.discover(customFFmpeg: link, environment: [:], standardDirectories: []).ffmpeg, link)
    }

    func testProbeIsOptional() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let ffmpeg = try fixture.tool("ffmpeg", "exit 0")
        XCTAssertNil(try Toolchain.discover(customFFmpeg: ffmpeg, environment: [:], standardDirectories: []).ffprobe)
    }

    func testProgressParserHandlesChunksLegacyUnitsAndUnknownDuration() {
        let progress = ProgressBox()
        let parser = ProgressParser(duration: 10) { progress.append($0) }
        parser.consume(Data("out_time_us=250".utf8))
        parser.consume(Data("0000\nprogress=continue\nout_time_ms=5000000\nprogress=continue\nout_time=00:00:15.0\nprogress=end".utf8))
        parser.finish()
        XCTAssertEqual(progress.values.map(\.fraction), [0.25, 0.5, 1])
        XCTAssertEqual(parser.processedSeconds, 15)
        let unknown = ProgressBox()
        let noDuration = ProgressParser(duration: nil) { unknown.append($0) }
        noDuration.consume(Data("out_time_us=N/A\nout_time_us=-1\nprogress=continue\n".utf8))
        XCTAssertNil(unknown.values.first?.fraction)
        XCTAssertEqual(unknown.values.first?.processedSeconds, 0)
    }

    func testEncoderParsing() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let tool = try fixture.tool("ffmpeg", "printf 'Encoders:\\n V..... = Video\\n V....D libx264 H.264\\n A..... aac AAC\\n A....D libmp3lame MP3\\n'\n")
        let runner = FFmpegRunner(toolchain: Toolchain(ffmpeg: tool, ffprobe: nil))
        let encoders = try await runner.availableEncoders()
        XCTAssertEqual(encoders, ["libx264", "aac", "libmp3lame"])
    }

    func testSuccessfulConversionUsesTemporaryAndReportsProgress() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let tool = try fixture.tool("ffmpeg", "for arg do last=\"$arg\"; done\nprintf 'out_time_us=5000000\\nprogress=continue\\n'\nprintf converted > \"$last\"\n")
        let probe = try fixture.tool("ffprobe", "printf '10\\n'")
        let progress = ProgressBox()
        let request = try fixture.request(inputName: "input ; $(echo unsafe).mov")
        let runner = FFmpegRunner(toolchain: Toolchain(ffmpeg: tool, ffprobe: probe))
        try await runner.convert(request) { progress.append($0) }
        XCTAssertEqual(try String(contentsOf: request.output, encoding: .utf8), "converted")
        XCTAssertTrue(progress.values.contains(where: { $0.fraction == 0.5 }))
        XCTAssertEqual(progress.values.last?.fraction, 1)
        XCTAssertEqual(try fixture.temporaryOutputs(), [])
    }

    func testNoProbeAndBrokenProbeStillConvertWithUnknownProgress() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let tool = try fixture.tool("ffmpeg", "for arg do last=\"$arg\"; done\nprintf 'out_time_us=1000000\\nprogress=end\\n'\nprintf ok > \"$last\"")
        for (index, probe) in [nil, fixture.url("missing-probe")].enumerated() {
            let progress = ProgressBox()
            let request = try fixture.request(outputName: "output\(index).mp4")
            try await FFmpegRunner(toolchain: Toolchain(ffmpeg: tool, ffprobe: probe)).convert(request) { progress.append($0) }
            XCTAssertTrue(progress.values.allSatisfy { $0.fraction == nil })
        }
    }

    func testFailedHardwareEncodingCleansPartialOutputAndRetriesInSoftware() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let tool = try fixture.tool("ffmpeg", """
            for arg do
                last="$arg"
                case "$arg" in
                    h264_videotoolbox) hardware=1 ;;
                    libx264) software=1 ;;
                esac
            done
            if [ "${hardware:-0}" = 1 ]; then
                printf partial > "$last"
                printf attempted > "${last%/*}/hardware-attempt"
                exit 1
            fi
            [ "${software:-0}" = 1 ] && [ ! -e "$last" ] || exit 2
            printf converted > "$last"
            """)
        let request = try fixture.request()
        let runner = FFmpegRunner(toolchain: Toolchain(ffmpeg: tool, ffprobe: nil),
                                  hardware: VideoHardwareCapabilities(encoders: ["h264_videotoolbox"]))
        let path = try await runner.convert(request) { _ in }
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.url("hardware-attempt").path))
        XCTAssertEqual(path, .software)
        XCTAssertEqual(try String(contentsOf: request.output, encoding: .utf8), "converted")
        XCTAssertEqual(try fixture.temporaryOutputs(), [])
    }

    func testInputValidationAndExistingOutputNeverModified() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let runner = FFmpegRunner(toolchain: Toolchain(ffmpeg: fixture.url("must-not-launch"), ffprobe: nil))
        let request = try fixture.request()
        try Data("original".utf8).write(to: request.output)
        do { try await runner.convert(request) { _ in }; XCTFail("Expected output exists") }
        catch ConversionError.outputExists { }
        XCTAssertEqual(try String(contentsOf: request.output, encoding: .utf8), "original")
        let same = ConversionRequest(input: request.input, output: request.input, format: .mp4, quality: .balanced)
        do { try await runner.convert(same) { _ in }; XCTFail("Expected same path") }
        catch ConversionError.sameInputAndOutput { }
        let missing = ConversionRequest(input: fixture.url("missing"), output: fixture.url("new.mp4"), format: .mp4, quality: .balanced)
        do { try await runner.convert(missing) { _ in }; XCTFail("Expected missing input") }
        catch ConversionError.inputMissing { }
        let alias = fixture.url("alias.mov")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: request.input)
        do { try await runner.convert(ConversionRequest(input: request.input, output: alias, format: .mp4, quality: .balanced)) { _ in }; XCTFail("Expected same resolved path") }
        catch ConversionError.sameInputAndOutput { }
    }

    func testMissingOutputDirectoryAndDanglingSymlinkAreRejected() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let request = try fixture.request()
        let runner = FFmpegRunner(toolchain: Toolchain(ffmpeg: fixture.url("must-not-launch"), ffprobe: nil))
        let absentDirectory = ConversionRequest(input: request.input, output: fixture.url("missing-directory/out.mp4"), format: .mp4, quality: .balanced)
        do { try await runner.convert(absentDirectory) { _ in }; XCTFail("Expected directory error") }
        catch ConversionError.outputDirectoryMissing { }
        try FileManager.default.createSymbolicLink(at: request.output, withDestinationURL: fixture.url("absent-target"))
        do { try await runner.convert(request) { _ in }; XCTFail("Expected existing symlink error") }
        catch ConversionError.outputExists { }
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: request.output.path), fixture.url("absent-target").path)
    }

    func testImmediateCancellationDoesNotLaunchOrPoisonRunner() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let tool = try fixture.tool("ffmpeg", "printf ' V..... libx264 encoder\\n'")
        let runner = FFmpegRunner(toolchain: Toolchain(ffmpeg: tool, ffprobe: nil))
        for _ in 0..<25 {
            let task = Task { try await runner.availableEncoders() }
            task.cancel()
            do { _ = try await task.value; XCTFail("Expected cancellation") } catch is CancellationError { }
        }
        let encoders = try await runner.availableEncoders()
        XCTAssertEqual(encoders, ["libx264"])
    }

    func testDestinationCreatedDuringConversionCannotBeOverwritten() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let request = try fixture.request()
        let tool = try fixture.tool("ffmpeg", "for arg do last=\"$arg\"; done\nprintf original > '\(request.output.path)'\nprintf converted > \"$last\"")
        let runner = FFmpegRunner(toolchain: Toolchain(ffmpeg: tool, ffprobe: nil))
        do { try await runner.convert(request) { _ in }; XCTFail("Expected exclusive move to fail") }
        catch ConversionError.outputExists { }
        XCTAssertEqual(try String(contentsOf: request.output, encoding: .utf8), "original")
        XCTAssertEqual(try fixture.temporaryOutputs(), [])
    }

    func testFailureDrainsBothPipesAndBoundsErrorLog() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let tool = try fixture.tool("ffmpeg", "for arg do last=\"$arg\"; done\nprintf partial > \"$last\"\ni=0\nwhile [ $i -lt 3000 ]; do\nprintf 'xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx\\n' >&2\nprintf 'out_time_us=1000000\\nprogress=continue\\n'\ni=$((i + 1))\ndone\nprintf FINAL_ERROR >&2\nexit 7")
        let request = try fixture.request()
        do { try await FFmpegRunner(toolchain: Toolchain(ffmpeg: tool, ffprobe: nil)).convert(request) { _ in }; XCTFail("Expected failure") }
        catch ConversionError.failed(let status, let log) {
            XCTAssertEqual(status, 7); XCTAssertLessThanOrEqual(log.utf8.count, 65_536); XCTAssertTrue(log.hasSuffix("FINAL_ERROR"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: request.output.path))
        XCTAssertEqual(try fixture.temporaryOutputs(), [])
    }

    func testCancelTerminatesStubbornProcessAndCleansTemporary() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let tool = try fixture.tool("ffmpeg", "for arg do last=\"$arg\"; done\nprintf partial > \"$last\"\ntrap '' TERM\nprintf 'out_time_us=1\\nprogress=continue\\n'\nwhile :; do :; done")
        let runner = FFmpegRunner(toolchain: Toolchain(ffmpeg: tool, ffprobe: nil))
        let request = try fixture.request()
        let started = expectation(description: "Process emitted progress")
        let task = Task {
            try await runner.convert(request) { if $0.processedSeconds > 0 { started.fulfill() } }
        }
        await fulfillment(of: [started], timeout: 5)
        let start = Date()
        runner.cancel()
        do { _ = try await task.value; XCTFail("Expected CancellationError") } catch is CancellationError { }
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
        XCTAssertFalse(FileManager.default.fileExists(atPath: request.output.path))
        XCTAssertEqual(try fixture.temporaryOutputs(), [])
        // Reuse is permitted and cancellation does not poison the next operation.
        let encoders = Task { try await runner.availableEncoders() }
        encoders.cancel()
        do { _ = try await encoders.value; XCTFail("Expected task cancellation") } catch is CancellationError { }
    }

    func testTaskCancellationAndBusyProtection() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let tool = try fixture.tool("ffmpeg", "printf 'out_time_us=1\\nprogress=continue\\n'\nexec /bin/sleep 30")
        let runner = FFmpegRunner(toolchain: Toolchain(ffmpeg: tool, ffprobe: nil))
        let started = expectation(description: "Started")
        let request = try fixture.request()
        let task = Task { try await runner.convert(request) { if $0.processedSeconds > 0 { started.fulfill() } } }
        await fulfillment(of: [started], timeout: 5)
        do { _ = try await runner.availableEncoders(); XCTFail("Expected busy") } catch ConversionError.runnerBusy { }
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancelled task") } catch is CancellationError { }
        XCTAssertEqual(try fixture.temporaryOutputs(), [])
    }
}

private final class ProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [ConversionProgress] = []
    func append(_ value: ConversionProgress) { lock.lock(); storage.append(value); lock.unlock() }
    var values: [ConversionProgress] { lock.lock(); defer { lock.unlock() }; return storage }
}

private final class Fixture {
    let directory: URL
    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("MediaForgeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    func url(_ name: String) -> URL { directory.appendingPathComponent(name) }
    func tool(_ name: String, _ body: String) throws -> URL {
        let path = url(name)
        try Data(("#!/bin/sh\n" + body + "\n").utf8).write(to: path)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path.path)
        return path
    }
    func request(inputName: String = "input.mov", outputName: String = "output.mp4") throws -> ConversionRequest {
        let input = url(inputName)
        try Data("input".utf8).write(to: input)
        return ConversionRequest(input: input, output: url(outputName), format: .mp4, quality: .balanced)
    }
    func temporaryOutputs() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasPrefix(".mediaforge-") }
    }
    func cleanup() {
        // Verify ownership before removing the isolated test fixture.
        guard directory.lastPathComponent.hasPrefix("MediaForgeTests-"),
              directory.deletingLastPathComponent().standardizedFileURL == FileManager.default.temporaryDirectory.standardizedFileURL else { return }
        try? FileManager.default.removeItem(at: directory)
    }
}
