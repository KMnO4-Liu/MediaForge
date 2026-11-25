import Foundation

struct StreamCopy {
    var video = false
    var audio = false
    var enabled: Bool { video || audio }
}

struct VideoAcceleration {
    var decode = false
    var encoder: String?
    var enabled: Bool { decode || encoder != nil }
    var inputArguments: [String] { decode ? ["-hwaccel", "videotoolbox"] : [] }

    func processingPath(copyingVideo: Bool = false) -> ProcessingPath {
        if copyingVideo { return .videoCopy }
        if encoder != nil { return .videoToolbox }
        return decode ? .hardwareDecoding : .software
    }
}

public enum FFmpegArguments {
    /// Does not throw for source compatibility. Runner validates options before executing.
    /// Output must be a private temporary URL, never the user's final destination.
    public static func conversion(_ request: ConversionRequest, temporaryOutput: URL) -> [String] {
        conversion(request, temporaryOutput: temporaryOutput, copying: StreamCopy(), inputTiming: AnimationTiming.read(request.input))
    }

    static func conversion(_ request: ConversionRequest, temporaryOutput: URL, copying: StreamCopy, sourceBitrate: Int? = nil,
                           acceleration: VideoAcceleration = VideoAcceleration(), inputTiming: AnimationTiming?) -> [String] {
        let q: ConversionQuality = request.matchSource ? .high : request.quality
        let o = request.options, f = request.format
        let timing = f.supportsAnimation && o.animationMode == .preserve && o.frameRate == nil ? inputTiming : nil
        var args = ["-hide_banner", "-nostdin", "-n", "-progress", "pipe:1", "-nostats"]
        // Decode precisely one cycle, including finite-loop animations. Never loop input forever.
        let ext = request.input.pathExtension.lowercased()
        if inputTiming != nil { args += ["-ignore_loop", "1"] }
        if inputTiming != nil && (ext == "gif" || ext == "webp") { args += ["-min_delay", "0"] }
        args += acceleration.inputArguments + ["-i", request.input.path]
        var filters = pictureFilters(format: f, options: o)
        switch f.kind {
        case .video:
            args += ["-map", "0:v:0", "-map", "0:a:0?"]
            if copying.video {
                args += ["-c:v", "copy"]
            } else {
                filters.append("pad=ceil(iw/2)*2:ceil(ih/2)*2")
                args += videoEncoding(format: f, options: o, quality: q, sourceBitrate: sourceBitrate, hardwareEncoder: acceleration.encoder)
            }
            if copying.audio {
                args += ["-c:a", "copy"]
            } else {
                args += audioEncoding(format: f, options: o, quality: q)
            }
            if f == .mp4 || f == .mov { args += ["-movflags", "+faststart"] }
        case .audio:
            args += ["-map", "0:a:0", "-vn"]
            if copying.audio {
                args += ["-c:a", "copy"]
                break
            }
            args += audioEncoding(format: f, options: o, quality: q)
        case .image:
            let animated = f.supportsAnimation && o.animationMode == .preserve
            args += ["-map", "0:v:0", "-an", "-c:v", f.encoder(options: o)]
            if !animated { args += ["-frames:v", "1"] }
            args += ["-fps_mode", "passthrough"]
            if animated { args += ["-enc_time_base", f == .apng ? (o.frameRate == nil ? "demux" : "filter") : "1:1000"] }
            switch f {
            case .jpeg: args += ["-q:v", q == .compact ? "8" : q == .balanced ? "4" : "2"]
            case .webp:
                args += ["-quality", q == .compact ? "65" : q == .balanced ? "82" : "95", "-loop", o.animationLoop == .forever ? "0" : "1"]
            case .gif:
                filters.append("split[a][b];[a]palettegen=reserve_transparent=1[p];[b][p]paletteuse=alpha_threshold=128")
                args += ["-loop", o.animationLoop == .forever ? "0" : "-1"]
            case .apng: args += ["-plays", o.animationLoop == .forever ? "0" : "1"]
            case .avif: args += ["-crf", q == .compact ? "40" : q == .balanced ? "30" : "20", "-cpu-used", "6", "-still-picture", "1"]
            case .png: args += ["-compression_level", q == .compact ? "9" : "6"]
            default: break
            }
            if [.png, .jpeg, .tiff, .bmp].contains(f) { args += ["-update", "1"] }
        }
        if let last = timing?.last, last > 0 {
            if f == .gif { args += ["-final_delay", String(Int((last * 100).rounded()))] }
            if f == .apng { args += ["-final_delay", String(last)] }
        }
        if !filters.isEmpty { args += ["-vf", filters.joined(separator: ",")] }
        args += [temporaryOutput.path]
        return args
    }

