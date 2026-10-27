import AVFoundation
import AVKit
import DropwheelCore
import PDFKit
import SwiftUI

// MARK: - Media model

@MainActor
final class MediaModel: ObservableObject {
    let url: URL
    let isVideo: Bool
    @Published var info: MediaInfo?
    @Published var playhead = 0.0
    @Published var thumbs: [CGImage] = []
    @Published var wave: [Float] = []
    @Published var frame: CGImage?
    @Published var error: String?
    @Published var playing = false
    private(set) var player: AVPlayer?
    private var observer: Any?
    private var stopAt: Double?
    private var frameTask: Task<Void, Never>?
    var wantsFrames = false

    init(url: URL, wantsFrames: Bool = false) {
        self.url = url
        isVideo = kind(of: url) == .video
        self.wantsFrames = wantsFrames
    }

    var duration: Double { info?.duration ?? 0 }

    func load() async {
        let url = url, isVideo = isVideo
        do {
            info = try await Task.detached { try probe(url) }.value
        } catch { self.error = error.localizedDescription; return }
        let asset = AVURLAsset(url: url)
        if (try? await asset.load(.isPlayable)) == true {
            let p = AVPlayer(url: url)
            observer = p.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] t in
                MainActor.assumeIsolated {
                    guard let self, self.playing else { return }
                    self.playhead = t.seconds
                    if let s = self.stopAt, t.seconds >= s { self.pause() }
                }
            }
            player = p
        }
        if isVideo {
            thumbs = await Task.detached { (try? VideoOps.thumbnails(url, count: 16, height: 60)) ?? [] }.value
            if wantsFrames || player == nil { refreshFrame() }
        }
        if info?.hasAudio == true { wave = await Task.detached { (try? AudioOps.waveform(url, buckets: 600))?.first ?? [] }.value }
    }

    func seek(_ t: Double) {
        playhead = max(0, min(duration, t))
        player?.seek(to: CMTime(seconds: playhead, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        if isVideo && (wantsFrames || player == nil) { refreshFrame() }
    }

    func refreshFrame() {
        frameTask?.cancel()
        let url = url, t = playhead
        frameTask = Task {
            try? await Task.sleep(for: .milliseconds(90))
            guard !Task.isCancelled else { return }
            if let f = await Task.detached(operation: { try? VideoOps.frame(url, at: t) }).value, !Task.isCancelled { frame = f }
        }
    }

    func play(_ range: TimeRange? = nil, rate: Float = 1) {
        guard let player else { return }
        if let range { seek(range.start); stopAt = range.end } else { stopAt = nil }
        player.rate = rate
        playing = true
    }

    func pause() { player?.pause(); playing = false; stopAt = nil; if isVideo && wantsFrames { refreshFrame() } }

    deinit { if let observer { player?.removeTimeObserver(observer) } }
}

// MARK: - Timeline

/// A strip of thumbnails or a waveform with a playhead. Overlays get a time-to-x mapping.
struct Timeline<Overlay: View>: View {
    @ObservedObject var m: MediaModel
    var height: CGFloat = 64
    var scrubs = true
    @ViewBuilder var overlay: (_ x: @escaping (Double) -> CGFloat, _ t: @escaping (CGFloat) -> Double) -> Overlay

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, d = max(m.duration, 0.001)
            let x = { (t: Double) in CGFloat(t / d) * w }
            let t = { (x: CGFloat) in max(0, min(d, Double(x / w) * d)) }
            ZStack(alignment: .topLeading) {
                if m.isVideo && !m.thumbs.isEmpty {
                    HStack(spacing: 0) {
                        ForEach(m.thumbs.indices, id: \.self) { i in Image(decorative: m.thumbs[i], scale: 1).resizable().scaledToFill().frame(width: w / CGFloat(m.thumbs.count), height: height).clipped() }
                    }
                } else {
                    Waveform(samples: m.wave).fill(Color.accentColor.opacity(0.8))
                }
                overlay(x, t)
                Rectangle().fill(.white).frame(width: 2, height: height).offset(x: x(m.playhead) - 1).shadow(radius: 1)
                    .accessibilityLabel("Playhead position in seconds").accessibilityValue(String(format: "%.1f", m.playhead))
            }
            .frame(height: height)
            .background(Color.black.opacity(0.6))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
            .gesture(scrubs ? DragGesture(minimumDistance: 0).onChanged { g in m.pause(); m.seek(t(g.location.x)) } : nil)
        }
        .frame(height: height)
    }
}

