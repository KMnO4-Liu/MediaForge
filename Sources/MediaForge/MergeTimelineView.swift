import AppKit
import AVKit
import SwiftUI
import MediaForgeCore

struct MergeTimelineView: View {
    @EnvironmentObject private var store: AppStore
    @State private var videoDuration: Double?
    @State private var audioDuration: Double?
    @State private var dragStart: DragStart?
    @State private var videoPosition = 0.0
    @State private var spectrum: NSImage?
    @State private var sourcePlayer: AVPlayer?
    @State private var loadingSpectrum = false
    @State private var previewStart = 0.0
    @State private var preview: MergePreview?
    @State private var zoom = 1.0
    @State private var snapping = true
    @State private var snapGuide: Double?
    @State private var isScrubbing = false
    @State private var seekGeneration = 0
    @State private var lastScrubSeek = 0.0
    @State private var resumeAfterScrub = false
    let video: URL
    let audio: URL?

    private struct ProbeInput: Equatable {
        let source: URL?
        let executable: URL?
    }

    private struct DragStart {
        let position: Double
        let offset: Double
        let left: Double
        let span: Double
        let playhead: Double
    }

    private var edit: MergeEdit { store.trackSelection(for: .merge).merge.edit }
    private var secondsFormat: FloatingPointFormatStyle<Double> { .number.precision(.fractionLength(0...3)) }
    private var videoLength: Double? { displayLength(edit.video, duration: videoDuration) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            previewMonitor
            Divider()
            HStack {
                Label("时间线", systemImage: "timeline.selection").font(.system(size: 14, weight: .semibold))
                Spacer()
                Button("重置时间线") { resetTimeline() }
                    .buttonStyle(.borderless).font(.system(size: 11)).disabled(edit == MergeEdit())
            }
            if let videoLength, videoLength > 0 {
                let audioLength = displayLength(edit.audio, duration: audioDuration)
                timeline(videoEnd: videoLength, audioLength: audioLength)
            }
            trimRow("视频", key: \.video, duration: videoDuration)
            if audio != nil {
                trimRow("音频", key: \.audio, duration: audioDuration)
                HStack(spacing: 8) {
                    Text("音频偏移").frame(width: 64, alignment: .leading)
                    TextField("音频偏移（秒）", value: binding(\.audioOffset), format: secondsFormat)
                        .frame(width: 72).textFieldStyle(.roundedBorder)
                        .accessibilityLabel("音频偏移，单位秒")
                    Text("秒 · 正值延后，负值提前").foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                .font(.system(size: 11))
            }
        }
        .padding(15)
        .background(panel, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(rule))
        .disabled(store.isRunning)
        .task(id: video) {
            sourcePlayer?.pause()
            let player = AVPlayer(url: video)
            sourcePlayer = player
        }
        .onChange(of: edit) { old, new in
            preview = nil
            if old.video != new.video { seekToPreview(clampedPreview(previewStart)) }
        }
        .onChange(of: audio) { _, _ in preview = nil; videoPosition = 0; dragStart = nil }
        .onChange(of: video) { _, _ in
            preview = nil
            videoPosition = 0
            dragStart = nil
            snapGuide = nil
            isScrubbing = false
            zoom = 1
            previewStart = 0
        }
        .onChange(of: store.isRunning) { _, running in
            if running { sourcePlayer?.pause(); preview = nil }
        }
        .onDisappear { sourcePlayer?.pause() }
        .task(id: ProbeInput(source: video, executable: store.toolchain?.ffprobe)) {
            videoDuration = nil
            guard let chain = store.toolchain, chain.ffprobe != nil else { return }
            let duration = try? await FFmpegRunner(toolchain: chain).trackDuration(video, video: true)
            guard !Task.isCancelled else { return }
            videoDuration = duration
        }
        .task(id: ProbeInput(source: audio, executable: store.toolchain?.ffprobe)) {
            audioDuration = nil
            guard let audio, let chain = store.toolchain, chain.ffprobe != nil else { return }
            let duration = try? await FFmpegRunner(toolchain: chain).trackDuration(audio, video: false)
            guard !Task.isCancelled else { return }
            audioDuration = duration
        }
        .task(id: ProbeInput(source: audio, executable: store.toolchain?.ffmpeg)) {
            spectrum = nil
            loadingSpectrum = false
            guard let audio, let chain = store.toolchain else { return }
            loadingSpectrum = true
            let data = try? await FFmpegRunner(toolchain: chain).audioSpectrum(audio)
            guard !Task.isCancelled else { return }
            loadingSpectrum = false
            spectrum = data.flatMap(NSImage.init(data:))
        }
    }

