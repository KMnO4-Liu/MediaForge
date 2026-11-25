import Foundation
import MediaForgeCore

extension MediaForgeChecks {
    static func optionChecks() throws {
        func rejected(_ format: OutputFormat, _ edit: (inout ConversionOptions) -> Void) throws {
            var options = ConversionOptions(); edit(&options)
            do { try options.validate(for: format); throw CheckFailure("invalid options accepted: \(format) \(options)") }
            catch ConversionError.invalidOptions { }
        }
        try rejected(.webm) { $0.videoCodec = .h264 }
        try rejected(.mp4) { $0.videoCodec = .prores }
        try rejected(.mov) { $0.videoCodec = .vp9 }
        try rejected(.wav) { $0.audioCodec = .alac }
        try rejected(.mp4) { $0.resolution = .custom; $0.customWidth = 0 }
        try rejected(.png) { $0.videoBitrateKbps = 100 }
        try rejected(.mp4) { $0.videoBitrateKbps = -1 }
        try rejected(.wav) { $0.audioBitrateKbps = 128 }
        try rejected(.m4a) { $0.audioCodec = .alac; $0.audioBitrateKbps = 128 }
        try rejected(.mp3) { $0.audioBitrateKbps = 321 }
        try rejected(.mp3) { $0.audioBitrateKbps = 33 }
        try rejected(.mp4) { $0.frameRate = 0 }
        try rejected(.png) { $0.frameRate = 30 }
        try rejected(.wav) { $0.pcmBitDepth = 20 }
        try rejected(.mp4) { $0.pcmBitDepth = 24 }
        for format in OutputFormat.allCases { try ConversionOptions().validate(for: format) }
        let defaults = ConversionOptions()
        let decoded = try JSONDecoder().decode(ConversionOptions.self, from: JSONEncoder().encode(defaults))
        try require(decoded == defaults, "options Codable round trip")
        for codec in [VideoCodec.h264, .hevc, .vp9, .av1] {
            var options = ConversionOptions(); options.videoCodec = codec; options.videoBitrateKbps = 250
            let request = ConversionRequest(input: URL(fileURLWithPath: "/tmp/in"), output: URL(fileURLWithPath: "/tmp/out"), format: .mkv, quality: .high, options: options)
            let args = FFmpegArguments.conversion(request, temporaryOutput: request.output)
            try require(args.contains("250k") && !args.contains("-crf"), "ABR excludes CRF: \(codec)")
            try require(!args.contains("-r") && !args.contains(where: { $0.contains("fps=") }), "nil fps preserves source")
        }
        print("PASS parameter rejection, Codable, ABR/CRF exclusion, nil-fps passthrough")
    }

