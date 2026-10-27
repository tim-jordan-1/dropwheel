import AppKit
import QuickLookThumbnailing
import Quartz
import SwiftUI
import UniformTypeIdentifiers

/// A Float is a small always-on-top shelf that holds files. Files stay where they are on disk.
@MainActor
final class FloatManager {
    static let shared = FloatManager()
    private var panels: [FloatPanel] = []

    func create(with urls: [URL]) {
        let model = FloatModel(urls: urls)
        let p = FloatPanel(model: model)
        let n = CGFloat(panels.count)
        if let s = NSScreen.main?.visibleFrame { p.setFrameOrigin(CGPoint(x: s.maxX - 260 - n * 24, y: s.maxY - 360 - n * 24)) }
        p.orderFrontRegardless()
        panels.append(p)
        model.onClose = { [weak self, weak p] in
            p?.orderOut(nil)
            self?.panels.removeAll { $0 === p }
        }
    }
}

@MainActor
final class FloatModel: ObservableObject {
    @Published var urls: [URL]
    @Published var selection: Set<URL> = []
    var onClose: () -> Void = {}
    init(urls: [URL]) { self.urls = urls }

    func add(_ new: [URL]) { urls += new.filter { !urls.contains($0) } }
    func remove(_ u: Set<URL>) { urls.removeAll { u.contains($0) }; selection.subtract(u) }
    var selected: [URL] { selection.isEmpty ? urls : urls.filter { selection.contains($0) } }
}

final class FloatPanel: NSPanel, QLPreviewPanelDataSource {
    let model: FloatModel

    @MainActor init(model: FloatModel) {
        self.model = model
        super.init(contentRect: CGRect(x: 0, y: 0, width: 240, height: 320), styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel, .fullSizeContentView], backing: .buffered, defer: false)
        title = "Float"
        titlebarAppearsTransparent = true
        isFloatingPanel = true
        level = .floating
        hidesOnDeactivate = false
        isMovableByWindowBackground = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isReleasedWhenClosed = false
        contentView = NSHostingView(rootView: FloatView(model: model, quickLook: { [weak self] in self?.toggleQuickLook() }))
    }

    override var canBecomeKey: Bool { true }
    override func close() { MainActor.assumeIsolated { model.onClose() } }

    @MainActor func toggleQuickLook() {
        guard let ql = QLPreviewPanel.shared() else { return }
        if QLPreviewPanel.sharedPreviewPanelExists() && ql.isVisible { ql.orderOut(nil); return }
        makeKey()
        ql.makeKeyAndOrderFront(nil)
    }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) { panel.dataSource = self; panel.reloadData() }
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) { panel.dataSource = nil }
    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { MainActor.assumeIsolated { model.selected.count } }
    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        MainActor.assumeIsolated { model.selected[index] as NSURL }
    }
}

struct FloatView: View {
    @ObservedObject var model: FloatModel
    let quickLook: () -> Void
    @State private var targeted = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                // Dragging the stack icon drags every file in the Float.
                Image(systemName: "square.stack.3d.up.fill").font(.title3)
                    .onDrag { provider(for: model.urls) }
                    .help("Drag all files")
                Text(model.urls.isEmpty ? "Drop to add" : "\(model.urls.count) item\(model.urls.count == 1 ? "" : "s")").font(.headline)
                Spacer()
                Button { model.onClose() } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).help("Close Float without deleting files")
            }
            .padding(.horizontal, 12).padding(.top, 28).padding(.bottom, 6)
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 92))], spacing: 10) {
                    ForEach(model.urls, id: \.self) { u in
                        FloatItem(url: u, selected: model.selection.contains(u))
                            .onTapGesture {
                                if NSEvent.modifierFlags.contains(.command) { model.selection.formSymmetricDifference([u]) } else { model.selection = [u] }
                            }
                            .onTapGesture(count: 2) { NSWorkspace.shared.open(u) }
                            .onDrag { provider(for: model.selection.contains(u) ? model.selected : [u]) }
                            .contextMenu {
                                Button("Open") { NSWorkspace.shared.open(u) }
                                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([u]) }
                                Button("Quick Look") { model.selection = [u]; quickLook() }
                                Divider()
                                Button("Remove from Float") { model.remove([u]) }
                            }
                    }
                }.padding(10)
            }
            .overlay {
                if model.urls.isEmpty {
                    VStack(spacing: 6) {
                        Image(systemName: "tray.and.arrow.down").font(.largeTitle)
                        Text("Drop files here to hold them.").font(.caption)
                    }.foregroundStyle(.secondary)
                }
            }
        }
        .background(VisualEffect().ignoresSafeArea())
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.accentColor, lineWidth: targeted ? 3 : 0))
        .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
            for p in providers {
                _ = p.loadObject(ofClass: URL.self) { u, _ in if let u { Task { @MainActor in model.add([u]) } } }
            }
            return true
        }
        .onKeyPress(.space) { quickLook(); return .handled }
        .onKeyPress(.delete) { model.remove(model.selection); return .handled }
    }

    func provider(for urls: [URL]) -> NSItemProvider {
        // A single provider can only carry one file URL, so extra files ride along as more registrations.
        let p = NSItemProvider(contentsOf: urls.first) ?? NSItemProvider()
        for u in urls.dropFirst() { p.registerObject(u as NSURL, visibility: .all) }
        return p
    }
}

struct FloatItem: View {
    let url: URL
    let selected: Bool
    @State private var thumb: NSImage?
    var body: some View {
        VStack(spacing: 4) {
            Group {
                if let thumb { Image(nsImage: thumb).resizable().scaledToFit() }
                else { Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().scaledToFit() }
            }
            .frame(width: 64, height: 64)
            Text(url.lastPathComponent).font(.caption2).lineLimit(2).multilineTextAlignment(.center).truncationMode(.middle)
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Color.accentColor.opacity(0.3) : .clear))
        .accessibilityLabel("Float file or folder thumbnail \(url.lastPathComponent)")
        .task {
            let req = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 128, height: 128), scale: 2, representationTypes: .thumbnail)
            if let r = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: req) { thumb = r.nsImage }
        }
    }
}

struct VisualEffect: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView(); v.material = .hudWindow; v.blendingMode = .behindWindow; v.state = .active; return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {}
}
