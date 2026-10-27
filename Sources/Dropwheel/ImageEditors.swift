import AppKit
import DropwheelCore
import SwiftUI

// MARK: - Editor router

@MainActor
enum Editors {
    static func open(_ action: Action, _ urls: [URL]) {
        let id = "editor-\(UUID().uuidString)"
        let close = { Windows.close(id) }
        let url = urls[0]
        let k = kind(of: url)
        let name = url.lastPathComponent
        func show<V: View>(_ title: String, _ w: CGFloat = 820, _ h: CGFloat = 620, _ v: V) {
            Windows.show(id, title: "\(title) — \(name)", size: CGSize(width: w, height: h)) { v }
        }
        switch (action.id, k) {
        case ("crop", .image): show("Crop", 820, 620, ImageCropEditor(url: url, close: close))
        case ("resize", .image): show("Resize", 420, 300, ResizeEditor(urls: urls, close: close))
        case ("annotate", .image): show("Annotate Photo", 960, 700, AnnotateEditor(url: url, close: close))
        case ("redact", .image): show("Redact", 900, 660, ImageRedactEditor(url: url, close: close))
        case ("background", .image): show("Change image background", 820, 640, BackgroundEditor(url: url, close: close))
        case ("adjust", .image): show("Adjust", 900, 620, AdjustEditor(url: url, close: close))
        case ("metadata", .image): show("Metadata", 560, 620, MetadataEditor(url: url, close: close))
        case ("collage", .image): show("Collage", 900, 660, CollageEditor(urls: urls, close: close))
        case ("trim", _): show("Trim", 860, 600, TrimEditor(url: url, close: close))
        case ("split", _): show("Split", 860, 620, SplitEditor(url: url, close: close))
        case ("crop", .video): show("Crop Video", 860, 640, VideoCropEditor(url: url, close: close))
        case ("speed", _): show("Change Video Speed", 760, 560, SpeedEditor(url: url, close: close))
        case ("frames", _): show("Export Frames", 900, 640, FramesEditor(url: url, close: close))
        case ("redact", .video): show("Redact Video", 960, 700, VideoRedactEditor(url: url, close: close))
        case ("bleep", _): show("Bleep", 900, 520, BleepEditor(url: url, close: close))
        case ("normalize", _): show("Normalize Volume", 480, 340, NormalizeEditor(urls: urls, close: close))
        case ("channels", _): show("Convert Audio Channels", 640, 460, ChannelsEditor(url: url, close: close))
        case ("visualizer", _):
            let audio = urls.first { kind(of: $0) == .audio } ?? url
            Windows.show(id, title: "Audio Visualizer — \(audio.lastPathComponent)", size: CGSize(width: 720, height: 560)) {
                VisualizerEditor(url: audio, image: urls.first { kind(of: $0) == .image }, close: close)
            }
        case ("organize", .pdf): show("Organize Pages", 900, 680, OrganizeEditor(url: url, close: close))
        default: Alerts.show("Unsupported file type", "\(action.title) does not work with \(name).")
        }
    }

    /// Saves through the task store so progress, free uses and errors behave like any other action.
    static func save(_ title: String, _ urls: [URL], close: () -> Void, _ work: @escaping @Sendable (@escaping DropwheelCore.Progress, Cancellation) throws -> [URL]) {
        TaskStore.shared.run(title, urls, work: work)
        close()
    }
}

// MARK: - Shared pieces

struct EditorShell<Content: View, Side: View>: View {
    let primary: String
    var enabled = true
    let close: () -> Void
    let save: () -> Void
    @ViewBuilder let content: Content
    @ViewBuilder let side: Side

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                content.frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.black.opacity(0.85))
                if !(side is EmptyView) {
                    Divider()
                    ScrollView { VStack(alignment: .leading, spacing: 14) { side }.padding(16) }.frame(width: 250)
                }
            }
            Divider()
            HStack {
                Spacer()
                Button("Cancel", action: close).keyboardShortcut(.cancelAction)
                Button(primary, action: save).keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).disabled(!enabled)
            }.padding(12)
        }
    }
}