struct Waveform: Shape {
    let samples: [Float]
    func path(in r: CGRect) -> Path {
        var p = Path()
        guard !samples.isEmpty else { return p }
        let peak = max(samples.max() ?? 1, 0.05)
        let step = r.width / CGFloat(samples.count)
        for (i, s) in samples.enumerated() {
            let h = max(1, CGFloat(s / peak) * r.height * 0.9)
            p.addRect(CGRect(x: CGFloat(i) * step, y: r.midY - h / 2, width: max(1, step * 0.7), height: h))
        }
        return p
    }
}

/// Two handles that select one range on a timeline.
struct RangeHandles: View {
    @Binding var range: TimeRange
    let x: (Double) -> CGFloat
    let t: (CGFloat) -> Double
    var height: CGFloat = 64
    var body: some View {
        let a = x(range.start), b = x(range.end)
        ZStack(alignment: .topLeading) {
            Rectangle().fill(.black.opacity(0.55)).frame(width: max(0, a), height: height)
            // t clamps to the duration, so x(t(.infinity)) is the full width.
            Rectangle().fill(.black.opacity(0.55)).frame(width: max(0, x(t(.greatestFiniteMagnitude)) - b), height: height).offset(x: b)
            RoundedRectangle(cornerRadius: 3).stroke(Color.yellow, lineWidth: 3).frame(width: max(2, b - a), height: height).offset(x: a)
            handle.offset(x: a - 7).gesture(DragGesture().onChanged { g in range = TimeRange(min(t(a + g.translation.width), range.end - 0.1), range.end) })
                .accessibilityLabel("Start time in seconds")
            handle.offset(x: b - 7).gesture(DragGesture().onChanged { g in range = TimeRange(range.start, max(t(b + g.translation.width), range.start + 0.1)) })
                .accessibilityLabel("End time in seconds")
        }
    }
    var handle: some View { RoundedRectangle(cornerRadius: 4).fill(Color.yellow).frame(width: 14, height: height) }
}

/// Video player when AVFoundation can play the file, otherwise a still frame at the playhead.
struct MediaPreview: View {
    @ObservedObject var m: MediaModel
    var body: some View {
        Group {
            if let p = m.player, m.isVideo { PlayerView(player: p) }
            else if let f = m.frame { Image(decorative: f, scale: 1).resizable().scaledToFit() }
            else if !m.isVideo { Image(systemName: "waveform").font(.system(size: 80)).foregroundStyle(.secondary) }
            else { ProgressView("Loading video") }
        }
        .accessibilityLabel("Video preview at \(timecode(m.playhead))")
    }
}

/// SwiftUI's VideoPlayer crashes when AVKit is not linked by Xcode, so wrap AVPlayerView directly.
struct PlayerView: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> AVPlayerView {
        let v = AVPlayerView(); v.player = player; v.controlsStyle = .minimal; return v
    }
    func updateNSView(_ v: AVPlayerView, context: Context) { v.player = player }
}

struct MediaLoaded<V: View>: View {
    @ObservedObject var m: MediaModel
    @ViewBuilder let content: () -> V
    var body: some View {
        Group {
            if let e = m.error { ContentUnavailableView("Could not open the file", systemImage: "exclamationmark.triangle", description: Text(e)) }
            else if m.info == nil { ProgressView("Loading file details") }
            else { content() }
        }
        .task { if m.info == nil { await m.load() } }
    }
}

struct TransportBar: View {
    @ObservedObject var m: MediaModel
    var range: TimeRange?
    var body: some View {
        HStack {
            Button { m.playing ? m.pause() : m.play() } label: { Image(systemName: m.playing ? "pause.fill" : "play.fill") }.disabled(m.player == nil)
                .keyboardShortcut(.space, modifiers: [])
            if let range { Button("Play Selected Range") { m.play(range) }.disabled(m.player == nil) }
            Spacer()
            Text("\(timecode(m.playhead)) / \(timecode(m.duration))").monospacedDigit().foregroundStyle(.secondary)
        }
    }
}

func secondsField(_ label: String, _ value: Binding<Double>) -> some View {
    TextField(label, value: value, format: .number.precision(.fractionLength(2))).frame(width: 80)
}

// MARK: - Trim

struct TrimEditor: View {
    @StateObject var m: MediaModel
    let close: () -> Void
    @State private var range = TimeRange(0, 0)
    @State private var silentEnds = false
    @State private var threshold = -50.0
    @State private var detected: TimeRange?

    init(url: URL, close: @escaping () -> Void) { _m = StateObject(wrappedValue: MediaModel(url: url)); self.close = close }

