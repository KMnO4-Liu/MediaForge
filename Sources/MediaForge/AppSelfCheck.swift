import Foundation
import Combine
import MediaForgeCore

@MainActor
enum AppSelfCheck {
    static func run() async throws -> [String: Any] {
        let suiteName = "dev.mediaforge.selfcheck.\(UUID().uuidString)"
        guard let preferences = UserDefaults(suiteName: suiteName) else { throw Failure("Cannot create isolated settings") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MediaForgeAppChecks-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            if suiteName.hasPrefix("dev.mediaforge.selfcheck.") { preferences.removePersistentDomain(forName: suiteName) }
            if root.lastPathComponent.hasPrefix("MediaForgeAppChecks-"),
               root.deletingLastPathComponent().resolvingSymlinksInPath() == FileManager.default.temporaryDirectory.resolvingSymlinksInPath() {
                try? FileManager.default.removeItem(at: root)
            }
        }
        // A stale v0.1 developer path must never break the new default engine.
        preferences.set("/nonexistent/old-developer-ffmpeg", forKey: "ffmpegPath")
        preferences.set(OutputFormat.mp3.rawValue, forKey: "videoFormat")
        let store = AppStore(preferences: preferences)
        for await checking in store.$checkingTools.values { if !checking { break } }
        guard let engine = store.toolchain else { throw Failure(store.toolError ?? "Engine discovery failed") }
        try require(store.customFFmpegPath.isEmpty, "Stale old engine override was used")
        if Bundle.main.bundleURL.pathExtension == "app" {
            try require(EngineLocator.isBundled(engine), "Packaged app used a non-bundled engine")
            try require(engine.ffprobe?.deletingLastPathComponent() == EngineLocator.helpersDirectory, "ffprobe is not bundled")
        }
        try require(OutputFormat.allCases.allSatisfy { store.supports($0) }, "Engine is missing a default output encoder")
        try require(store.outputDirectory == nil, "Fresh app must default to source-adjacent output")
        try require(store.selectedPreset == .source, "Fresh app did not select the source preset")
        try require(store.hardwareAccelerationEnabled, "Fresh app must enable hardware acceleration")
        try require(store.appearance == .system && store.appearance.nativeAppearance == nil, "Fresh app must follow system appearance")
        store.appearance = .dark
        try require(store.appearance.nativeAppearance?.name == .darkAqua && preferences.string(forKey: "appearance") == "dark",
                    "Dark appearance was not applied and saved")
        store.appearance = .light
        try require(store.appearance.nativeAppearance?.name == .aqua && preferences.string(forKey: "appearance") == "light",
                    "Light appearance was not applied and saved")
        store.appearance = .system
        try require(store.defaultFormat(for: .video) == .mp4, "Legacy audio output was retained as the video default")
        for kind in MediaKind.allCases {
            try require(store.formats(for: kind) == OutputFormat.allCases.filter { $0.kind == kind }, "Output format crossed a category")
        }
        store.setDefault(.gif, for: .video)
        try require(store.defaultFormat(for: .video) == .mp4, "Video default accepted an animation format")

        var custom = ConversionOptions()
        custom.videoCodec = .hevc; custom.audioCodec = .alac; custom.videoBitrateKbps = 2000
        custom.audioBitrateKbps = 192; custom.pcmBitDepth = 24; custom.animationMode = .firstFrame
        for format in OutputFormat.allCases { try store.effectiveOptions(for: format, from: custom).validate(for: format) }
        try require(store.effectiveOptions(for: .webm, from: custom).videoCodec == .automatic, "Incompatible codec did not fall back")
        try require(store.effectiveOptions(for: .m4a, from: custom).audioBitrateKbps == nil, "ALAC retained lossy bitrate")
        try require(store.effectiveOptions(for: .mp4, from: custom).animationMode == .preserve, "Animation-only control leaked into video")
        store.applyPreset(.small)
        try require(store.options.resolution == .p720 && store.quality == .compact, "Small preset mismatch")
        store.applyPreset(.balanced)

        let png = root.appendingPathComponent("picture.png")
        let animation = root.appendingPathComponent("animation.png") // APNG is frequently named .png.
        let audio = root.appendingPathComponent("sound.wav")
        let broken = root.appendingPathComponent("broken.mp4")
        try generate(engine.ffmpeg, ["-f", "lavfi", "-i", "testsrc=size=48x32:rate=5", "-t", "0.6", "-c:v", "apng", "-plays", "1", "-f", "apng", animation.path])
        try generate(engine.ffmpeg, ["-i", animation.path, "-frames:v", "1", "-update", "1", png.path])
        try generate(engine.ffmpeg, ["-f", "lavfi", "-i", "sine=frequency=440:duration=0.3", audio.path])
        try Data("deliberately invalid media".utf8).write(to: broken)
        let original = try Data(contentsOf: png)
        store.addFiles([broken, png, animation, audio, png])
        try require(store.jobs.count == 4, "Duplicate imports were not ignored")
        try require(store.jobs.first { $0.input == animation }?.format == .apng, "PNG-named APNG was not protected at import")
        store.setFormat(.mp3, for: store.jobs[0].id)
        store.setDefault(.mov, for: .video)
        try require(store.jobs[0].format == .mp3, "Changing the video default overwrote an explicit extraction")
        store.setFormat(.png, for: store.jobs[0].id)
        try require(store.jobs[0].format == .mp3, "Video accepted an unsupported static format")
        store.setFormat(.mov, for: store.jobs[0].id)

        store.workspace = .conversion(.audio)
        try require(store.selectedJob?.input == audio && store.pendingCount == 1, "Audio category did not scope the selection and count")
        try require(store.canStart, "Fresh app requires unexpected manual setup")
        store.start()
        for await running in store.$isRunning.values { if !running { break } }
        try require(store.completedCount == 1 && !store.canStart, "Audio category did not finish its queue")
        try require(store.jobs.filter { $0.kind != .audio }.allSatisfy { $0.status == .waiting }, "A filtered batch processed hidden jobs")
        for kind in [MediaKind.video, .image] {
            store.workspace = .conversion(kind)
            store.start()
            for await running in store.$isRunning.values { if !running { break } }
        }
        try require(store.jobs[0].status == .failed, "Invalid input did not fail")
        try require(store.jobs.filter { $0.status == .completed }.count == 3, "Category conversion failed: \(store.jobs.compactMap(\.error).joined(separator: " | "))")
        let outputDirectory = root.appendingPathComponent("MediaForge 输出", isDirectory: true)
        try require(store.jobs.filter { $0.status == .completed }.allSatisfy { $0.output?.deletingLastPathComponent() == outputDirectory }, "Default output location mismatch")
        try require(try Data(contentsOf: png) == original, "Original input was modified")
        for job in store.jobs where job.status == .completed {
            guard let output = job.output else { throw Failure("Completed job has no output") }
            try generate(engine.ffmpeg, ["-i", output.path, "-f", "null", "-"])
            try require(job.settingsSummary != nil, "Job lost its applied settings snapshot")
        }

        let firstPicture = store.jobs.first { $0.input == png }!
        let firstOutput = firstPicture.output!
        let firstResult = try Data(contentsOf: firstOutput)
        store.remove(firstPicture.id)
        store.addFiles([png])
        store.start()
        for await running in store.$isRunning.values { if !running { break } }
        guard let repeated = store.jobs.first(where: { $0.input == png }), repeated.status == .completed, let repeatedOutput = repeated.output else { throw Failure("Repeated conversion failed") }
        try require(repeatedOutput != firstOutput && repeatedOutput.lastPathComponent.contains("_2"), "Output collision was not numbered")
        try require(try Data(contentsOf: firstOutput) == firstResult, "Existing result was overwritten")

        // Explicit animation loss must require acknowledgement, not silently flatten.
        let animatedJob = store.jobs.first { $0.input == animation }!
        store.remove(animatedJob.id)
        store.addFiles([animation])
        let pending = store.jobs.first { $0.input == animation }!
        store.setFormat(.png, for: pending.id)
        store.workspace = .conversion(.image)
        store.start()
        try require(store.showAnimationLossWarning && !store.isRunning, "Animation loss did not ask for confirmation")
        store.workspace = .conversion(.audio)
        store.confirmFirstFrameConversion()
        for await running in store.$isRunning.values { if !running { break } }
        try require(store.jobs.first { $0.id == pending.id }?.status == .completed, "Confirmed first-frame conversion failed")

        let video = root.appendingPathComponent("original.mp4")
        let avi = root.appendingPathComponent("original.AVI")
        try generate(engine.ffmpeg, ["-f", "lavfi", "-i", "testsrc=size=48x32:rate=5", "-t", "0.4", "-c:v", "libx264", "-pix_fmt", "yuv420p", video.path])
        try generate(engine.ffmpeg, ["-f", "lavfi", "-i", "testsrc=size=48x32:rate=5", "-t", "0.4", "-c:v", "mpeg4", avi.path])
        store.workspace = .conversion(.video)
        store.addFiles([video])
        guard let videoJob = store.jobs.first(where: { $0.input == video }) else { throw Failure("MP4 did not import") }
        store.setFormat(.mov, for: videoJob.id)
        for preset in [QuickPreset.small, .highQuality, .balanced, .source] {
            store.applyPreset(preset)
            try require(store.jobs.first { $0.id == videoJob.id }?.format == .mov, "A preset changed the selected output format")
        }
        store.setDefault(.webm, for: .video)
        try require(store.selectedPreset == .source, "Changing an output format changed the preset")
        store.addFiles([avi])
        store.setFormat(.mov, for: videoJob.id)
        try require(store.selectedPreset == .source, "Changing a job format changed the preset")
        store.start()
        for await running in store.$isRunning.values { if !running { break } }
        guard let mov = store.jobs.first(where: { $0.input == video })?.output, mov.pathExtension == "mov",
              let webm = store.jobs.first(where: { $0.input == avi })?.output, webm.pathExtension == "webm" else {
            throw Failure("The source preset did not export both selected formats: \(store.jobs.compactMap(\.error).joined(separator: " | "))")
        }
        let sourceHash = root.appendingPathComponent("source.hash")
        let movHash = root.appendingPathComponent("mov.hash")
        try generate(engine.ffmpeg, ["-i", video.path, "-map", "0:v:0", "-c", "copy", "-f", "hash", sourceHash.path])
        try generate(engine.ffmpeg, ["-i", mov.path, "-map", "0:v:0", "-c", "copy", "-f", "hash", movHash.path])
        try require(try Data(contentsOf: sourceHash) == Data(contentsOf: movHash), "Compatible video was re-encoded")
        try generate(engine.ffmpeg, ["-i", webm.path, "-f", "null", "-"])
        try await checkTrackWorkspaces(store, engine: engine, root: root, silentVideo: video, soundtrack: audio)
        try await checkUtilityWorkspaces(store, engine: engine, video: video, picture: png)
        try await checkParameterEditing(store, engine: engine, root: root, video: video)
        try await checkVideoRateControl(engine, root: root)
        let hardwarePaths = try await checkHardwarePaths(store, engine: engine, root: root)

        let unexpectedTemporary = try FileManager.default.contentsOfDirectory(atPath: outputDirectory.path).filter { $0.hasPrefix(".mediaforge-") }
        try require(unexpectedTemporary.isEmpty, "Temporary outputs leaked")
        return [
            "status": "PASS", "bundled": EngineLocator.isBundled(engine), "videoRateControl": "source, CBR, ABR, CRF",
            "mergeTimeline": "trims, positive/negative offset, edge and playhead snapping, inline preview media, spectrum PNG, MKV/WebM format and output settings",
            "ffmpeg": engine.ffmpeg.path, "ffprobe": engine.ffprobe?.path ?? "none",
            "videoHardwarePaths": hardwarePaths,
            "defaultOutputFormats": OutputFormat.allCases.count,
            "checks": ["stale-settings migration", "bundled engine discovery", "all default encoders", "category-specific defaults and job formats", "category-scoped conversion", "mixed-container option normalization", "quick presets", "source preset keeps selected formats and preserves compatible streams", "duplicate import", "PNG-named APNG protection", "no-setup start", "failure isolation", "3 category conversions + decode", "source preservation", "numbered collision output", "per-job parameter editing and frame fit", "expanded video and audio codecs", "animation-loss confirmation", "atomic track separation", "soundtrack replacement and duration", "independent compression and audio extraction tools", "task filtering, retry and retained results", "temporary cleanup"]
        ]
    }