extension EditorShell where Side == EmptyView {
    init(primary: String, enabled: Bool = true, close: @escaping () -> Void, save: @escaping () -> Void, @ViewBuilder content: () -> Content) {
        self.init(primary: primary, enabled: enabled, close: close, save: save, content: content, side: { EmptyView() })
    }
}

/// Maps between image pixels (top-left origin) and the fitted view.
struct Fit {
    let scale: CGFloat, origin: CGPoint, size: CGSize
    init(image: CGSize, in view: CGSize, padding: CGFloat = 16) {
        let avail = CGSize(width: max(1, view.width - 2 * padding), height: max(1, view.height - 2 * padding))
        scale = min(avail.width / max(image.width, 1), avail.height / max(image.height, 1))
        size = CGSize(width: image.width * scale, height: image.height * scale)
        origin = CGPoint(x: (view.width - size.width) / 2, y: (view.height - size.height) / 2)
    }
    func view(_ p: CGPoint) -> CGPoint { CGPoint(x: origin.x + p.x * scale, y: origin.y + p.y * scale) }
    func image(_ p: CGPoint) -> CGPoint { CGPoint(x: (p.x - origin.x) / scale, y: (p.y - origin.y) / scale) }
    func view(_ r: CGRect) -> CGRect { CGRect(origin: view(r.origin), size: CGSize(width: r.width * scale, height: r.height * scale)) }
    var frame: CGRect { CGRect(origin: origin, size: size) }
}

extension CGImage { var size: CGSize { CGSize(width: width, height: height) } }

func rectFrom(_ a: CGPoint, _ b: CGPoint) -> CGRect { CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y)) }

/// Loads an image off the main thread for an editor.
struct Loaded<T, V: View>: View {
    let load: @Sendable () throws -> T
    @ViewBuilder let content: (T) -> V
    @State private var value: T?
    @State private var error: String?
    var body: some View {
        Group {
            if let value { content(value) }
            else if let error { ContentUnavailableView("Could not open the file", systemImage: "exclamationmark.triangle", description: Text(error)) }
            else { ProgressView("Loading preview") }
        }
        .task {
            let load = self.load
            let r = await Task.detached { Result { try load() } }.value
            switch r { case .success(let v): value = v; case .failure(let e): error = e.localizedDescription }
        }
    }
}

// MARK: - Crop

struct CropView: View {
    let image: CGImage
    @Binding var rect: CGRect
    var aspect: CGFloat?
    @State private var dragStart: (CGPoint, CGRect, Int)?

    var body: some View {
        GeometryReader { geo in
            let fit = Fit(image: image.size, in: geo.size)
            let v = fit.view(rect)
            ZStack(alignment: .topLeading) {
                Image(decorative: image, scale: 1).resizable().frame(width: fit.size.width, height: fit.size.height).offset(x: fit.origin.x, y: fit.origin.y)
                Path { p in p.addRect(fit.frame); p.addRect(v) }.fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
                Rectangle().stroke(Color.white, lineWidth: 1.5).frame(width: v.width, height: v.height).offset(x: v.minX, y: v.minY)
                    .accessibilityLabel("Crop selection. Drag to reposition.")
                ForEach(0..<4, id: \.self) { i in
                    let c = CGPoint(x: i % 2 == 0 ? v.minX : v.maxX, y: i < 2 ? v.minY : v.maxY)
                    RoundedRectangle(cornerRadius: 2).fill(.white).frame(width: 12, height: 12).offset(x: c.x - 6, y: c.y - 6)
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 1).onChanged { g in
                let p = fit.image(g.location)
                if dragStart == nil {
                    let s = fit.image(g.startLocation)
                    let corners = [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY), CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY)]
                    let hit = corners.firstIndex { hypot($0.x - s.x, $0.y - s.y) * fit.scale < 14 }
                    dragStart = (s, rect, hit ?? (rect.contains(s) ? 4 : 5))
                }
                guard let (s, r0, mode) = dragStart else { return }
                let bounds = CGRect(origin: .zero, size: image.size)
                var r: CGRect
                switch mode {
                case 4: r = r0.offsetBy(dx: p.x - s.x, dy: p.y - s.y)
                    r.origin.x = min(max(0, r.minX), bounds.width - r.width); r.origin.y = min(max(0, r.minY), bounds.height - r.height)
                case 5: r = rectFrom(s, p)
                default:
                    let anchor = CGPoint(x: mode % 2 == 0 ? r0.maxX : r0.minX, y: mode < 2 ? r0.maxY : r0.minY)
                    r = rectFrom(anchor, p)
                }
                if let a = aspect, mode != 4, r.height > 0 { r.size.height = r.width / a }
                rect = r.intersection(bounds).integral
            }.onEnded { _ in dragStart = nil })
        }
    }
}