    private static func pictureFilters(format: OutputFormat, options: ConversionOptions) -> [String] {
        var filters: [String] = []
        if let (width, height) = options.bounds {
            switch options.frameFit ?? .fit {
            case .fit:
                filters.append("scale=w='min(iw,\(width))':h='min(ih,\(height))':force_original_aspect_ratio=decrease")
            case .pad:
                filters += ["scale=\(width):\(height):force_original_aspect_ratio=decrease",
                            "pad=\(width):\(height):(ow-iw)/2:(oh-ih)/2", "setsar=1"]
            case .crop:
                filters += ["scale=\(width):\(height):force_original_aspect_ratio=increase",
                            "crop=\(width):\(height)", "setsar=1"]
            }
        }
        let legacyFrameRate = format.resolvedVideoCodec(options: options).usesStandardFrameRate
        if let fps = options.frameRate ?? (legacyFrameRate ? 25 : nil) { filters.append("fps=\(fps)") }
        return filters
    }

    private static func videoEncoding(format: OutputFormat, options: ConversionOptions, quality: ConversionQuality,
                                      sourceBitrate: Int? = nil, hardwareEncoder: String? = nil) -> [String] {
        let codec = format.resolvedVideoCodec(options: options)
        let timeBase = codec.usesStandardFrameRate ? "filter" : codec == .mpeg4 ? "1:60000" : options.frameRate == nil ? "demux" : "filter"
        if let hardwareEncoder {
            var args = ["-c:v", hardwareEncoder, "-allow_sw", "0", "-pix_fmt", codec == .prores ? "p210le" : "nv12",
                        "-fps_mode", "passthrough", "-enc_time_base:v", timeBase]
            if codec == .prores {
                args += ["-profile:v", quality == .compact ? "0" : quality == .balanced ? "2" : "3"]
            } else {
                let mode = options.resolvedVideoRateMode
                let rate = mode == .source ? (options.videoRateMode == .source ? sourceBitrate : nil) : options.videoBitrateKbps
                if let rate {
                    args += ["-b:v", "\(rate)k"]
                    if mode == .cbr { args += ["-constant_bit_rate", "1"] }
                } else {
                    args += ["-q:v", quality == .compact ? "45" : quality == .balanced ? "65" : "80"]
                }
            }
            if codec == .hevc && (format == .mp4 || format == .mov) { args += ["-tag:v", "hvc1"] }
            return args
        }
        var args = ["-c:v", codec.encoder,
                    "-pix_fmt", codec == .prores ? "yuv422p10le" : "yuv420p", "-fps_mode", "passthrough",
                    "-enc_time_base:v", timeBase]
        let mode = options.resolvedVideoRateMode
        switch mode {
        case .cbr:
            if let bitrate = options.videoBitrateKbps {
                let rate = "\(bitrate)k"
                args += ["-b:v", rate, "-minrate", rate, "-maxrate", rate, "-bufsize", "\(2 * bitrate)k"]
                if codec == .h264 { args += ["-x264-params", "filler=1"] }
                if codec == .hevc { args += ["-x265-params", "strict-cbr=1"] }
            }
        case .abr:
            if let bitrate = options.videoBitrateKbps { args += ["-b:v", "\(bitrate)k"] }
        case .crf:
            if let crf = options.resolvedVideoCRF(for: codec) { args += ["-crf", "\(crf)"] }
            if codec == .vp9 || codec == .av1 { args += ["-b:v", "0"] }
        case .source:
            if options.videoRateMode == .source, let sourceBitrate, codec.supports(.abr) {
                args += ["-b:v", "\(sourceBitrate)k"]
                break
            }
            switch codec {
            case .vp9, .av1: args += ["-crf", "\(codec.recommendedCRF(for: quality) ?? 32)", "-b:v", "0"]
            case .prores: args += ["-profile:v", quality == .compact ? "0" : quality == .balanced ? "2" : "3"]
            case .mpeg1video, .mpeg2video, .mpeg4: args += ["-q:v", quality == .compact ? "8" : quality == .balanced ? "5" : "3"]
            default: args += ["-crf", "\(codec.recommendedCRF(for: quality) ?? 23)"]
            }
        }
        if codec == .h264 || codec == .hevc { args += ["-preset", "medium"] }
        if codec == .av1 { args += ["-cpu-used", "6", "-row-mt", "1"] }
        if codec == .hevc && (format == .mp4 || format == .mov) { args += ["-tag:v", "hvc1"] }
        return args
    }