    private static func checkHardwarePaths(_ store: AppStore, engine: Toolchain, root: URL) async throws -> [String: String] {
        guard let probe = engine.ffprobe else { throw Failure("Hardware checks require ffprobe") }
        let input = root.appendingPathComponent("hardware-source.mp4")
        try generate(engine.ffmpeg, ["-f", "lavfi", "-i", "testsrc2=size=320x180:rate=25:duration=0.6",
                                     "-c:v", "libx264", "-pix_fmt", "yuv420p", input.path])
        let runner = FFmpegRunner(toolchain: engine, hardware: store.videoHardware)
        var paths: [String: String] = [:]
        for (codec, format, expected) in [(VideoCodec.h264, OutputFormat.mp4, "h264"), (.hevc, .mp4, "hevc"), (.prores, .mov, "prores")] {
            var options = ConversionOptions()
            options.videoCodec = codec
            let output = root.appendingPathComponent("hardware-\(expected).\(format.fileExtension)")
            let path = try await runner.convert(ConversionRequest(input: input, output: output, format: format,
                                                                   quality: .balanced, options: options)) { _ in }
            try require(try probeValue(probe, output, entries: "stream=codec_name") == expected, "Hardware candidate produced the wrong codec")
            try generate(engine.ffmpeg, ["-i", output.path, "-f", "null", "-"])
            paths[expected] = String(describing: path)
        }
        var crf = ConversionOptions()
        crf.videoRateMode = .crf
        crf.videoCRF = 23
        let crfOutput = root.appendingPathComponent("hardware-crf.mp4")
        let crfPath = try await runner.convert(ConversionRequest(input: input, output: crfOutput, format: .mp4,
                                                                 quality: .balanced, options: crf)) { _ in }
        try require(crfPath == .hardwareDecoding || crfPath == .software, "CRF must retain software encoding")
        paths["crf"] = String(describing: crfPath)

        store.hardwareAccelerationEnabled = false
        defer { store.hardwareAccelerationEnabled = true }
        let softwareOutput = root.appendingPathComponent("software-only.mp4")
        let disabledPath = try await FFmpegRunner(toolchain: engine, hardware: store.videoHardware)
            .convert(ConversionRequest(input: input, output: softwareOutput, format: .mp4, quality: .balanced)) { _ in }
        try require(disabledPath == .software, "The hardware acceleration switch did not disable hardware processing")
        paths["disabled"] = String(describing: disabledPath)
        return paths
    }