struct CropControls: View {
    let size: CGSize
    @Binding var rect: CGRect
    @Binding var aspect: CGFloat?
    var body: some View {
        Text("Aspect").font(.headline)
        Picker("", selection: $aspect) {
            Text("Free").tag(CGFloat?.none)
            Text("Original").tag(CGFloat?.some(size.width / size.height))
            Text("1:1").tag(CGFloat?.some(1)); Text("4:3").tag(CGFloat?.some(4.0 / 3)); Text("16:9").tag(CGFloat?.some(16.0 / 9)); Text("9:16").tag(CGFloat?.some(9.0 / 16))
        }.labelsHidden()
        .onChange(of: aspect) { _, a in if let a { rect.size.height = min(size.height - rect.minY, rect.width / a); rect.size.width = rect.height * a } }
        Text("Size").font(.headline)
        HStack {
            TextField("Width", value: Binding(get: { Int(rect.width) }, set: { rect.size.width = CGFloat(min(max(2, $0), Int(size.width - rect.minX))) }), format: .number)
                .accessibilityLabel("Crop width in pixels")
            Text("×")
            TextField("Height", value: Binding(get: { Int(rect.height) }, set: { rect.size.height = CGFloat(min(max(2, $0), Int(size.height - rect.minY))) }), format: .number)
                .accessibilityLabel("Crop height in pixels")
        }
        Text("Original \(Int(size.width)) × \(Int(size.height))").font(.caption).foregroundStyle(.secondary)
        Button("Reset") { rect = CGRect(origin: .zero, size: size); aspect = nil }
    }
}

struct ImageCropEditor: View {
    let url: URL
    let close: () -> Void
    var body: some View { Loaded(load: { try ImageOps.load(url) }) { CropBody(image: $0, url: url, close: close) } }

    struct CropBody: View {
        let image: CGImage, url: URL, close: () -> Void
        @State private var rect: CGRect
        @State private var aspect: CGFloat?
        init(image: CGImage, url: URL, close: @escaping () -> Void) {
            self.image = image; self.url = url; self.close = close
            _rect = State(initialValue: CGRect(origin: .zero, size: image.size).insetBy(dx: CGFloat(image.width) / 10, dy: CGFloat(image.height) / 10).integral)
        }
        var body: some View {
            EditorShell(primary: "Save Cropped Copy", enabled: rect.width >= 2 && rect.height >= 2, close: close, save: {
                let r = rect
                Editors.save("Cropping", [url], close: close) { _, _ in [try ImageOps.crop(url, rect: r)] }
            }) { CropView(image: image, rect: $rect, aspect: aspect) } side: { CropControls(size: image.size, rect: $rect, aspect: $aspect) }
        }
    }
}

// MARK: - Resize