    private var previewMonitor: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Label("预览监视器", systemImage: "play.rectangle").font(.system(size: 14, weight: .semibold))
                Spacer()
                if preview != nil {
                    Button("原片") { preview = nil }.buttonStyle(.borderless)
                } else {
                    Button {
                        if let videoLength, previewStart >= videoLength { seekToPreview(0, resume: true) }
                        else { sourcePlayer?.play() }
                    } label: {
                        Label("播放原片", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderless)
                    .disabled(sourcePlayer == nil)
                }
            }
            if let preview {
                MergePreviewView(request: preview, toolchain: store.toolchain, hardware: store.videoHardware, onTimeChange: { time in
                    previewStart = clampedPreview(preview.start + time)
                }).id(preview.id)
            } else if let sourcePlayer {
                MergePlayerView(player: sourcePlayer, onTimeChange: { time in
                    if !isScrubbing && preview == nil { previewStart = clampedPreview(time - edit.video.start) }
                }).frame(height: 200)
                    .background(.black, in: RoundedRectangle(cornerRadius: 6))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            if let audio {
                HStack(spacing: 8) {
                    Text("播放位置")
                    TextField("预览起点（秒）", value: Binding(get: { previewStart }, set: { seekToPreview($0) }), format: secondsFormat)
                        .frame(width: 72).textFieldStyle(.roundedBorder)
                        .accessibilityLabel("预览起点，单位秒")
                    Text("秒").foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        sourcePlayer?.pause()
                        let start = videoLength.map { previewStart >= $0 ? 0 : previewStart } ?? previewStart
                        preview = MergePreview(video: video, audio: audio, edit: edit, start: start)
                    } label: {
                    Label("播放对齐预览", systemImage: "play.fill")
                    }
                    .buttonStyle(.bordered)
                    .help("从播放位置起预览最多 12 秒")
                    .disabled(store.toolchain == nil || store.checkingTools)
                }
                .font(.system(size: 11))
            }
        }
    }

    private func resetTimeline() {
        videoPosition = 0
        store.updateMerge { $0.edit = MergeEdit() }
        seekToPreview(0)
    }

    private func trimRow(_ name: String, key: WritableKeyPath<MergeEdit, TrackTrim>, duration: Double?) -> some View {
        HStack(spacing: 8) {
            Text(name).frame(width: 64, alignment: .leading)
            Text("入点").foregroundStyle(.secondary)
            TextField("入点（秒）", value: binding(key.appending(path: \.start)), format: secondsFormat)
                .frame(width: 62).textFieldStyle(.roundedBorder).accessibilityLabel("\(name)入点，单位秒")
            Text("出点").foregroundStyle(.secondary)
            TextField("末尾", value: binding(key.appending(path: \.end)), format: secondsFormat)
                .frame(width: 70).textFieldStyle(.roundedBorder).accessibilityLabel("\(name)出点，留空使用素材末尾")
            Text("秒").foregroundStyle(.secondary)
            Spacer(minLength: 0)
            if let duration {
                Text("总长 \(duration.formatted(secondsFormat)) 秒").foregroundStyle(.secondary).monospacedDigit()
            }
        }
        .font(.system(size: 11))
    }

    private func binding<Value>(_ path: WritableKeyPath<MergeEdit, Value>) -> Binding<Value> {
        Binding(get: { edit[keyPath: path] }, set: { value in
            store.updateMerge { $0.edit[keyPath: path] = value }
        })
    }

    private func timeline(videoEnd: Double, audioLength: Double?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Toggle(isOn: $snapping) { Label("吸附", systemImage: "magnet") }.toggleStyle(.button)
                Spacer(minLength: 5)
                Image(systemName: "minus.magnifyingglass").foregroundStyle(.secondary)
                Slider(value: $zoom, in: 1...16, step: 0.25)
                    .frame(width: 100).accessibilityLabel("时间线缩放")
                Button("适应窗口") { zoom = 1 }.buttonStyle(.borderless).disabled(zoom == 1)
            }
            .font(.system(size: 11))
            .onChange(of: snapping) { _, enabled in if !enabled { snapGuide = nil } }

            GeometryReader { geometry in
                let width = max(Double(geometry.size.width), 1) * zoom
                ScrollView(.horizontal) {
                    timelineContent(width: width, videoLength: videoEnd, audioLength: audioLength)
                        .frame(width: width, height: 88)
                }
                .scrollIndicators(zoom == 1 ? .hidden : .visible)
            }
            .frame(height: zoom == 1 ? 88 : 104)
            HStack {
                Text("播放头 \(previewStart.formatted(secondsFormat)) 秒").monospacedDigit()
                Spacer()
                Text("在标尺上拖动，实时预览")
            }
            .font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }

    private func timelineContent(width: Double, videoLength: Double, audioLength: Double?) -> some View {
        let offset = edit.audioOffset.isFinite ? min(max(edit.audioOffset, -86400), 86400) : 0
        let audioPosition = videoPosition + offset
        let left = dragStart?.left ?? min(0, videoPosition, audioLength == nil ? 0 : audioPosition)
        let right = max(videoPosition + videoLength, audioLength.map { audioPosition + $0 } ?? 0)
        let span = dragStart?.span ?? max(right - left, 0.1)
        let pixelsPerSecond = width / span
        let videoX = (videoPosition - left) * pixelsPerSecond
        let playheadX = (videoPosition + previewStart - left) * pixelsPerSecond
        let scrub = scrubGesture(left: left, pixelsPerSecond: pixelsPerSecond, videoLength: videoLength,
                                 audioPosition: audioPosition, audioLength: audioLength)
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 7).fill(canvas)
            timeRuler(left: left, span: span, pixelsPerSecond: pixelsPerSecond)
                .frame(height: 24).contentShape(Rectangle()).gesture(scrub)
                .accessibilityLabel("时间标尺，可拖动播放头")
            Rectangle().fill(rule).frame(height: 1).offset(y: 55)
            trackBar("视频", symbol: "film", color: accent, width: videoLength * pixelsPerSecond)
                .gesture(trackDrag(video: true, width: width, left: left, span: span, offset: offset,
                                   videoLength: videoLength, audioLength: audioLength ?? 0))
                .offset(x: videoX, y: 28)
            if let audioLength {
                trackBar("音频", symbol: "waveform", color: accent.opacity(0.68), width: audioLength * pixelsPerSecond, showsSpectrum: true)
                    .gesture(trackDrag(video: false, width: width, left: left, span: span, offset: offset,
                                       videoLength: videoLength, audioLength: audioLength))
                    .offset(x: (audioPosition - left) * pixelsPerSecond, y: 59)
            }
            Rectangle().fill(.secondary.opacity(0.5)).frame(width: 1, height: 64)
                .offset(x: videoX, y: 24).allowsHitTesting(false)
            if let snapGuide {
                Rectangle().strokeBorder(accent, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .frame(width: 2, height: 88)
                    .offset(x: (snapGuide - left) * pixelsPerSecond).allowsHitTesting(false)
            }
            VStack(spacing: 0) {
                Image(systemName: "arrowtriangle.down.fill").font(.system(size: 10))
                Rectangle().frame(width: 1)
            }
            .foregroundStyle(accent)
            .frame(width: 16, height: 88)
            .contentShape(Rectangle())
            .offset(x: playheadX - 8)
            .gesture(scrub)
            .accessibilityLabel("播放头")
            .accessibilityValue("\(previewStart.formatted(secondsFormat)) 秒")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: seekToPreview(previewStart + 0.1)
                case .decrement: seekToPreview(previewStart - 0.1)
                @unknown default: break
                }
            }
        }
        .coordinateSpace(name: "mergeTimeline")
        .clipShape(RoundedRectangle(cornerRadius: 7))
    }

    private func timeRuler(left: Double, span: Double, pixelsPerSecond: Double) -> some View {
        Canvas { context, size in
            let ideal = max(64 / pixelsPerSecond, 0.001)
            let magnitude = pow(10, floor(log10(ideal)))
            let step = ([1.0, 2, 5, 10].first { $0 * magnitude >= ideal } ?? 10) * magnitude
            let first = ceil((left - videoPosition) / step) * step
            let last = left + span - videoPosition
            guard first <= last else { return }
            for tick in stride(from: first, through: last, by: step) {
                let x = (tick + videoPosition - left) * pixelsPerSecond
                var line = Path()
                line.move(to: CGPoint(x: x, y: 18))
                line.addLine(to: CGPoint(x: x, y: size.height))
                context.stroke(line, with: .color(.secondary.opacity(0.55)), lineWidth: 1)
                if x + 34 < size.width {
                    let value = abs(tick) < 0.0005 ? 0 : tick
                    let label = Text(value.formatted(secondsFormat) + "s")
                        .font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
                    context.draw(label, at: CGPoint(x: x + 3, y: 8), anchor: .leading)
                }
            }
        }
    }

    private func scrubGesture(left: Double, pixelsPerSecond: Double, videoLength: Double,
                              audioPosition: Double, audioLength: Double?) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("mergeTimeline"))
            .onChanged { value in
                if !isScrubbing {
                    resumeAfterScrub = preview == nil && (sourcePlayer?.rate ?? 0) > 0
                    sourcePlayer?.pause()
                    lastScrubSeek = 0
                }
                let time = scrubTime(value.location.x, left: left, pixelsPerSecond: pixelsPerSecond,
                                     videoLength: videoLength, audioPosition: audioPosition, audioLength: audioLength)
                seekToPreview(time, final: false)
            }
            .onEnded { value in
                let time = scrubTime(value.location.x, left: left, pixelsPerSecond: pixelsPerSecond,
                                     videoLength: videoLength, audioPosition: audioPosition, audioLength: audioLength)
                snapGuide = nil
                seekToPreview(time, resume: resumeAfterScrub)
                resumeAfterScrub = false
            }
    }

    private func scrubTime(_ x: Double, left: Double, pixelsPerSecond: Double, videoLength: Double,
                           audioPosition: Double, audioLength: Double?) -> Double {
        let proposed = left + x / pixelsPerSecond
        let range = videoPosition...(videoPosition + videoLength)
        var anchors = [range.lowerBound, range.upperBound]
        if let audioLength { anchors += [audioPosition, audioPosition + audioLength] }
        let match = snapping ? TimelineSnap.nearest(position: proposed, edges: [0], anchors: anchors,
                                                     within: range, tolerance: 8 / pixelsPerSecond) : nil
        snapGuide = match?.guide
        return clampedPreview((match?.position ?? proposed) - videoPosition)
    }

    private func trackDrag(video: Bool, width: Double, left: Double, span: Double, offset: Double,
                           videoLength: Double, audioLength: Double) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .named("mergeTimeline"))
            .onChanged { value in
                guard videoLength > 0 && audioLength > 0 else { return }
                let start = dragStart ?? DragStart(position: videoPosition, offset: offset, left: left, span: span,
                                                   playhead: videoPosition + previewStart)
                dragStart = start
                let secondsPerPoint = start.span / width
                let delta = Double(value.translation.width) * secondsPerPoint
                let margin = min(0.01, videoLength / 2, audioLength / 2)
                let audioStart = start.position + start.offset
                let stationary = video ? audioStart : start.position
                let stationaryLength = video ? audioLength : videoLength
                let movingLength = video ? videoLength : audioLength
                let proposed = (video ? start.position : audioStart) + delta
                let range = (stationary - movingLength + margin)...(stationary + stationaryLength - margin)
                let match = snapping ? TimelineSnap.nearest(position: proposed, edges: [0, movingLength],
                    anchors: [stationary, stationary + stationaryLength, start.playhead, 0],
                    within: range, tolerance: 8 * secondsPerPoint) : nil
                let position = match?.position ?? min(max(proposed, range.lowerBound), range.upperBound)
                let newOffset = video ? audioStart - position : position - start.position
                if video { videoPosition = position }
                snapGuide = match?.guide
                store.updateMerge { $0.edit.audioOffset = newOffset }
            }
            .onEnded { _ in dragStart = nil; snapGuide = nil }
    }

    private func clampedPreview(_ requested: Double) -> Double {
        guard requested.isFinite else { return 0 }
        return min(max(requested, 0), videoLength ?? max(requested, 0))
    }

    private func displayLength(_ trim: TrackTrim, duration: Double?) -> Double? {
        guard let end = trim.end ?? duration, end.isFinite, trim.start.isFinite,
              (0...86400).contains(trim.start), (0...86400).contains(end) else { return nil }
        return max(0, end - trim.start)
    }

    private func seekToPreview(_ requested: Double, final: Bool = true, resume: Bool = false) {
        preview = nil
        previewStart = clampedPreview(requested)
        guard let player = sourcePlayer else { isScrubbing = false; return }
        isScrubbing = true
        let now = ProcessInfo.processInfo.systemUptime
        if !final && now - lastScrubSeek < 1.0 / 60 { return }
        lastScrubSeek = now
        let position = min(previewStart, max(0, (videoLength ?? (previewStart + 1)) - 1.0 / 600))
        let target = CMTime(seconds: max(edit.video.start, 0) + position, preferredTimescale: 60000)
        let tolerance: CMTime = final ? .zero : CMTime(value: 1, timescale: 60)
        seekGeneration += 1
        let generation = seekGeneration
        player.seek(to: target, toleranceBefore: tolerance, toleranceAfter: tolerance) { _ in
            guard final else { return }
            Task { @MainActor in
                guard generation == seekGeneration, sourcePlayer === player else { return }
                isScrubbing = false
                if resume { player.play() }
            }
        }
    }

    private func trackBar(_ title: String, symbol: String, color: Color, width: Double, showsSpectrum: Bool = false) -> some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(color.opacity(0.5))
            .overlay {
                if showsSpectrum, let spectrum, let audioDuration, audioDuration > 0 {
                    GeometryReader { geometry in
                        let start = min(max(edit.audio.start / audioDuration, 0), 1)
                        let end = min(max((edit.audio.end ?? audioDuration) / audioDuration, start), 1)
                        let fullWidth = min(geometry.size.width / max(0.00001, end - start), 100_000)
                        Image(nsImage: spectrum).resizable()
                            .interpolation(.medium)
                            .frame(width: fullWidth, height: geometry.size.height)
                            .offset(x: -start * fullWidth)
                    }
                    .clipped().opacity(0.83)
                }
            }
            .overlay(alignment: .leading) {
                if width >= 42 {
                    Label(showsSpectrum && loadingSpectrum ? "分析频谱…" : title, systemImage: symbol)
                        .font(.system(size: 10, weight: .semibold)).foregroundStyle(.white)
                        .lineLimit(1).padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.black.opacity(0.48), in: RoundedRectangle(cornerRadius: 4)).padding(.leading, 4)
                }
            }
            .frame(width: max(width, 1), height: 24)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .contentShape(Rectangle())
    }

}