    static func probeJSON(_ probe: URL, _ input: URL, frames: Bool = false) throws -> [String: Any] {
        let process = Process(); process.executableURL = probe
        process.arguments = ["-v", "error", "-show_streams", "-show_format"] + (frames ? ["-show_frames"] : []) + ["-of", "json", input.path]
        let pipe = Pipe(); process.standardOutput = pipe; process.standardError = FileHandle.standardError
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        try require(process.terminationStatus == 0, "ffprobe failed")
        return try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }
    static func stream(_ probe: URL, _ input: URL) throws -> [String: Any] {
        let json = try probeJSON(probe, input)
        return (json["streams"] as! [[String: Any]])[0]
    }
    static func advancedChecks(tool: URL, probe: URL, fixture: Fixture, source: URL, runner: FFmpegRunner) async throws {
        try require(FileManager.default.isExecutableFile(atPath: probe.path), "advanced checks require adjacent real ffprobe")
        for (codec, format) in [(VideoCodec.h264, OutputFormat.mp4), (.hevc, .mp4), (.vp9, .webm), (.av1, .webm), (.prores, .mov)] {
            var options = ConversionOptions(); options.videoCodec = codec
            if codec != .prores { options.videoBitrateKbps = 250 }
            let output = fixture.url("codec-\(codec.rawValue).\(format.rawValue)")
            try await runner.convert(ConversionRequest(input: source, output: output, format: format, quality: .balanced, options: options)) { _ in }
            let info = try stream(probe, output)
            try require(info["codec_name"] as? String == codec.rawValue, "actual codec: \(codec) \(info)")
            try run(tool, ["-v", "error", "-i", output.path, "-f", "null", "-"])
            print("PASS real \(codec.displayName) \(format.displayName) + decode + ABR arguments")
        }
        for format in [OutputFormat.wav, .aiff] {
            for depth in [16, 24, 32] {
                var options = ConversionOptions(); options.pcmBitDepth = depth
                let output = fixture.url("depth-\(depth).\(format.rawValue)")
                try await runner.convert(ConversionRequest(input: source, output: output, format: format, quality: .balanced, options: options)) { _ in }
                let info = try stream(probe, output)
                try require(info["bits_per_sample"] as? Int == depth, "actual PCM depth \(depth)")
            }
        }
        var alac = ConversionOptions(); alac.audioCodec = .alac
        let alacOutput = fixture.url("alac.m4a")
        try await runner.convert(ConversionRequest(input: source, output: alacOutput, format: .m4a, quality: .balanced, options: alac)) { _ in }
        let alacInfo = try stream(probe, alacOutput)
        try require(alacInfo["codec_name"] as? String == "alac", "actual ALAC")
        print("PASS real ALAC and WAV/AIFF 16/24/32-bit outputs")
        let longAudio = fixture.url("bitrate-source.wav")
        try run(tool, ["-v", "error", "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000:duration=2", longAudio.path])
        for format in [OutputFormat.opus, .m4a] {
            var sizes: [Int] = []
            for bitrate in [64, 192] {
                var options = ConversionOptions(); options.audioBitrateKbps = bitrate
                let output = fixture.url("bitrate-\(bitrate).\(format.rawValue)")
                let request = ConversionRequest(input: longAudio, output: output, format: format, quality: .high, options: options)
                let args = FFmpegArguments.conversion(request, temporaryOutput: output)
                try require(args.contains("\(bitrate)k") && !args.contains("-q:a"), "explicit audio bitrate arguments")
                try await runner.convert(request) { _ in }
                let info = try stream(probe, output)
                try require(info["codec_name"] as? String == (format == .opus ? "opus" : "aac"), "actual bitrate output codec")
                sizes.append(try Data(contentsOf: output).count)
            }
            try require(sizes[1] > sizes[0], "audio bitrate changes actual output size: \(sizes)")
        }
        print("PASS real Opus/AAC explicit 64/192kbps parameters and measured size response")
        for (format, width, height, expectedWidth, expectedHeight) in [(OutputFormat.mp4, 31, 31, 32, 24), (.png, 31, 31, 31, 23), (.mp4, 1920, 1080, 66, 50), (.png, 1920, 1080, 65, 49)] {
            var options = ConversionOptions(); options.resolution = .custom; options.customWidth = width; options.customHeight = height
            let output = fixture.url("size-\(width)-\(height).\(format.rawValue)")
            try await runner.convert(ConversionRequest(input: source, output: output, format: format, quality: .balanced, options: options)) { _ in }
            let info = try stream(probe, output)
            try require(info["width"] as? Int == expectedWidth && info["height"] as? Int == expectedHeight, "actual fit/no-upscale/even dimensions: \(info)")
        }
        print("PASS measured fit-inside, aspect ratio, no enlargement, video-only even padding")
        var fpsOptions = ConversionOptions(); fpsOptions.frameRate = 24
        let fpsOutput = fixture.url("fps.mp4")
        try await runner.convert(ConversionRequest(input: source, output: fpsOutput, format: .mp4, quality: .balanced, options: fpsOptions)) { _ in }
        let fpsInfo = try stream(probe, fpsOutput)
        try require(fpsInfo["avg_frame_rate"] as? String == "24/1", "explicit actual fps")
        try await animationChecks(tool: tool, probe: probe, fixture: fixture, runner: runner)
    }