struct ResizeEditor: View {
    let urls: [URL]
    let close: () -> Void
    @State private var size: CGSize?
    @State private var w = 0
    @State private var h = 0
    @State private var lock = true
    var body: some View {
        Form {
            if let size {
                Picker("Scale", selection: Binding(get: { 0 }, set: { (pct: Int) in if pct > 0 { w = Int(size.width) * pct / 100; h = Int(size.height) * pct / 100 } })) {
                    Text("Custom").tag(0); Text("25%").tag(25); Text("50%").tag(50); Text("75%").tag(75); Text("200%").tag(200)
                }
                TextField("Width", value: Binding(get: { w }, set: { w = $0; if lock { h = Int((Double($0) * size.height / size.width).rounded()) } }), format: .number)
                TextField("Height", value: Binding(get: { h }, set: { h = $0; if lock { w = Int((Double($0) * size.width / size.height).rounded()) } }), format: .number)
                Toggle("Keep proportions", isOn: $lock)
                if urls.count > 1 { Text("Each of the \(urls.count) images is scaled by the same factor.").font(.caption).foregroundStyle(.secondary) }
            } else { ProgressView() }
            HStack {
                Spacer()
                Button("Cancel", action: close)
                Button("Resize") {
                    guard let size else { return }
                    let fx = Double(w) / size.width, fy = Double(h) / size.height, urls = urls, single = urls.count == 1, w = w, h = h
                    Editors.save("Resizing", urls, close: close) { _, _ in
                        try urls.map { u in
                            if single { return try ImageOps.resize(u, width: w, height: h) }
                            let s = try ImageOps.load(u).size
                            return try ImageOps.resize(u, width: Int(s.width * fx), height: Int(s.height * fy))
                        }
                    }
                }.keyboardShortcut(.defaultAction).disabled(w < 1 || h < 1)
            }
        }
        .formStyle(.grouped).padding()
        .task {
            let u = urls[0]
            if let s = await Task.detached(operation: { try? ImageOps.load(u).size }).value { size = s; w = Int(s.width); h = Int(s.height) }
        }
    }
}

// MARK: - Redact

struct RectsCanvas: View {
    let image: CGImage
    @Binding var rects: [CGRect]
    @Binding var selected: Int?
    let style: RedactionStyle
    var visible: (Int) -> Bool = { _ in true }
    @State private var drag: (start: CGPoint, index: Int, original: CGRect?)?

    var body: some View {
        GeometryReader { geo in
            let fit = Fit(image: image.size, in: geo.size)
            ZStack(alignment: .topLeading) {
                Image(decorative: image, scale: 1).resizable().frame(width: fit.size.width, height: fit.size.height).offset(x: fit.origin.x, y: fit.origin.y)
                ForEach(rects.indices, id: \.self) { i in
                    let v = fit.view(rects[i])
                    Group {
                        if style == .solid { Rectangle().fill(.black) } else { Rectangle().fill(.ultraThinMaterial) }
                    }
                    .opacity(visible(i) ? 1 : 0.3)
                    .overlay(Rectangle().stroke(selected == i ? Color.accentColor : .white.opacity(0.6), lineWidth: selected == i ? 2 : 1))
                    .frame(width: v.width, height: v.height).offset(x: v.minX, y: v.minY)
                    .accessibilityLabel("Redaction rectangle \(i + 1)")
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                let p = fit.image(g.location), s = fit.image(g.startLocation)
                if drag == nil {
                    if let hit = rects.lastIndex(where: { $0.contains(s) }) { selected = hit; drag = (s, hit, rects[hit]) }
                    else { rects.append(CGRect(origin: s, size: .zero)); selected = rects.count - 1; drag = (s, rects.count - 1, nil) }
                }
                guard let d = drag, rects.indices.contains(d.index) else { return }
                let bounds = CGRect(origin: .zero, size: image.size)
                rects[d.index] = (d.original.map { $0.offsetBy(dx: p.x - s.x, dy: p.y - s.y) } ?? rectFrom(s, p)).intersection(bounds)
            }.onEnded { _ in
                if let d = drag, rects.indices.contains(d.index), rects[d.index].width < 4 || rects[d.index].height < 4, d.original == nil {
                    rects.remove(at: d.index); selected = nil
                }
                drag = nil
            })
        }
        .onDeleteCommand { if let s = selected, rects.indices.contains(s) { rects.remove(at: s); selected = nil } }
    }
}