    var body: some View {
        MediaLoaded(m: m) {
            VStack(spacing: 12) {
                MediaPreview(m: m).frame(maxHeight: .infinity)
                Timeline(m: m) { x, t in
                    ZStack(alignment: .topLeading) {
                        RangeHandles(range: $range, x: x, t: t)
                        if silentEnds, let d = detected {
                            Rectangle().fill(.red.opacity(0.35)).frame(width: max(0, x(d.start)), height: 64)
                            Rectangle().fill(.red.opacity(0.35)).frame(width: max(0, x(m.duration) - x(d.end)), height: 64).offset(x: x(d.end))
                        }
                    }
                }
                Text("Drag the ends to trim").font(.caption).foregroundStyle(.secondary)
                HStack {
                    TransportBar(m: m, range: range)
                    secondsField("Start", Binding(get: { range.start }, set: { range = TimeRange(max(0, $0), range.end) }))
                    secondsField("End", Binding(get: { range.end }, set: { range = TimeRange(range.start, min(m.duration, $0)) }))
                }
                if !m.isVideo {
                    HStack {
                        Toggle("Trim silent ends automatically", isOn: $silentEnds)
                        if silentEnds {
                            Slider(value: $threshold, in: -70...(-20)) { Text("Silence threshold") }.frame(width: 220)
                                .accessibilityLabel("Silence threshold in decibels")
                            Text("\(Int(threshold)) dB").monospacedDigit()
                        }
                        Spacer()
                    }
                }
                HStack {
                    Spacer()
                    Button("Cancel", action: close).keyboardShortcut(.cancelAction)
                    Button("Save Trimmed Copy") { save() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                }
            }
            .padding()
            .onAppear { range = TimeRange(0, m.duration) }
            .task(id: "\(silentEnds)\(threshold)") {
                guard silentEnds else { detected = nil; return }
                let u = m.url, th = threshold
                detected = await Task.detached { try? AudioOps.detectSilentEnds(u, thresholdDB: th) }.value
            }
        }
    }

    func save() {
        let u = m.url, r = range, full = r.start < 0.01 && r.end > m.duration - 0.01, silent = silentEnds, th = threshold
        Editors.save("Trimming", [u], close: close) { p, c in
            if kind(of: u) == .video { return [try VideoOps.trim(u, r, progress: p, cancel: c)] }
            return [try AudioOps.trim(u, full ? nil : r, silentEnds: silent, thresholdDB: th, progress: p, cancel: c)]
        }
    }
}

// MARK: - Split

struct SplitEditor: View {
    @StateObject var m: MediaModel
    let close: () -> Void
    @State private var cuts: [Double] = []
    @State private var dropped: Set<Int> = []
    @State private var mode = SplitExportMode.separateVideos

    init(url: URL, close: @escaping () -> Void) { _m = StateObject(wrappedValue: MediaModel(url: url)); self.close = close }

    var segments: [TimeRange] {
        let points = [0] + cuts.sorted() + [m.duration]
        return zip(points, points.dropFirst()).map { TimeRange($0, $1) }
    }

    var body: some View {
        MediaLoaded(m: m) {
            VStack(spacing: 12) {
                MediaPreview(m: m).frame(maxHeight: .infinity)
                Timeline(m: m) { x, _ in
                    ZStack(alignment: .topLeading) {
                        ForEach(segments.indices, id: \.self) { i in
                            if dropped.contains(i) { Rectangle().fill(.black.opacity(0.65)).frame(width: x(segments[i].end) - x(segments[i].start), height: 64).offset(x: x(segments[i].start)) }
                        }
                        ForEach(cuts, id: \.self) { c in Rectangle().fill(.yellow).frame(width: 3, height: 64).offset(x: x(c) - 1.5) }
                    }
                }
                HStack {
                    TransportBar(m: m)
                    Button("Split at Playhead") { if m.playhead > 0.1, m.playhead < m.duration - 0.1, !cuts.contains(m.playhead) { cuts.append(m.playhead); dropped = [] } }
                    Button("Clear") { cuts = []; dropped = [] }.disabled(cuts.isEmpty)
                }
                ScrollView(.horizontal) {
                    HStack {
                        ForEach(segments.indices, id: \.self) { i in
                            Toggle(isOn: Binding(get: { !dropped.contains(i) }, set: { if $0 { dropped.remove(i) } else { dropped.insert(i) } })) {
                                Text("Part \(i + 1): \(timecode(segments[i].start))–\(timecode(segments[i].end))")
                            }.toggleStyle(.button)
                        }
                    }
                }
                HStack {
                    Picker("", selection: $mode) { Text("Export Separate Videos").tag(SplitExportMode.separateVideos); Text("Export One Video").tag(SplitExportMode.oneVideo) }
                        .pickerStyle(.segmented).frame(width: 340)
                    Spacer()
                    Button("Cancel", action: close).keyboardShortcut(.cancelAction)
                    Button("Export") {
                        let kept = segments.enumerated().filter { !dropped.contains($0.offset) }.map(\.element), u = m.url, mode = mode
                        Editors.save("Splitting video", [u], close: close) { p, c in try VideoOps.split(u, segments: kept, mode: mode, progress: p, cancel: c) }
                    }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).disabled(cuts.isEmpty && dropped.isEmpty || dropped.count == segments.count)
                }
            }.padding()
        }
    }
}