    static func animationChecks(tool: URL, probe: URL, fixture: Fixture, runner: FFmpegRunner) async throws {
        let original = fixture.url("variable.apng")
        // Three visually distinct RGBA frames; unequal 0.1/0.2/0.3 second delays.
        try run(tool, ["-v", "error", "-f", "lavfi", "-i", "testsrc=size=32x24:rate=10:duration=0.3,format=rgba,drawbox=x=0:y=0:w=8:h=8:color=black@0:t=fill:replace=1", "-vf", "settb=1/1000,setpts='if(eq(N,0),0,if(eq(N,1),100,300))'", "-fps_mode", "passthrough", "-enc_time_base", "1:1000", "-plays", "3", "-final_delay", "3/10", original.path])
        let originalFrames = try frameTimes(probe, original)
        try require(originalFrames.count == 3, "fixture frame count")
        let gif = fixture.url("variable.gif"), webp = fixture.url("variable.webp")
        for (input, output, format) in [(original, gif, OutputFormat.gif), (original, webp, .webp), (gif, fixture.url("gif-gif.gif"), .gif), (gif, fixture.url("gif-webp.webp"), .webp), (gif, fixture.url("gif-apng.apng"), .apng), (webp, fixture.url("webp-gif.gif"), .gif)] {
            try await runner.convert(ConversionRequest(input: input, output: output, format: format, quality: .high)) { _ in }
            let before = try frameTimes(probe, input), after = try frameTimes(probe, output)
            try require(before.count == after.count, "animation frame count \(input.lastPathComponent) → \(format): \(before) / \(after)")
            for (a, b) in zip(before, after) {
                try require(abs(a.0 - b.0) < 0.011 && abs(a.1 - b.1) < 0.011, "animation timing \(input.lastPathComponent) → \(format): \(before) / \(after)")
            }
            let info = try stream(probe, output)
            let pixel = info["pix_fmt"] as? String ?? ""
            try require(pixel.contains("a") || format == .gif, "alpha-capable pixel format: \(pixel)")
            let rgba = fixture.url("\(output.lastPathComponent).rgba")
            try run(tool, ["-v", "error", "-i", output.path, "-frames:v", "1", "-pix_fmt", "rgba", "-f", "rawvideo", rgba.path])
            let pixels = try Data(contentsOf: rgba)
            try require(pixels.count == 32 * 24 * 4 && pixels[3] == 0 && pixels[(16 * 32 + 16) * 4 + 3] == 255, "actual transparent and opaque decoded pixels")
            try loopCheck(output, format: format, once: false)
            print("PASS animation \(input.lastPathComponent) → \(format): \(after.count) frames, exact unequal timing ±10ms, alpha format \(pixel)")
        }
        for format in [OutputFormat.gif, .webp, .apng] {
            var options = ConversionOptions(); options.animationLoop = .once
            let once = fixture.url("once.\(format.rawValue)")
            try await runner.convert(ConversionRequest(input: original, output: once, format: format, quality: .balanced, options: options)) { _ in }
            try loopCheck(once, format: format, once: true)
            var first = ConversionOptions(); first.animationMode = .firstFrame
            let single = fixture.url("first.\(format.rawValue)")
            try await runner.convert(ConversionRequest(input: original, output: single, format: format, quality: .balanced, options: first)) { _ in }
            let frames = try frameTimes(probe, single)
            try require(frames.count == 1, "explicit first frame \(format)")
        }
        let pngNamedAnimation = fixture.url("animation-with-png-extension.png")
        try FileManager.default.copyItem(at: original, to: pngNamedAnimation)
        for format in [OutputFormat.gif, .webp, .apng] {
            let output = fixture.url("png-extension-result.\(format.rawValue)")
            try await runner.convert(ConversionRequest(input: pngNamedAnimation, output: output, format: format, quality: .high)) { _ in }
            let frames = try frameTimes(probe, output)
            try require(frames.count == originalFrames.count, "APNG .png extension retains frame count")
            for (before, after) in zip(originalFrames, frames) {
                try require(abs(before.0 - after.0) < 0.011 && abs(before.1 - after.1) < 0.011, "APNG .png extension retains frame timing")
            }
        }
        print("PASS APNG content with .png extension → GIF/WebP/APNG: all 3 frames and 100/200/300ms delays")
        let staticWebP = fixture.url("first.webp"), staticPNG = fixture.url("static-webp.png")
        try await runner.convert(ConversionRequest(input: staticWebP, output: staticPNG, format: .png, quality: .balanced)) { _ in }
        let staticFrames = try frameTimes(probe, staticPNG)
        try require(staticFrames.count == 1, "static WebP input does not receive animation-only demuxer options")
        let vfr = fixture.url("vfr.mp4")
        try await runner.convert(ConversionRequest(input: original, output: vfr, format: .mp4, quality: .balanced)) { _ in }
        let vfrFrames = try frameTimes(probe, vfr)
        try require(vfrFrames.count == 3 && abs(vfrFrames[1].0 - 0.1) < 0.001 && abs(vfrFrames[2].0 - 0.3) < 0.001, "nil-fps preserves actual VFR timestamps")
        print("PASS actual alpha pixels; forever/once GIF/WebP/APNG metadata; finite input loop; first-frame/static WebP; nil-fps VFR timestamps")
    }
    static func loopCheck(_ input: URL, format: OutputFormat, once: Bool) throws {
        let bytes = try Data(contentsOf: input)
        if format == .gif {
            let range = bytes.range(of: Data("NETSCAPE2.0".utf8))
            if once { try require(range == nil, "GIF once omits looping extension") }
            else {
                guard let range else { throw CheckFailure("GIF forever missing loop extension") }
                try require(bytes[range.upperBound + 2] == 0 && bytes[range.upperBound + 3] == 0, "GIF forever loop count")
            }
        }
        if format == .webp {
            guard let range = bytes.range(of: Data("ANIM".utf8)) else { throw CheckFailure("WebP missing ANIM") }
            try require(bytes[range.lowerBound + 12] == (once ? 1 : 0) && bytes[range.lowerBound + 13] == 0, "WebP loop count")
        }
        if format == .apng {
            guard let range = bytes.range(of: Data("acTL".utf8)) else { throw CheckFailure("APNG missing acTL") }
            try require(Array(bytes[(range.lowerBound + 8)..<(range.lowerBound + 12)]) == [0, 0, 0, once ? 1 : 0], "APNG plays")
        }
    }
    static func frameTimes(_ probe: URL, _ input: URL) throws -> [(Double, Double)] {
        let json = try probeJSON(probe, input, frames: true)
        return (json["frames"] as? [[String: Any]] ?? []).map { frame in
            (Double(frame["pts_time"] as? String ?? "0") ?? 0, Double(frame["duration_time"] as? String ?? "0") ?? 0)
        }
    }
}