struct ImageRedactEditor: View {
    let url: URL
    let close: () -> Void
    @State private var rects: [CGRect] = []
    @State private var selected: Int?
    @State private var style = RedactionStyle.blur
    var body: some View {
        Loaded(load: { try ImageOps.load(url) }) { image in
            EditorShell(primary: "Save Redacted Copy", enabled: !rects.isEmpty, close: close, save: {
                let r = rects, s = style
                Editors.save("Redacting", [url], close: close) { _, _ in [try ImageOps.redact(url, rects: r, style: s)] }
            }) {
                RectsCanvas(image: image, rects: $rects, selected: $selected, style: style)
            } side: {
                Text("Drag over the parts to hide.").foregroundStyle(.secondary)
                Picker("Style", selection: $style) { Text("Blur").tag(RedactionStyle.blur); Text("Solid").tag(RedactionStyle.solid) }.pickerStyle(.segmented)
                Text("\(rects.count) redaction\(rects.count == 1 ? "" : "s")")
                Button("Delete Redaction") { if let s = selected { rects.remove(at: s); selected = nil } }.disabled(selected == nil)
                Button("Remove All") { rects.removeAll(); selected = nil }.disabled(rects.isEmpty)
            }
        }
    }
}

// MARK: - Annotate

struct Mark: Identifiable {
    enum Kind: String, CaseIterable { case pen, highlighter, arrow, rectangle, ellipse, text, magnifier }
    let id = UUID()
    var kind: Kind
    var points: [CGPoint]
    var color: CGColor
    var width: CGFloat
    var text = ""
    var zoom: CGFloat = 2
}

/// Draws marks in image pixel space on a context whose origin is top-left.
func drawMarks(_ marks: [Mark], base: CGImage, in ctx: CGContext) {
    for m in marks {
        guard let a = m.points.first, let b = m.points.last else { continue }
        ctx.saveGState()
        ctx.setStrokeColor(m.color); ctx.setFillColor(m.color)
        ctx.setLineWidth(m.width); ctx.setLineCap(.round); ctx.setLineJoin(.round)
        switch m.kind {
        case .pen, .highlighter:
            if m.kind == .highlighter { ctx.setAlpha(0.4); ctx.setLineWidth(m.width * 4); ctx.setBlendMode(.multiply) }
            ctx.addLines(between: m.points); ctx.strokePath()
        case .rectangle: ctx.stroke(rectFrom(a, b))
        case .ellipse: ctx.strokeEllipse(in: rectFrom(a, b))
        case .arrow:
            ctx.move(to: a); ctx.addLine(to: b); ctx.strokePath()
            let ang = atan2(b.y - a.y, b.x - a.x), len = max(14, m.width * 4)
            ctx.move(to: b)
            ctx.addLine(to: CGPoint(x: b.x - len * cos(ang - .pi / 6), y: b.y - len * sin(ang - .pi / 6)))
            ctx.addLine(to: CGPoint(x: b.x - len * cos(ang + .pi / 6), y: b.y - len * sin(ang + .pi / 6)))
            ctx.closePath(); ctx.fillPath()
        case .text:
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
            (m.text as NSString).draw(at: a, withAttributes: [.font: NSFont.systemFont(ofSize: m.width * 6, weight: .semibold), .foregroundColor: NSColor(cgColor: m.color) ?? .red])
            NSGraphicsContext.restoreGraphicsState()
        case .magnifier:
            let r = max(20, hypot(b.x - a.x, b.y - a.y))
            let circle = CGRect(x: a.x - r, y: a.y - r, width: 2 * r, height: 2 * r)
            ctx.saveGState()
            ctx.addEllipse(in: circle); ctx.clip()
            // Draw the base scaled around the circle centre. The context is flipped, so flip the image back.
            ctx.translateBy(x: a.x, y: a.y); ctx.scaleBy(x: m.zoom, y: -m.zoom); ctx.translateBy(x: -a.x, y: -a.y)
            ctx.draw(base, in: CGRect(x: 0, y: 2 * a.y - CGFloat(base.height), width: CGFloat(base.width), height: CGFloat(base.height)))
            ctx.restoreGState()
            ctx.setLineWidth(m.width); ctx.strokeEllipse(in: circle)
        }
        ctx.restoreGState()
    }
}