    private static func checkVideoRateControl(_ engine: Toolchain, root: URL) async throws {
        guard let probe = engine.ffprobe else { throw Failure("Rate control checks require ffprobe") }
        let input = root.appendingPathComponent("bitrate-source.mp4")
        try generate(engine.ffmpeg, ["-f", "lavfi", "-i", "color=size=128x96:rate=25:duration=3",
                                     "-c:v", "libx264", "-b:v", "250k", "-minrate", "250k", "-maxrate", "250k",
                                     "-bufsize", "500k", "-x264-params", "filler=1", input.path])
        let runner = FFmpegRunner(toolchain: engine)
        var sizes: [VideoRateMode: Int] = [:]
        for mode in VideoRateMode.allCases {
            var options = ConversionOptions()
            options.videoRateMode = mode
            if mode == .cbr || mode == .abr { options.videoBitrateKbps = 250 }
            if mode == .crf { options.videoCRF = 23 }
            let output = root.appendingPathComponent("rate-\(mode.rawValue).mp4")
            try await runner.convert(ConversionRequest(input: input, output: output, format: .mp4,
                                                       quality: .balanced, options: options)) { _ in }
            try require(try probeValue(probe, output, entries: "stream=codec_name") == "h264", "Rate control produced an invalid stream")
            sizes[mode] = try output.resourceValues(forKeys: [.fileSizeKey]).fileSize
            if mode == .source {
                let sourceRate = try probeValue(probe, input, entries: "stream=bit_rate")
                let outputRate = try probeValue(probe, output, entries: "stream=bit_rate")
                try require(sourceRate == outputRate, "Source mode changed the compatible video bitrate")
            }
        }
        guard let cbr = sizes[.cbr], let abr = sizes[.abr], let crf = sizes[.crf] else { throw Failure("Rate control output size missing") }
        try require(cbr > abr * 2 && cbr > crf * 2, "H.264 CBR did not sustain the selected rate on static frames")
    }

