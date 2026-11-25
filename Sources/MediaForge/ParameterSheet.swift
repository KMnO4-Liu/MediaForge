import SwiftUI
import MediaForgeCore

struct ParameterSheet: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var draft: EncodingParameters
    @State private var error: String?
    @State private var customSampleRate: Bool
    let target: ParameterTarget

    init(target: ParameterTarget) {
        self.target = target
        _draft = State(initialValue: target.initial)
        let options = target.initial.options
        _customSampleRate = State(initialValue: target.format.resolvedAudioCodec(options: options) == .pcm &&
            options.audioSampleRate.map { !AudioCodec.pcm.sampleRates.contains($0) } == true)
    }

    private var format: OutputFormat { target.format }
    private var videoCodec: VideoCodec { format.resolvedVideoCodec(options: draft.options) }
    private var audioCodec: AudioCodec { format.resolvedAudioCodec(options: draft.options) }
    private var frameRates: [Int] {
        let rates = videoCodec.usesStandardFrameRate ? [24, 25, 30, 50, 60] : [10, 15, 24, 25, 30, 50, 60, 120]
        return Array(Set(rates + [draft.options.frameRate].compactMap { $0 })).sorted()
    }
    private var audioBitrates: [Int] {
        let rates = audioCodec.bitrates.filter {
            audioCodec != .mp2 || (draft.options.audioSampleRate ?? 48000) >= 32000 || $0 <= 160
        }
        return Array(Set(rates + [draft.options.audioBitrateKbps].compactMap { $0 })).sorted()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("参数设置").font(.system(size: 22, weight: .semibold))
                    Text(target.title).font(.system(size: 12)).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                Text(format.displayName).font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(accent).padding(.horizontal, 10).padding(.vertical, 6)
                    .background(accent.opacity(0.08), in: Capsule())
            }
            .padding(.horizontal, 25).padding(.vertical, 20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if format.kind != .audio { pictureSection }
                    if format.kind == .video { bitrateSection }
                    if format.kind != .image { audioSection }
                    if format.kind == .image && format.supportsAnimation { animationSection }
                }
                .padding(22)
            }
            .frame(maxHeight: 480)
            Divider()
            VStack(alignment: .leading, spacing: 9) {
                if let error {
                    Text(error).font(.system(size: 11)).foregroundStyle(.red)
                }
                HStack {
                    Button("恢复默认") { draft = EncodingParameters(); customSampleRate = false; error = nil }
                    Spacer()
                    Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                    Button("保存", action: save).buttonStyle(.borderedProminent).tint(accent)
                        .keyboardShortcut(.defaultAction).disabled(store.isRunning)
                }
                .controlSize(.large)
            }
            .padding(.horizontal, 25).padding(.vertical, 15)
        }
        .frame(width: 615)
        .background(canvas)
        .onChange(of: draft.options.videoCodec) { _, _ in
            if !videoCodec.supports(draft.options.resolvedVideoRateMode) { selectRateMode(.source) }
            if let crf = draft.options.videoCRF, let range = videoCodec.crfRange {
                draft.options.videoCRF = min(max(crf, range.lowerBound), range.upperBound)
            }
            if videoCodec.usesStandardFrameRate, let rate = draft.options.frameRate,
               ![24, 25, 30, 50, 60].contains(rate) { draft.options.frameRate = nil }
        }
        .onChange(of: draft.options.audioCodec) { _, _ in
            if audioCodec != .pcm {
                customSampleRate = false
                draft.options.pcmBitDepth = 16
            }
            normalizeAudio()
        }
        .onChange(of: draft.options.audioSampleRate) { _, _ in normalizeAudio() }
        .onChange(of: draft.options.animationMode) { _, mode in
            if mode == .firstFrame { draft.options.frameRate = nil }
        }
    }

    private var pictureSection: some View {
        section(format.kind == .video ? "视频参数" : "图片参数", icon: format.kind == .video ? "film" : "photo") {
            columns {
                if format.kind == .video {
                    field("视频编码器") {
                        Picker("视频编码器", selection: $draft.options.videoCodec) {
                            ForEach(format.allowedVideoCodecs.filter { $0 == .automatic || store.encoders.contains($0.encoder) }, id: \.self) {
                                Text($0.displayName).tag($0)
                            }
                        }
                    }
                }
                field("分辨率") {
                    Picker("分辨率", selection: $draft.options.resolution) {
                        ForEach(ResolutionPreset.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                }
                if format.kind == .video || (format.supportsAnimation && draft.options.animationMode == .preserve) {
                    field("帧率") {
                        Picker("帧率", selection: $draft.options.frameRate) {
                            Text(videoCodec.usesStandardFrameRate ? "自动 · 25 fps" : "保留源时序").tag(nil as Int?)
                            ForEach(frameRates, id: \.self) { Text("\($0) fps").tag(Optional($0)) }
                        }
                    }
                }
                if draft.options.resolution != .original {
                    field("画面适配") {
                        Picker("画面适配", selection: Binding(get: { draft.options.frameFit ?? .fit }, set: { draft.options.frameFit = $0 })) {
                            ForEach(FrameFit.allCases, id: \.self) { Text($0.displayName).tag($0) }
                        }
                    }
                }
                if draft.options.resolution == .custom {
                    field("宽度") {
                        TextField("宽度", value: $draft.options.customWidth, format: .number.grouping(.never))
                            .textFieldStyle(.roundedBorder).accessibilityLabel("输出宽度")
                    }
                    field("高度") {
                        TextField("高度", value: $draft.options.customHeight, format: .number.grouping(.never))
                            .textFieldStyle(.roundedBorder).accessibilityLabel("输出高度")
                    }
                }
            }
        }
    }

    private var audioSection: some View {
        section("音频参数", icon: "waveform") {
            columns {
                field("音频编码器") {
                    Picker("音频编码器", selection: $draft.options.audioCodec) {
                        Text("自动 · \(format.resolvedAudioCodec(options: ConversionOptions()).displayName)").tag(AudioCodec.automatic)
                        ForEach(format.allowedAudioCodecs.filter { codec in
                            var options = draft.options
                            options.audioCodec = codec
                            return store.encoders.contains(format.audioEncoder(options: options))
                        }, id: \.self) { Text($0.displayName).tag($0) }
                    }
                }
                field("采样率") {
                    Picker("采样率", selection: Binding(
                        get: { customSampleRate ? -1 : draft.options.audioSampleRate ?? 0 },
                        set: { rate in
                            customSampleRate = rate == -1
                            if rate == -1 { draft.options.audioSampleRate = draft.options.audioSampleRate ?? 48000 }
                            else { draft.options.audioSampleRate = rate == 0 ? nil : rate }
                        }
                    )) {
                        Text("自动").tag(0)
                        ForEach(audioCodec.sampleRates, id: \.self) { Text("\($0) Hz").tag($0) }
                        if audioCodec == .pcm { Text("自定义").tag(-1) }
                    }
                }
                if audioCodec == .pcm && customSampleRate {
                    field("自定义采样率（Hz）") {
                        TextField("采样率（Hz）", value: $draft.options.audioSampleRate, format: .number.grouping(.never))
                            .textFieldStyle(.roundedBorder).accessibilityLabel("PCM 自定义采样率，单位 Hz")
                    }
                }
                if audioCodec.supportsBitrate {
                    field("音频码率") {
                        Picker("音频码率", selection: $draft.options.audioBitrateKbps) {
                            Text("自动").tag(nil as Int?)
                            ForEach(audioBitrates, id: \.self) { Text("\($0) kbps").tag(Optional($0)) }
                        }
                    }
                }
                if audioCodec == .pcm {
                    field("PCM 位深") {
                        Picker("PCM 位深", selection: $draft.options.pcmBitDepth) {
                            ForEach([16, 24, 32], id: \.self) { Text("\($0)-bit").tag($0) }
                        }
                    }
                }
            }
        }
    }

    private var bitrateSection: some View {
        section("码率参数", icon: "gauge.with.dots.needle.33percent") {
            let mode = draft.options.resolvedVideoRateMode
            columns {
                field("视频码率模式") {
                    Picker("视频码率模式", selection: Binding(
                        get: { draft.options.resolvedVideoRateMode },
                        set: { selectRateMode($0) }
                    )) {
                        ForEach(VideoRateMode.allCases.filter { videoCodec.supports($0) }, id: \.self) { candidate in
                            Text(candidate == .source ? "默认（与源文件相同）" : candidate.rawValue.uppercased()).tag(candidate)
                        }
                    }
                }
                if mode == .cbr || mode == .abr {
                    field("目标视频码率") {
                        HStack(spacing: 8) {
                            TextField("目标视频码率", value: Binding(
                                get: { draft.options.videoBitrateKbps ?? 5000 },
                                set: { draft.options.videoBitrateKbps = $0 }
                            ), format: .number.grouping(.never))
                            .textFieldStyle(.roundedBorder).accessibilityLabel("目标视频码率，单位 kbps")
                            Text("kbps").font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                } else if mode == .crf, let range = videoCodec.crfRange {
                    field("质量") {
                        Picker("CRF 质量", selection: Binding(
                            get: { draft.options.videoCRFPreset },
                            set: { selectCRFQuality($0) }
                        )) {
                            ForEach([ConversionQuality.high, .balanced, .compact], id: \.self) { quality in
                                Text(crfQualityLabel(quality)).tag(Optional(quality))
                            }
                            Text("自定义").tag(nil as ConversionQuality?)
                        }
                    }
                    if draft.options.videoCRFPreset == nil {
                        field("CRF（\(range.lowerBound)–\(range.upperBound)）") {
                            TextField("CRF 数值", value: Binding(
                                get: { draft.options.videoCRF ?? defaultCRF },
                                set: { draft.options.videoCRF = $0 }
                            ), format: .number.grouping(.never))
                            .textFieldStyle(.roundedBorder).accessibilityLabel("CRF 数值")
                        }
                    }
                }
            }
            Text(rateModeDetail(mode)).font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    private var defaultCRF: Int { videoCodec.recommendedCRF(for: .balanced) ?? 23 }

    private func crfQualityLabel(_ quality: ConversionQuality) -> String {
        let title: String
        switch quality {
        case .high: title = "高质量"
        case .balanced: title = "中等"
        case .compact: title = "低质量"
        }
        if let crf = videoCodec.recommendedCRF(for: quality) { return "\(title) · CRF \(crf)" }
        return title
    }

    private func selectCRFQuality(_ quality: ConversionQuality?) {
        if quality == nil && draft.options.videoCRF == nil {
            draft.options.videoCRF = draft.options.resolvedVideoCRF(for: videoCodec) ?? defaultCRF
        }
        draft.options.videoCRFPreset = quality
    }

    private func selectRateMode(_ mode: VideoRateMode) {
        draft.options.videoRateMode = mode
        if mode == .cbr || mode == .abr {
            draft.options.videoBitrateKbps = draft.options.videoBitrateKbps ?? 5000
        } else {
            draft.options.videoBitrateKbps = nil
        }
        if mode == .crf {
            if draft.options.resolvedVideoCRF(for: videoCodec) == nil { draft.options.videoCRFPreset = .balanced }
        } else {
            draft.options.videoCRF = nil
            draft.options.videoCRFPreset = nil
        }
    }

    private func rateModeDetail(_ mode: VideoRateMode) -> String {
        switch mode {
        case .source: return "优先沿用源视频码率，无法取得或应用时由编码器自动决定。"
        case .cbr: return "以恒定码率为目标，缓冲区内允许短时波动。"
        case .abr: return "以平均码率为目标，复杂画面可以使用更多码率。"
        case .crf: return "以恒定质量为目标，数值越小通常画质越高、文件越大。"
        }
    }

    private var animationSection: some View {
        section("动画参数", icon: "play.rectangle") {
            columns {
                field("帧处理") {
                    Picker("帧处理", selection: $draft.options.animationMode) {
                        ForEach(AnimationMode.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                }
                if draft.options.animationMode == .preserve {
                    field("循环") {
                        Picker("循环", selection: $draft.options.animationLoop) {
                            ForEach(AnimationLoop.allCases, id: \.self) { Text($0.displayName).tag($0) }
                        }
                    }
                }
            }
        }
    }

    private func section<Fields: View>(_ title: String, icon: String, @ViewBuilder content: () -> Fields) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: icon).font(.system(size: 13, weight: .semibold)).foregroundStyle(accent)
            content()
        }
        .padding(15)
        .background(panel, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(rule))
    }

    private func columns<Fields: View>(@ViewBuilder _ content: () -> Fields) -> some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 18), GridItem(.flexible())], spacing: 11, content: content)
    }

    private func field<Field: View>(_ label: String, @ViewBuilder content: () -> Field) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary).accessibilityHidden(true)
            content().labelsHidden().frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func normalizeAudio() {
        if let rate = draft.options.audioSampleRate, audioCodec != .pcm && !audioCodec.acceptsSampleRate(rate) { draft.options.audioSampleRate = nil }
        if let bitrate = draft.options.audioBitrateKbps,
           !audioCodec.acceptsBitrate(bitrate) || (audioCodec == .mp2 && (draft.options.audioSampleRate ?? 48000) < 32000 && bitrate > 160) {
            draft.options.audioBitrateKbps = nil
        }
    }

    private func save() {
        do {
            if audioCodec == .pcm && customSampleRate && draft.options.audioSampleRate == nil {
                throw ConversionError.invalidOptions("请输入 PCM 采样率（Hz）。")
            }
            if format.kind == .video { draft.options.videoRateMode = draft.options.resolvedVideoRateMode }
            draft.matchSource = false
            try store.saveParameters(draft, for: target)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