func renderAnnotated(_ base: CGImage, _ marks: [Mark]) -> CGImage {
    let ctx = CGContext(data: nil, width: base.width, height: base.height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(base, in: CGRect(origin: .zero, size: base.size))
    ctx.translateBy(x: 0, y: CGFloat(base.height)); ctx.scaleBy(x: 1, y: -1)
    drawMarks(marks, base: base, in: ctx)
    return ctx.makeImage()!
}

struct AnnotateEditor: View {
    let url: URL
    let close: () -> Void
    @State private var marks: [Mark] = []
    @State private var tool = Mark.Kind.arrow
    @State private var color = Color.red
    @State private var width: CGFloat = 6
    @State private var zoom: CGFloat = 2
    @State private var text = "Text"
    @State private var current: Mark?

    var body: some View {
        Loaded(load: { try ImageOps.load(url) }) { image in
            EditorShell(primary: "Save Annotated Copy", enabled: !marks.isEmpty, close: close, save: {
                let m = marks
                Editors.save("Annotating photo", [url], close: close) { _, _ in [try ImageOps.save(renderAnnotated(try ImageOps.load(url), m), like: url, suffix: "annotated")] }
            }) {
                GeometryReader { geo in
                    let fit = Fit(image: image.size, in: geo.size)
                    Canvas { gc, _ in
                        gc.withCGContext { ctx in
                            ctx.translateBy(x: fit.origin.x, y: fit.origin.y); ctx.scaleBy(x: fit.scale, y: fit.scale)
                            ctx.saveGState(); ctx.translateBy(x: 0, y: CGFloat(image.height)); ctx.scaleBy(x: 1, y: -1)
                            ctx.draw(image, in: CGRect(origin: .zero, size: image.size)); ctx.restoreGState()
                            drawMarks(marks + (current.map { [$0] } ?? []), base: image, in: ctx)
                        }
                    }
                    .accessibilityLabel("Annotation preview")
                    .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                        let p = fit.image(g.location)
                        if current == nil {
                            current = Mark(kind: tool, points: [fit.image(g.startLocation)], color: NSColor(color).cgColor, width: width, text: text, zoom: zoom)
                        }
                        if tool == .pen || tool == .highlighter { current!.points.append(p) } else { current!.points = [current!.points[0], p] }
                    }.onEnded { _ in
                        if var c = current {
                            if c.kind == .magnifier, c.points.count < 2 { c.points.append(CGPoint(x: c.points[0].x + 120, y: c.points[0].y)) }
                            marks.append(c)
                        }
                        current = nil
                    })
                }
            } side: {
                Text("Tool").font(.headline)
                Picker("", selection: $tool) {
                    ForEach(Mark.Kind.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                }.labelsHidden().pickerStyle(.radioGroup)
                ColorPicker("Annotation color", selection: $color)
                Slider(value: $width, in: 2...30) { Text("Size") }
                Button("Make drawn annotations a little larger.") { width = min(30, width + 2) }.buttonStyle(.link).font(.caption)
                if tool == .text { TextField("Text", text: $text) }
                if tool == .magnifier { Slider(value: $zoom, in: 1.5...5) { Text("Zoom") }.accessibilityLabel("Magnifier zoom level") }
                Divider()
                Button("Undo last annotation") { _ = marks.popLast() }.keyboardShortcut("z").disabled(marks.isEmpty)
                Button("Remove all drawn strokes") { marks.removeAll() }.disabled(marks.isEmpty)
            }
        }
    }
}

// MARK: - Background