// MARK: - Video crop

struct VideoCropEditor: View {
    @StateObject var m: MediaModel
    let close: () -> Void
    @State private var rect = CGRect.zero
    @State private var aspect: CGFloat?

    init(url: URL, close: @escaping () -> Void) { _m = StateObject(wrappedValue: MediaModel(url: url, wantsFrames: true)); self.close = close }

    var body: some View {
        MediaLoaded(m: m) {
            let size = CGSize(width: m.info?.width ?? 1, height: m.info?.height ?? 1)
            EditorShell(primary: "Save Cropped Video", enabled: rect.width >= 16 && rect.height >= 16, close: close, save: {
                let u = m.url, r = rect
                Editors.save("Cropping video", [u], close: close) { p, c in [try VideoOps.crop(u, rect: r, progress: p, cancel: c)] }
            }) {
                VStack {
                    if let f = m.frame { CropView(image: f, rect: $rect, aspect: aspect) } else { ProgressView() }
                    Timeline(m: m, height: 44) { _, _ in EmptyView() }.padding(8)
                }
            } side: { CropControls(size: size, rect: $rect, aspect: $aspect) }
            .onAppear { rect = CGRect(origin: .zero, size: size).insetBy(dx: size.width / 10, dy: size.height / 10).integral }
        }
    }
}

// MARK: - Speed

struct SpeedEditor: View {
    @StateObject var m: MediaModel
    let close: () -> Void
    @State private var factor = 2.0
    init(url: URL, close: @escaping () -> Void) { _m = StateObject(wrappedValue: MediaModel(url: url)); self.close = close }

    var body: some View {
        MediaLoaded(m: m) {
            VStack(spacing: 14) {
                MediaPreview(m: m).frame(maxHeight: .infinity)
                    .accessibilityLabel("Video speed preview at \(String(format: "%g", factor))×")
                HStack {
                    Button { m.playing ? m.pause() : m.play(rate: Float(factor)) } label: { Label(m.playing ? "Pause" : "Preview", systemImage: m.playing ? "pause.fill" : "play.fill") }
                    Slider(value: $factor, in: 0.25...4, step: 0.05)
                    Text(String(format: "%.2f×", factor)).monospacedDigit().frame(width: 56)
                }
                HStack {
                    ForEach([0.25, 0.5, 0.75, 1.5, 2, 3, 4], id: \.self) { v in Button(String(format: "%g×", v)) { factor = v } }
                }
                Text("New length: \(timecode(m.duration / factor))").foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("Cancel", action: close).keyboardShortcut(.cancelAction)
                    Button("Save") {
                        let u = m.url, f = factor
                        Editors.save("Changing speed", [u], close: close) { p, c in [try VideoOps.changeSpeed(u, factor: f, progress: p, cancel: c)] }
                    }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).disabled(abs(factor - 1) < 0.01)
                }
            }.padding()
        }
    }
}

// MARK: - Frames

struct FramesEditor: View {
    @StateObject var m: MediaModel
    let close: () -> Void
    @State private var frames: [(Double, CGImage)] = []
    @State private var selected: Int?
    init(url: URL, close: @escaping () -> Void) { _m = StateObject(wrappedValue: MediaModel(url: url, wantsFrames: true)); self.close = close }