    private static func checkParameterEditing(_ store: AppStore, engine: Toolchain, root: URL, video: URL) async throws {
        guard let probe = engine.ffprobe, let merged = store.trackSelection(for: .merge).output else {
            throw Failure("Missing parameter test fixtures")
        }
        store.workspace = .conversion(.video)
        let second = root.appendingPathComponent("parameter-control.mp4")
        try FileManager.default.copyItem(at: video, to: second)
        store.addFiles([merged, second])
        guard let job = store.visibleJobs.first(where: { $0.input == merged }),
              let control = store.visibleJobs.first(where: { $0.input == second }) else { throw Failure("Parameter fixtures did not import") }
        store.setFormat(.mkv, for: job.id)
        guard let editable = store.visibleJobs.first(where: { $0.id == job.id }) else { throw Failure("Missing editable task") }
        store.editParameters(for: editable)
        guard let target = store.parameterEditor else { throw Failure("Parameters did not open") }
        var settings = target.initial
        settings.options.videoCodec = .mpeg2video
        settings.options.audioCodec = .ac3
        settings.options.audioSampleRate = 48000
        settings.options.resolution = .custom
        settings.options.customWidth = 80
        settings.options.customHeight = 64
        settings.options.frameFit = .pad
        settings.matchSource = false
        try store.saveParameters(settings, for: target)
        store.parameterEditor = nil
        try require(store.selectedPreset == .source && store.encoding(for: control).options.videoCodec == .automatic,
                    "Editing one job changed the preset or another job")
        store.start()
        for await running in store.$isRunning.values { if !running { break } }
        guard let exported = store.jobs.first(where: { $0.id == job.id })?.output else {
            throw Failure(store.jobs.first(where: { $0.id == job.id })?.error ?? "Parameterized export failed")
        }
        try require(try probeValue(probe, exported, entries: "stream=codec_name") == "mpeg2video,ac3", "Job ignored its saved codecs")
        try require(try probeValue(probe, exported, entries: "stream=width,height,sample_rate") == "80,64,48000", "Job ignored canvas size or sample rate")
        let runner = FFmpegRunner(toolchain: engine)
        let combinations: [(OutputFormat, VideoCodec, AudioCodec, String)] = [
            (.mkv, .mpeg1video, .dts, "mpeg1video,dts"),
            (.mkv, .mpeg2video, .eac3, "mpeg2video,eac3"),
            (.mp4, .mpeg4, .mp3, "mpeg4,mp3"),
            (.mov, .mpeg4, .ac3, "mpeg4,ac3"),
            (.mp4, .h264, .eac3, "h264,eac3"),
            (.mov, .h264, .pcm, "h264,pcm_s24le"),
            (.mp4, .h264, .pcm, "h264,pcm_s24le"),
            (.wav, .automatic, .pcm, "pcm_s24le"),
            (.mkv, .h264, .flac, "h264,flac"),
            (.mkv, .h264, .mp2, "h264,mp2"),
            (.webm, .vp9, .vorbis, "vp9,vorbis"),
            (.ogg, .automatic, .opus, "opus")
        ]
        for (index, combination) in combinations.enumerated() {
            let (format, videoCodec, audioCodec, streams) = combination
            var options = ConversionOptions()
            options.videoCodec = videoCodec
            options.audioCodec = audioCodec
            options.audioSampleRate = audioCodec == .pcm ? (format == .wav ? 50123 : 96000) : 48000
            if audioCodec == .pcm { options.pcmBitDepth = 24 }
            let output = root.appendingPathComponent("encoder-\(index).\(format.fileExtension)")
            do {
                try await runner.convert(ConversionRequest(input: merged, output: output, format: format,
                                                           quality: .balanced, options: options)) { _ in }
            } catch {
                throw Failure("\(format.displayName) / \(videoCodec.displayName) / \(audioCodec.displayName): \(error.localizedDescription)")
            }
            try require(try probeValue(probe, output, entries: "stream=codec_name") == streams, "Unexpected codecs for \(output.lastPathComponent)")
            if audioCodec == .pcm {
                try require(try probeValue(probe, output, entries: "stream=sample_rate") == String(options.audioSampleRate ?? 0),
                            "PCM sample rate was not applied")
            }
            try generate(engine.ffmpeg, ["-i", output.path, "-f", "null", "-"])
        }
    }