private struct MergePreview: Identifiable {
    let id = UUID()
    let video: URL
    let audio: URL
    let edit: MergeEdit
    let start: Double
}

private struct MergePreviewView: View {
    @State private var player: AVPlayer?
    @State private var error: String?
    let request: MergePreview
    let toolchain: Toolchain?
    let hardware: VideoHardwareCapabilities
    let onTimeChange: (Double) -> Void

    private var directory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("MediaForge-Preview-\(request.id.uuidString)", isDirectory: true)
    }

    var body: some View {
        Group {
            if let player {
                MergePlayerView(player: player, onTimeChange: onTimeChange)
                    .background(.black, in: RoundedRectangle(cornerRadius: 6))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            } else if let error {
                Text(error).font(.system(size: 12)).textSelection(.enabled).padding(10)
            } else {
                ProgressView("正在准备对齐预览…")
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 200)
        .task { await render() }
        .onDisappear {
            player?.pause()
            player?.replaceCurrentItem(with: nil)
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private func render() async {
        guard let toolchain else { return }
        do {
            try Task.checkCancellation()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            let output = directory.appendingPathComponent("preview.mp4")
            var options = ConversionOptions()
            options.resolution = .p480
            try await FFmpegRunner(toolchain: toolchain, hardware: hardware).processTracks(.merge(
                video: request.video, audio: request.audio, output: output, options: options,
                edit: request.edit, previewStart: request.start
            ))
            try Task.checkCancellation()
            player = AVPlayer(url: output)
            player?.play()
        } catch is CancellationError {
            try? FileManager.default.removeItem(at: directory)
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct MergePlayerView: NSViewRepresentable {
    let player: AVPlayer
    let onTimeChange: (Double) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.videoGravity = .resizeAspect
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        context.coordinator.onTimeChange = onTimeChange
        if view.player !== player {
            view.player = player
            context.coordinator.observe(player)
        }
    }

    static func dismantleNSView(_ view: AVPlayerView, coordinator: Coordinator) {
        coordinator.stopObserving()
        view.player = nil
    }

    final class Coordinator {
        var onTimeChange: ((Double) -> Void)?
        private var player: AVPlayer?
        private var observer: Any?

        func observe(_ player: AVPlayer) {
            stopObserving()
            self.player = player
            observer = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] time in
                let seconds = time.seconds
                if seconds.isFinite { self?.onTimeChange?(seconds) }
            }
        }

        func stopObserving() {
            if let observer { player?.removeTimeObserver(observer) }
            observer = nil
            player = nil
        }
    }
}