    var body: some View {
        MediaLoaded(m: m) {
            VStack(spacing: 12) {
                Group { if let f = m.frame { Image(decorative: f, scale: 1).resizable().scaledToFit() } else { ProgressView() } }
                    .frame(maxHeight: .infinity).accessibilityLabel("Preview selected frame")
                Timeline(m: m) { x, _ in
                    ForEach(frames.indices, id: \.self) { i in Circle().fill(.yellow).frame(width: 10, height: 10).offset(x: x(frames[i].0) - 5, y: 4) }
                }
                HStack {
                    TransportBar(m: m)
                    Button("Add Frame") {
                        if let f = m.frame, !frames.contains(where: { abs($0.0 - m.playhead) < 0.01 }) { frames.append((m.playhead, f)); frames.sort { $0.0 < $1.0 } }
                    }.keyboardShortcut("a", modifiers: [])
                }
                ScrollView(.horizontal) {
                    HStack {
                        ForEach(frames.indices, id: \.self) { i in
                            VStack {
                                Image(decorative: frames[i].1, scale: 1).resizable().scaledToFit().frame(height: 70)
                                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(selected == i ? Color.accentColor : .clear, lineWidth: 2))
                                Text(timecode(frames[i].0)).font(.caption2)
                            }
                            .onTapGesture { selected = i; m.seek(frames[i].0) }
                            .contextMenu { Button("Remove frame at \(timecode(frames[i].0))") { frames.remove(at: i); selected = nil } }
                        }
                    }
                }.frame(height: frames.isEmpty ? 0 : 96)
                HStack {
                    Button("Remove selected frame") { if let s = selected { frames.remove(at: s); selected = nil } }.disabled(selected == nil)
                    Spacer()
                    Button("Cancel", action: close).keyboardShortcut(.cancelAction)
                    Button("Save \(frames.count) Snapshot\(frames.count == 1 ? "" : "s")") {
                        let u = m.url, times = frames.map(\.0)
                        Editors.save("Saving snapshots", [u], close: close) { _, c in [try VideoOps.exportFrames(u, at: times, cancel: c)] }
                    }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).disabled(frames.isEmpty)
                }
            }.padding()
        }
    }
}

// MARK: - Video redact

struct VideoRedactEditor: View {
    @StateObject var m: MediaModel
    let close: () -> Void
    @State private var rects: [CGRect] = []
    @State private var ranges: [TimeRange?] = []
    @State private var selected: Int?
    @State private var style = RedactionStyle.blur
    init(url: URL, close: @escaping () -> Void) { _m = StateObject(wrappedValue: MediaModel(url: url, wantsFrames: true)); self.close = close }

    var body: some View {
        MediaLoaded(m: m) {
            EditorShell(primary: "Save Redacted Copy", enabled: !rects.isEmpty, close: close, save: {
                let items = zip(rects, ranges).map { VideoRedaction(rect: $0, range: $1) }, u = m.url, s = style
                Editors.save("Redacting video", [u], close: close) { p, c in [try VideoOps.redact(u, items, style: s, progress: p, cancel: c)] }
            }) {
                VStack {
                    if let f = m.frame {
                        RectsCanvas(image: f, rects: $rects, selected: $selected, style: style) { i in ranges.indices.contains(i) ? (ranges[i]?.start ?? 0) <= m.playhead && m.playhead <= (ranges[i]?.end ?? .infinity) : true }
                    } else { ProgressView() }
                    Timeline(m: m, height: 50) { x, t in
                        if let s = selected, ranges.indices.contains(s), ranges[s] != nil {
                            RangeHandles(range: Binding(get: { ranges[s]! }, set: { ranges[s] = $0 }), x: x, t: t, height: 50)
                        }
                    }.padding(8)
                }
                .onChange(of: rects.count) { old, new in
                    // New rectangles start at the playhead and last two seconds.
                    if new > ranges.count { ranges.append(TimeRange(m.playhead, min(m.duration, m.playhead + 2))) }
                    else if new < ranges.count, let s = selected ?? ranges.indices.last { ranges.remove(at: min(s, ranges.count - 1)) }
                }
            } side: {
                Text("Drag over the area to hide, then set when it shows.").foregroundStyle(.secondary)
                Picker("Style", selection: $style) { Text("Blur").tag(RedactionStyle.blur); Text("Solid").tag(RedactionStyle.solid) }.pickerStyle(.segmented)
                if let s = selected, ranges.indices.contains(s) {
                    Text("Redaction \(s + 1)").font(.headline)
                    Toggle("Show for Entire Video", isOn: Binding(get: { ranges[s] == nil }, set: { ranges[s] = $0 ? nil : TimeRange(m.playhead, min(m.duration, m.playhead + 2)) }))
                    if let r = ranges[s] {
                        Text("\(timecode(r.start)) – \(timecode(r.end))").monospacedDigit()
                        Button("Start at playhead") { ranges[s] = TimeRange(m.playhead, max(m.playhead + 0.1, r.end)) }
                        Button("End at playhead") { ranges[s] = TimeRange(min(r.start, m.playhead - 0.1), m.playhead) }
                    }
                    Button("Delete Redaction") { rects.remove(at: s); selected = nil }
                }
                Button("Add redaction at playhead") { rects.append(CGRect(x: 20, y: 20, width: 160, height: 100)); selected = rects.count - 1 }
            }
        }
    }
}