struct BackgroundEditor: View {
    let url: URL
    let close: () -> Void
    enum Mode: String, CaseIterable { case transparent = "Transparent", color = "Color", image = "Image" }
    @State private var mode = Mode.color
    @State private var color = Color.white
    @State private var bgImage: URL?
    @State private var preview: CGImage?
    @State private var error: String?
    @State private var busy = false

    var background: Background {
        switch mode {
        case .transparent: return .transparent
        case .color: return .color(NSColor(color).cgColor)
        case .image: return bgImage.map { .image($0) } ?? .transparent
        }
    }

    var body: some View {
        EditorShell(primary: "Save with Background", enabled: mode != .image || bgImage != nil, close: close, save: {
            let bg = background
            Editors.save("Adding background", [url], close: close) { _, _ in [try ImageOps.changeBackground(url, bg)] }
        }) {
            ZStack {
                Checkerboard()
                if let preview { Image(decorative: preview, scale: 1).resizable().scaledToFit().padding() }
                if busy { ProgressView() }
                if let error { Text(error).foregroundStyle(.white).padding() }
            }
        } side: {
            Picker("Background", selection: $mode) { ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented).labelsHidden()
            if mode == .color { ColorPicker("Choose a custom background color", selection: $color) }
            if mode == .image {
                Button(bgImage == nil ? "Choose an image background" : bgImage!.lastPathComponent) {
                    let p = NSOpenPanel(); p.allowedContentTypes = [.image]
                    if p.runModal() == .OK { bgImage = p.url }
                }
            }
            Text("Dropwheel lifts the subject with on-device Vision, then puts it on the new background.").font(.caption).foregroundStyle(.secondary)
        }
        .task(id: "\(mode)\(color)\(bgImage?.path ?? "")") { await render() }
    }

    func render() async {
        busy = true; defer { busy = false }
        let bg = background, url = url
        let r = await Task.detached { Result { try ImageOps.withBackground(ImageOps.scaled(try ImageOps.load(url), maxSide: 900), bg) } }.value
        switch r { case .success(let i): preview = i; error = nil; case .failure(let e): error = e.localizedDescription }
    }
}

struct Checkerboard: View {
    var body: some View {
        Canvas { gc, size in
            let s: CGFloat = 12
            for y in stride(from: 0, to: size.height, by: s) {
                for x in stride(from: 0, to: size.width, by: s) where (Int(x / s) + Int(y / s)) % 2 == 0 {
                    gc.fill(Path(CGRect(x: x, y: y, width: s, height: s)), with: .color(.gray.opacity(0.35)))
                }
            }
        }
    }
}

// MARK: - Adjust

struct AdjustEditor: View {
    let url: URL
    let close: () -> Void
    @State private var a = Adjustments()
    @State private var base: CGImage?
    @State private var preview: CGImage?

    var body: some View {
        EditorShell(primary: "Save Edited Copy", enabled: a != Adjustments(), close: close, save: {
            let a = a
            Editors.save("Adjusting photo", [url], close: close) { _, _ in [try ImageOps.adjust(url, a)] }
        }) {
            if let preview { Image(decorative: preview, scale: 1).resizable().scaledToFit().padding() } else { ProgressView() }
        } side: {
            slider("Exposure", $a.exposure, -2...2)
            slider("Contrast", $a.contrast, 0.5...1.5)
            slider("Saturation", $a.saturation, 0...2)
            slider("Warmth", $a.warmth, -1...1)
            slider("Sharpness", $a.sharpness, 0...1)
            slider("Vignette", $a.vignette, 0...1)
            Button("Restore Defaults") { a = Adjustments() }
        }
        .task {
            let u = url
            base = await Task.detached { try? ImageOps.scaled(try ImageOps.load(u), maxSide: 1200) }.value
            preview = base
        }
        .onChange(of: a) { _, new in if let base { preview = ImageOps.adjusted(base, new) } }
    }

    func slider(_ name: String, _ v: Binding<Double>, _ r: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack { Text(name); Spacer(); Text(String(format: "%.2f", v.wrappedValue)).foregroundStyle(.secondary).monospacedDigit() }
            Slider(value: v, in: r)
        }
    }
}