    private static func checkUtilityWorkspaces(_ store: AppStore, engine: Toolchain, video: URL, picture: URL) async throws {
        guard let merged = store.trackSelection(for: .merge).output,
              let probe = engine.ffprobe else { throw Failure("Utility fixtures missing") }
        let defaults = [store.defaultFormat(for: .video), store.defaultFormat(for: .image), store.defaultFormat(for: .audio)]
        let fixtures: [(UtilityTool, URL, OutputFormat, String)] = [
            (.compressVideo, video, .mp4, "video"),
            (.compressImage, picture, .webp, "video"),
            (.extractAudio, merged, .flac, "audio")
        ]
        for (tool, input, format, streamType) in fixtures {
            store.workspace = .utility(tool)
            store.setUtilityFormat(format, for: tool)
            store.importDroppedFiles([input, input])
            try require(store.visibleJobs.count == 1 && store.visibleJobs[0].format == format, "Utility input was routed incorrectly")
            store.start()
            for await running in store.$isRunning.values { if !running { break } }
            guard let output = store.visibleJobs.first?.output else {
                throw Failure(store.visibleJobs.first?.error ?? "Utility returned no output")
            }
            try require(output.pathExtension == format.fileExtension, "Utility changed the selected format")
            try require(try probeValue(probe, output, entries: "stream=codec_type") == streamType, "Unexpected utility output tracks")
            try generate(engine.ffmpeg, ["-i", output.path, "-f", "null", "-"])
            let id = store.visibleJobs[0].id
            store.clearFinished()
            try require(store.visibleJobs.isEmpty && store.tasks(in: .completed).contains { $0.id == id },
                        "Clearing a queue also removed task history")
        }
        try require(defaults == [store.defaultFormat(for: .video), store.defaultFormat(for: .image), store.defaultFormat(for: .audio)],
                    "Utility settings changed the conversion defaults")
        let failed = store.tasks(in: .failed)
        try require(failed.contains { if case .tracks = $0 { return true }; return false }, "Track failures were missing from the task center")
        guard let conversion = failed.first(where: { if case .conversion = $0 { return true }; return false }) else {
            throw Failure("Conversion failure was missing from the task center")
        }
        store.openTask(conversion, retry: true)
        try require(store.workspace == .conversion(.video) && store.selectedJob?.id == conversion.id && store.selectedJob?.status == .waiting,
                    "Retry did not return the task to its original queue")
        try require(!store.tasks(in: .failed).contains { $0.id == conversion.id }, "Retried task still appeared as failed")
    }