    private static func audioEncoding(format: OutputFormat, options: ConversionOptions, quality: ConversionQuality) -> [String] {
        let codec = format.resolvedAudioCodec(options: options)
        var args = ["-c:a", format.audioEncoder(options: options)]
        if let sampleRate = options.audioSampleRate { args += ["-ar", "\(sampleRate)"] }
        if codec == .dts { args += ["-strict", "experimental"] }
        if let bitrate = options.audioBitrateKbps { return args + ["-b:a", "\(bitrate)k"] }
        if codec == .vorbis { return args + ["-q:a", quality == .compact ? "3" : quality == .balanced ? "5" : "8"] }
        if codec == .flac { return args + ["-compression_level", "5"] }
        guard codec.supportsBitrate else { return args }
        let bitrate: Int
        switch codec {
        case .dts: bitrate = 768
        case .ac3, .eac3: bitrate = quality == .compact ? 192 : quality == .balanced ? 256 : 384
        case .mp2: bitrate = quality == .compact ? 128 : 160
        case .aac where format.kind == .video, .opus where format.kind == .video:
            bitrate = quality == .compact ? 96 : quality == .high ? 256 : 192
        case .opus: bitrate = quality == .compact ? 64 : quality == .balanced ? 128 : 192
        default: bitrate = quality == .compact ? 128 : quality == .balanced ? 192 : 320
        }
        return args + ["-b:a", "\(bitrate)k"]
    }

    static func trackSeparation(video: URL, videoOutput: URL, audioOutput: URL, acceleration: VideoAcceleration) -> [String] {
        var args = ["-hide_banner", "-nostdin", "-n", "-nostats"] + acceleration.inputArguments + ["-i", video.path]
        args += ["-map", "0:V:0", "-vf", "setpts=PTS-STARTPTS,pad=ceil(iw/2)*2:ceil(ih/2)*2"]
        args += videoEncoding(format: .mp4, options: ConversionOptions(), quality: .high, hardwareEncoder: acceleration.encoder)
        return args + ["-movflags", "+faststart", "-an", videoOutput.path, "-map", "0:a:0", "-vn",
                       "-c:a", "aac", "-b:a", "256k", audioOutput.path]
    }

    static func trackMerge(video: URL, audio: URL, output: URL, format: OutputFormat, options: ConversionOptions,
                           edit: MergeEdit, sourceBitrate: Int?, duration: Double?, previewStart: Double?,
                           acceleration: VideoAcceleration) -> [String] {
        var args = ["-hide_banner", "-nostdin", "-n", "-nostats"] + acceleration.inputArguments
        args += ["-i", video.path, "-i", audio.path, "-map", "0:V:0", "-map", "1:a:0"]
        let videoFilters = ["setpts=PTS-STARTPTS", trimFilter("trim", start: edit.video.start, end: edit.video.end), "setpts=PTS-STARTPTS"]
            + pictureFilters(format: format, options: options) + ["pad=ceil(iw/2)*2:ceil(ih/2)*2"]
        let audioStart = edit.audio.start + max(0, -edit.audioOffset)
        var audioFilters = ["asetpts=PTS-STARTPTS", trimFilter("atrim", start: audioStart, end: edit.audio.end), "asetpts=PTS-STARTPTS"]
        if edit.audioOffset > 0 {
            let milliseconds = Int((edit.audioOffset * 1000).rounded())
            audioFilters.append("adelay=\(milliseconds):all=1")
        }
        audioFilters.append("apad")
        args += ["-vf", videoFilters.joined(separator: ","), "-af", audioFilters.joined(separator: ",")]
        args += videoEncoding(format: format, options: options, quality: .high, sourceBitrate: sourceBitrate, hardwareEncoder: acceleration.encoder)
        args += audioEncoding(format: format, options: options, quality: .high)
        if format == .mp4 || format == .mov { args += ["-movflags", "+faststart"] }
        if let previewStart {
            let length = duration.map { min($0 - previewStart, 12) } ?? 12
            args += ["-ss", "\(previewStart)", "-t", "\(length)"]
        } else if let duration {
            args += ["-t", "\(duration)"]
        }
        return args + ["-shortest", output.path]
    }

    private static func trimFilter(_ name: String, start: Double, end: Double?) -> String {
        let startArg = "\(name)=start=\(start)"
        guard let end else { return startArg }
        return startArg + ":end=\(end)"
    }
}