// MARK: - Metadata

struct MetadataEditor: View {
    let url: URL
    let close: () -> Void
    @State private var fields: [MetadataField] = []
    @State private var original: [String: String] = [:]
    @State private var all: [(String, String)] = []

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Editable") {
                    ForEach($fields) { $f in TextField(f.label, text: $f.value) }
                }
                Section("All metadata (\(all.count) fields)") {
                    ForEach(all.indices, id: \.self) { i in LabeledContent(all[i].0) { Text(all[i].1).lineLimit(2).textSelection(.enabled) } }
                }
            }.formStyle(.grouped)
            Divider()
            HStack {
                Button("Remove All Metadata") {
                    Editors.save("Removing metadata", [url], close: close) { _, _ in [try MetadataOps.removeAll(url)] }
                }
                Spacer()
                Button("Cancel", action: close)
                Button("Save Edited Copy") {
                    let changed = Dictionary(uniqueKeysWithValues: fields.filter { original[$0.id] != $0.value }.map { ($0.id, $0.value) })
                    Editors.save("Editing metadata", [url], close: close) { _, _ in [try MetadataOps.edit(url, values: changed)] }
                }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                    .disabled(fields.allSatisfy { original[$0.id] == $0.value })
            }.padding(12)
        }
        .onAppear {
            let r = MetadataOps.read(url)
            fields = r.fields; all = r.all
            original = Dictionary(uniqueKeysWithValues: r.fields.map { ($0.id, $0.value) })
        }
    }
}

// MARK: - Collage

struct CollageEditor: View {
    @State var urls: [URL]
    let close: () -> Void
    @State private var o = CollageOptions()
    @State private var color = Color.white
    @State private var thumbs: [CGImage] = []
    @State private var preview: CGImage?

    var body: some View {
        EditorShell(primary: "Save Collage", enabled: urls.count >= 2, close: close, save: {
            var o = o; o.background = NSColor(color).cgColor
            let urls = urls, opts = o
            Editors.save("Creating collage", urls, close: close) { _, _ in [try ImageOps.collage(urls, opts)] }
        }) {
            if let preview { Image(decorative: preview, scale: 1).resizable().scaledToFit().padding() } else { ProgressView() }
        } side: {
            Picker("Style", selection: $o.style) { Text("Grid").tag(CollageOptions.Style.grid); Text("Row").tag(CollageOptions.Style.row); Text("Column").tag(CollageOptions.Style.column) }
            if o.style == .grid { Stepper("Columns: \(o.columns == 0 ? "Auto" : "\(o.columns)")", value: $o.columns, in: 0...8) }
            VStack(alignment: .leading) { Text("Spacing"); Slider(value: $o.spacing, in: 0...120) }
            VStack(alignment: .leading) { Text("Corner radius"); Slider(value: $o.cornerRadius, in: 0...200) }
            Toggle("Fit whole images", isOn: $o.fitWholeImages)
            ColorPicker("Background", selection: $color)
            Text("Order").font(.headline)
            ForEach(urls.indices, id: \.self) { i in
                HStack {
                    Text(urls[i].lastPathComponent).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button { urls.swapAt(i, i - 1); thumbs.swapAt(i, i - 1) } label: { Image(systemName: "chevron.up") }.disabled(i == 0).buttonStyle(.plain)
                }
            }
        }
        .task {
            let u = urls
            thumbs = await Task.detached { u.compactMap { try? ImageOps.scaled(try ImageOps.load($0), maxSide: 300) } }.value
            redraw()
        }
        .onChange(of: "\(o.style)\(o.columns)\(o.spacing)\(o.cornerRadius)\(o.fitWholeImages)\(color)\(urls)") { redraw() }
    }

    func redraw() {
        guard thumbs.count >= 2 else { return }
        var p = o; p.cellSize = 200; p.spacing = o.spacing / 5; p.cornerRadius = o.cornerRadius / 5; p.background = NSColor(color).cgColor
        preview = ImageOps.collageImage(thumbs, p)
    }
}