    private static func checkTrackWorkspaces(_ store: AppStore, engine: Toolchain, root: URL, silentVideo: URL, soundtrack: URL) async throws {
        let edge = TimelineSnap.nearest(position: 1.94, edges: [0, 2], anchors: [4], within: 0...3, tolerance: 0.08)
        try require(edge?.position == 2 && edge?.guide == 4, "Trailing track edge did not snap")
        let zoomed = TimelineSnap.nearest(position: 1.94, edges: [0, 2], anchors: [4], within: 0...3, tolerance: 0.02)
        try require(zoomed == nil, "Snap tolerance did not shrink with zoom")
        let playhead = TimelineSnap.nearest(position: 1.03, edges: [0], anchors: [1], within: 0...3, tolerance: 0.08)
        try require(playhead?.position == 1, "Playhead did not snap to the clip edge")
        let excluded = TimelineSnap.nearest(position: 1.03, edges: [0], anchors: [1], within: 1.01...3, tolerance: 0.08)
        try require(excluded == nil, "Snap moved the clip outside its valid range")
        guard let probe = engine.ffprobe else { throw Failure("Track checks require ffprobe") }
        let withAudio = root.appendingPathComponent("tracks.mp4")
        try generate(engine.ffmpeg, ["-f", "lavfi", "-i", "testsrc=size=48x32:rate=10", "-f", "lavfi", "-i", "anullsrc=r=44100:cl=mono",
                                     "-t", "1.2", "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac", withAudio.path])
        store.workspace = .tracks(.separate)
        store.importDroppedFiles([silentVideo])
        store.start()
        for await running in store.$isRunning.values { if !running { break } }
        try require(store.trackSelection(for: .separate).output == nil && store.notice != nil, "Silent input produced a partial split")
        store.notice = nil
        store.importDroppedFiles([withAudio])
        store.start()
        for await running in store.$isRunning.values { if !running { break } }
        guard let split = store.trackSelection(for: .separate).output else { throw Failure(store.notice ?? "Split produced no output") }
        let splitVideo = split.appendingPathComponent("video.mp4")
        let splitAudio = split.appendingPathComponent("audio.m4a")
        try require(try probeValue(probe, splitVideo, entries: "stream=codec_type") == "video", "Split video still contained audio")
        try require(try probeValue(probe, splitAudio, entries: "stream=codec_type") == "audio", "Split audio still contained video")
        try generate(engine.ffmpeg, ["-i", splitVideo.path, "-f", "null", "-"])
        try generate(engine.ffmpeg, ["-i", splitAudio.path, "-f", "null", "-"])
        store.start()
        for await running in store.$isRunning.values { if !running { break } }
        try require(store.trackSelection(for: .separate).output?.lastPathComponent == "tracks_separated_2", "Split collision was not numbered")

        store.workspace = .tracks(.merge)
        store.importDroppedFiles([withAudio])
        try require(!store.canStartTracks(.merge), "Merge enabled without a soundtrack")
        store.importDroppedFiles([soundtrack])
        try require(store.canStartTracks(.merge), "Merge did not accept a video and an audio input")
        store.start()
        for await running in store.$isRunning.values { if !running { break } }
        guard let merged = store.trackSelection(for: .merge).output else { throw Failure(store.notice ?? "Merge produced no output") }
        try require(try probeValue(probe, merged, entries: "stream=codec_type") == "video,audio", "Merged output lacked exactly one video and one audio stream")
        let duration = try probeValue(probe, merged, entries: "format=duration")
        try require(Double(duration).map { abs($0 - 1.2) < 0.06 } == true, "A short soundtrack changed video duration: \(duration)")
        let decodedAudio = root.appendingPathComponent("merged.pcm")
        try generate(engine.ffmpeg, ["-i", merged.path, "-map", "0:a:0", "-t", "0.2", "-f", "s16le", decodedAudio.path])
        try require(try Data(contentsOf: decodedAudio).contains(where: { $0 != 0 }), "Merge did not replace the silent source track")

        let longAudio = root.appendingPathComponent("long.wav")
        try generate(engine.ffmpeg, ["-f", "lavfi", "-i", "sine=frequency=440:duration=2", longAudio.path])
        store.importDroppedFiles([longAudio])
        store.start()
        for await running in store.$isRunning.values { if !running { break } }
        guard let mergedLong = store.trackSelection(for: .merge).output else { throw Failure(store.notice ?? "Long soundtrack merge failed") }
        let longDuration = try probeValue(probe, mergedLong, entries: "format=duration")
        try require(Double(longDuration).map { abs($0 - 1.2) < 0.06 } == true, "A long soundtrack changed video duration: \(longDuration)")

        let runner = FFmpegRunner(toolchain: engine)
        let pictureDuration = try await runner.trackDuration(withAudio, video: true)
        let soundtrackDuration = try await runner.trackDuration(longAudio, video: false)
        try require(pictureDuration == 1.2 && soundtrackDuration == 2, "Timeline durations did not match their source tracks")
        let spectrum = try await runner.audioSpectrum(longAudio)
        try require(spectrum.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]), "Timeline spectrum is not a PNG")
        store.setMergeFormat(.mkv)
        store.updateMerge {
            $0.edit.video = TrackTrim(start: 0.2, end: 1.0)
            $0.edit.audio = TrackTrim(start: 0.13, end: 0.53)
            $0.edit.audioOffset = 0.25
        }
        store.editMergeParameters()
        guard let target = store.parameterEditor, target.format == .mkv else { throw Failure("Merge parameters used the wrong container") }
        var draft = target.initial
        draft.options.resolution = .custom
        draft.options.customWidth = 96
        draft.options.customHeight = 64
        draft.options.frameFit = .pad
        draft.options.videoCodec = .hevc
        try store.saveParameters(draft, for: target)
        store.parameterEditor = nil
        store.start()
        for await running in store.$isRunning.values { if !running { break } }
        guard let aligned = store.trackSelection(for: .merge).output else { throw Failure(store.notice ?? "Aligned merge failed") }
        try require(aligned.pathExtension == "mkv", "Merge ignored the chosen output container")
        try require(try probeValue(probe, aligned, entries: "stream=codec_name,width,height") == "hevc,96,64,aac",
                    "Merge ignored its resolution or codec settings")
        let editedDuration = try probeValue(probe, aligned, entries: "format=duration")
        try require(Double(editedDuration).map { abs($0 - 0.8) < 0.06 } == true, "Video trim duration differed: \(editedDuration)")
        for (time, shouldHearAudio) in [(0.02, false), (0.35, true), (0.72, false)] {
            let pcm = root.appendingPathComponent("aligned-\(time).pcm")
            try generate(engine.ffmpeg, ["-ss", String(time), "-i", aligned.path, "-map", "0:a:0", "-t", "0.04", "-f", "s16le", pcm.path])
            let samples = try Data(contentsOf: pcm)
            let audible = stride(from: 0, to: samples.count - 1, by: 2).contains { index in
                let value = Int16(bitPattern: UInt16(samples[index]) | (UInt16(samples[index + 1]) << 8))
                return abs(Int(value)) > 40
            }
            try require(!samples.isEmpty && audible == shouldHearAudio, "Trim or audio delay was incorrect around \(time)s")
        }

        var earlyEdit = store.trackSelection(for: .merge).merge.edit
        earlyEdit.audioOffset = -0.15
        let early = root.appendingPathComponent("early.webm")
        try await runner.processTracks(.merge(video: withAudio, audio: longAudio, output: early, format: .webm, edit: earlyEdit))
        try require(try probeValue(probe, early, entries: "stream=codec_name") == "vp9,opus", "WebM merge used the wrong encoders")
        let earlySamples = root.appendingPathComponent("early.pcm")
        try generate(engine.ffmpeg, ["-i", early.path, "-map", "0:a:0", "-t", "0.1", "-f", "s16le", earlySamples.path])
        try require(try Data(contentsOf: earlySamples).contains(where: { $0 != 0 }), "Advance did not align audio to the video start")

        let preview = root.appendingPathComponent("preview.mp4")
        try await runner.processTracks(.merge(video: withAudio, audio: longAudio, output: preview, edit: earlyEdit, previewStart: 0.2))
        let previewDuration = try probeValue(probe, preview, entries: "format=duration")
        try require(Double(previewDuration).map { abs($0 - 0.6) < 0.06 } == true, "Preview did not start at the requested position: \(previewDuration)")
    }

    private static func probeValue(_ tool: URL, _ file: URL, entries: String) throws -> String {
        let process = Process()
        let stdout = Pipe()
        process.executableURL = tool
        process.arguments = ["-v", "error", "-show_entries", entries, "-of", "default=noprint_wrappers=1:nokey=1", file.path]
        process.standardOutput = stdout
        try process.run()
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw Failure("Track probe failed") }
        return String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).joined(separator: ",")
    }

    private static func generate(_ tool: URL, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = tool
        process.arguments = ["-hide_banner", "-loglevel", "error", "-nostdin", "-n"] + arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.standardError
        try process.run(); process.waitUntilExit()
        if process.terminationStatus != 0 { throw Failure("Fixture/decode failed: \(process.terminationStatus)") }
    }

    private static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { throw Failure(message) }
    }
    private struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }
}