// MARK: - Bleep

struct BleepEditor: View {
    @StateObject var m: MediaModel
    let close: () -> Void
    @State private var ranges: [TimeRange] = []
    @State private var selected: Int?
    @State private var tone = true
    @State private var drawing: TimeRange?
    init(url: URL, close: @escaping () -> Void) { _m = StateObject(wrappedValue: MediaModel(url: url)); self.close = close }

    var body: some View {
        MediaLoaded(m: m) {
            VStack(spacing: 12) {
                Text("Drag to add a bleep. Click to move the playhead.").foregroundStyle(.secondary)
                Timeline(m: m, height: 120, scrubs: false) { x, t in
                    ZStack(alignment: .topLeading) {
                        ForEach(Array((ranges + (drawing.map { [$0] } ?? [])).enumerated()), id: \.offset) { i, r in
                            Rectangle().fill(Color.red.opacity(selected == i ? 0.6 : 0.4))
                                .overlay(Rectangle().stroke(selected == i ? .white : .clear))
                                .frame(width: max(2, x(r.end) - x(r.start)), height: 120).offset(x: x(r.start))
                        }
                        Color.clear.contentShape(Rectangle())
                            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                                if abs(g.translation.width) > 3 { drawing = TimeRange(t(g.startLocation.x), t(g.location.x)) }
                            }.onEnded { g in
                                if let d = drawing, d.duration > 0.05 { ranges.append(d); selected = ranges.count - 1 }
                                else {
                                    let tt = t(g.location.x)
                                    selected = ranges.firstIndex { $0.start <= tt && tt <= $0.end }
                                    m.seek(tt)
                                }
                                drawing = nil
                            })
                    }
                }
                .accessibilityLabel("Audio redaction timeline")
                HStack {
                    TransportBar(m: m, range: selected.map { ranges[$0] })
                    Button("Add bleep at playhead") { ranges.append(TimeRange(m.playhead, min(m.duration, m.playhead + 0.6))); selected = ranges.count - 1 }
                    Button("Delete") { if let s = selected { ranges.remove(at: s); selected = nil } }.disabled(selected == nil)
                    Button("Bleep Entire Audio") { ranges = [TimeRange(0, m.duration)]; selected = 0 }
                }
                if let s = selected, ranges.indices.contains(s) {
                    HStack {
                        Text("Bleep \(s + 1)")
                        secondsField("Start", Binding(get: { ranges[s].start }, set: { ranges[s] = TimeRange($0, ranges[s].end) }))
                        secondsField("End", Binding(get: { ranges[s].end }, set: { ranges[s] = TimeRange(ranges[s].start, $0) }))
                        Spacer()
                    }
                }
                HStack {
                    Picker("Sound", selection: $tone) { Text("Bleep tone").tag(true); Text("Silence").tag(false) }.pickerStyle(.segmented).frame(width: 240)
                    Spacer()
                    Button("Cancel", action: close).keyboardShortcut(.cancelAction)
                    Button("Save Bleeped Copy") {
                        let u = m.url, r = ranges, tone = tone
                        Editors.save("Bleeping", [u], close: close) { p, c in [try AudioOps.bleep(u, ranges: r, tone: tone, progress: p, cancel: c)] }
                    }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).disabled(ranges.isEmpty)
                }
            }
            .padding()
            .onDeleteCommand { if let s = selected { ranges.remove(at: s); selected = nil } }
        }
    }
}

// MARK: - Normalize

struct NormalizeEditor: View {
    let urls: [URL]
    let close: () -> Void
    @State private var target = -16.0
    var body: some View {
        Form {
            Picker("Target loudness", selection: $target) {
                Text("Streaming music (−14 LUFS)").tag(-14.0)
                Text("Podcasts and voice (−16 LUFS)").tag(-16.0)
                Text("Video and social (−18 LUFS)").tag(-18.0)
                Text("Broadcast, EBU R128 (−23 LUFS)").tag(-23.0)
            }.pickerStyle(.radioGroup)
            Text("Dropwheel measures each file first, then adjusts it in a second pass so peaks stay under −1.5 dBTP.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel", action: close)
                Button("Normalize Volume") {
                    let urls = urls, t = target
                    Editors.save("Normalizing volume", urls, close: close) { p, c in try urls.map { try AudioOps.normalize($0, targetLUFS: t, progress: p, cancel: c) } }
                }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            }
        }.formStyle(.grouped).padding()
    }
}

// MARK: - Channels

struct ChannelsEditor: View {
    let url: URL
    let close: () -> Void
    enum Mode: String, CaseIterable { case mono = "Mono", stereo = "Stereo", left = "Left to both", right = "Right to both", swap = "Swap", custom = "Custom volume" }
    @State private var mode = Mode.mono
    @State private var left = 1.0
    @State private var right = 1.0
    @State private var waves: [[Float]] = []

    var channelMode: ChannelMode {
        switch mode {
        case .mono: return .mono
        case .stereo: return .stereo
        case .left: return .leftToBoth
        case .right: return .rightToBoth
        case .swap: return .swap
        case .custom: return .volumes(left: left, right: right)
        }
    }

    /// Approximate output waveforms, computed from the input peaks.
    var output: [[Float]] {
        guard let l = waves.first else { return [] }
        let r = waves.count > 1 ? waves[1] : l
        switch mode {
        case .mono: return [zip(l, r).map { ($0 + $1) / 2 }]
        case .stereo: return [l, r]
        case .left: return [l, l]
        case .right: return [r, r]
        case .swap: return [r, l]
        case .custom: return [l.map { $0 * Float(left) }, r.map { $0 * Float(right) }]
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Input").font(.headline)
            ForEach(waves.indices, id: \.self) { i in row(i == 0 ? (waves.count == 1 ? "Mono" : "Left") : "Right", waves[i], .secondary) }
            Picker("Output", selection: $mode) { ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented)
            if mode == .custom {
                HStack { Text("Left volume"); Slider(value: $left, in: 0...2); Text("\(Int(left * 100))%").monospacedDigit().frame(width: 48) }
                HStack { Text("Right volume"); Slider(value: $right, in: 0...2); Text("\(Int(right * 100))%").monospacedDigit().frame(width: 48) }
            }
            Text("Output channel preview").font(.headline)
            ForEach(output.indices, id: \.self) { i in row(output.count == 1 ? "Mono" : i == 0 ? "Left" : "Right", output[i], .accentColor) }
            Spacer()
            HStack {
                Spacer()
                Button("Cancel", action: close).keyboardShortcut(.cancelAction)
                Button("Convert Channels") {
                    let u = url, cm = channelMode
                    Editors.save("Converting channels", [u], close: close) { p, c in [try AudioOps.channels(u, cm, progress: p, cancel: c)] }
                }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .task { let u = url; waves = await Task.detached { (try? AudioOps.waveform(u, buckets: 300, perChannel: true)) ?? [] }.value }
    }

    func row(_ name: String, _ w: [Float], _ color: Color) -> some View {
        HStack { Text(name).frame(width: 44, alignment: .leading).font(.caption); Waveform(samples: w).fill(color).frame(height: 40) }
    }
}

// MARK: - Visualizer

struct VisualizerEditor: View {
    let url: URL
    @State var image: URL?
    let close: () -> Void
    @State private var style = VisualizationStyle.wave
    @State private var color = Color.white
    @State private var still: CGImage?
    @State private var wave: [Float] = []

    var hex: String {
        let c = NSColor(color).usingColorSpace(.sRGB) ?? .white
        return String(format: "%02x%02x%02x", Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255))
    }

    var body: some View {
        EditorShell(primary: "Create Visualization", close: close, save: {
            let u = url, img = image, s = style, h = hex
            Editors.save("Creating visualization", [u], close: close) { p, c in [try AudioOps.visualize(u, image: img, style: s, color: h, progress: p, cancel: c)] }
        }) {
            ZStack(alignment: .bottom) {
                if let still { Image(decorative: still, scale: 1).resizable().scaledToFill() } else { Color(white: 0.07) }
                Waveform(samples: style == .bars ? stride(from: 0, to: wave.count, by: 12).map { wave[$0] } : wave)
                    .fill(style == .spectrum ? AnyShapeStyle(LinearGradient(colors: [.purple, .orange], startPoint: .bottom, endPoint: .top)) : AnyShapeStyle(color))
                    .frame(height: 120).padding(.bottom, 40)
            }
            .aspectRatio(16 / 9, contentMode: .fit).clipped().padding()
            .accessibilityLabel("Waveform visualization preview")
        } side: {
            Button(image == nil ? "Choose a static image" : image!.lastPathComponent) {
                let p = NSOpenPanel(); p.allowedContentTypes = [.image]
                if p.runModal() == .OK { image = p.url }
            }
            if image != nil { Button("Use a solid background") { image = nil } }
            Picker("Visualization style", selection: $style) {
                Text("Wave").tag(VisualizationStyle.wave); Text("Line").tag(VisualizationStyle.line); Text("Bars").tag(VisualizationStyle.bars); Text("Spectrum").tag(VisualizationStyle.spectrum)
            }.pickerStyle(.radioGroup)
            if style != .spectrum { ColorPicker("Color", selection: $color) }
            Text("The video has the length of the audio and plays it in full.").font(.caption).foregroundStyle(.secondary)
        }
        .task(id: image) {
            let i = image
            still = await Task.detached { i.flatMap { try? ImageOps.scaled(try ImageOps.load($0), maxSide: 1200) } }.value
        }
        .task { let u = url; wave = await Task.detached { (try? AudioOps.waveform(u, buckets: 240))?.first ?? [] }.value }
    }
}

// MARK: - PDF organize

struct OrganizeEditor: View {
    let url: URL
    let close: () -> Void
    @State private var pages: [PageEdit] = []
    @State private var thumbs: [Int: NSImage] = [:]
    @State private var selection: Set<Int> = []
    @State private var dragging: PageEdit?

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 16)], spacing: 16) {
                    ForEach(Array(pages.enumerated()), id: \.element) { pos, p in
                        VStack(spacing: 6) {
                            Group {
                                if let t = thumbs[p.index] { Image(nsImage: t).resizable().scaledToFit().rotationEffect(.degrees(Double(p.rotation))) }
                                else { Rectangle().fill(.gray.opacity(0.2)) }
                            }
                            .frame(width: 130, height: 170)
                            .overlay(RoundedRectangle(cornerRadius: 4).stroke(selection.contains(pos) ? Color.accentColor : .gray.opacity(0.4), lineWidth: selection.contains(pos) ? 3 : 1))
                            Text("Page \(p.index + 1)").font(.caption)
                        }
                        .onTapGesture { if NSEvent.modifierFlags.contains(.command) { selection.formSymmetricDifference([pos]) } else { selection = [pos] } }
                        .onDrag { dragging = p; return NSItemProvider(object: "\(p.index)" as NSString) }
                        .onDrop(of: [.text], delegate: PageDrop(target: p, pages: $pages, dragging: $dragging))
                    }
                }.padding()
            }
            Divider()
            HStack {
                Button { rotate(-90) } label: { Label("Rotate Left", systemImage: "rotate.left") }.disabled(selection.isEmpty)
                Button { rotate(90) } label: { Label("Rotate Right", systemImage: "rotate.right") }.disabled(selection.isEmpty)
                Button(role: .destructive) { pages = pages.enumerated().filter { !selection.contains($0.offset) }.map(\.element); selection = [] } label: { Label("Delete", systemImage: "trash") }
                    .disabled(selection.isEmpty || selection.count == pages.count)
                Button("Reverse") { pages.reverse(); selection = [] }
                Spacer()
                Text("\(pages.count) pages").foregroundStyle(.secondary)
                Button("Cancel", action: close).keyboardShortcut(.cancelAction)
                Button("Save Organized PDF") {
                    let u = url, p = pages
                    Editors.save("Organizing pages", [u], close: close) { _, _ in [try PDFOps.organize(u, pages: p)] }
                }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            }.padding(12)
        }
        .onDeleteCommand { if !selection.isEmpty, selection.count < pages.count { pages = pages.enumerated().filter { !selection.contains($0.offset) }.map(\.element); selection = [] } }
        .task {
            guard let doc = PDFDocument(url: url) else { return }
            pages = (0..<doc.pageCount).map { PageEdit(index: $0) }
            for i in 0..<doc.pageCount { thumbs[i] = doc.page(at: i)?.thumbnail(of: CGSize(width: 260, height: 340), for: .mediaBox) }
        }
    }

    func rotate(_ deg: Int) { for i in selection { pages[i].rotation = (pages[i].rotation + deg + 360) % 360 } }
}

struct PageDrop: DropDelegate {
    let target: PageEdit
    @Binding var pages: [PageEdit]
    @Binding var dragging: PageEdit?
    func dropEntered(info: DropInfo) {
        guard let d = dragging, d != target, let from = pages.firstIndex(of: d), let to = pages.firstIndex(of: target) else { return }
        withAnimation { pages.move(fromOffsets: [from], toOffset: to > from ? to + 1 : to) }
    }
    func performDrop(info: DropInfo) -> Bool { dragging = nil; return true }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
}
