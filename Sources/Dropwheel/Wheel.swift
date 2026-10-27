import AppKit
import DropwheelCore
import SwiftUI

// MARK: - Drag gesture monitor

/// Watches for a file drag in any app and fires when the user taps a wheel key.
/// It polls the drag pasteboard and modifier state, so it needs no Accessibility permission.
@MainActor
final class DragMonitor {
    static let keyHelp = "⇧ Shift: convert   ⌘ Command: tools   ⌃ Control: actions"
    var onTrigger: (CGPoint, [URL], Action.Group) -> Void = { _, _, _ in }
    var onDragEnd: () -> Void = {}
    private var timer: Timer?
    private var wasDown = false, dragging = false
    private var lastGroup: Action.Group?
    private var startCount = 0
    private var urls: [URL] = []

    func start() {
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick() {
        let down = NSEvent.pressedMouseButtons & 1 != 0
        let pb = NSPasteboard(name: .drag)
        defer { wasDown = down }
        if down, !wasDown { startCount = pb.changeCount; dragging = false }
        if !down {
            if wasDown, dragging { onDragEnd() }
            dragging = false; lastGroup = nil
            return
        }
        // A new drag writes to the drag pasteboard after the mouse goes down.
        if !dragging, pb.changeCount != startCount,
           let found = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !found.isEmpty {
            dragging = true
            urls = found
        }
        let flags = NSEvent.modifierFlags.intersection([.command, .option, .control, .shift])
        let group: Action.Group? = flags == .shift ? .format : flags == .command ? .tool : flags == .control ? .file : nil
        if dragging, let group, group != lastGroup { onTrigger(NSEvent.mouseLocation, urls, group) }
        lastGroup = group
    }
}

// MARK: - Wheel window

@MainActor
final class WheelController {
    private var panel: NSPanel?
    private var hideWork: DispatchWorkItem?
    let runner = ActionRunner()

    /// `group` limits the wheel to one ring; nil shows all. `sticky` keeps it open until a click, for files chosen without a drag.
    func show(at point: CGPoint, urls: [URL], group: Action.Group? = nil, sticky: Bool = false) {
        hideWork?.cancel()
        panel?.orderOut(nil)
        let hidden = AppSettings.shared.hiddenActions
        let actions = Catalog.actions(for: urls).filter { !hidden.contains($0.id) && (group == nil || $0.group == group) }
        let view = WheelView(urls: urls, actions: actions, group: group, sticky: sticky) { [weak self] action, dropped in
            self?.hide(after: 0)
            self?.runner.perform(action, dropped.isEmpty ? urls : dropped)
        } dismiss: { [weak self] in self?.hide(after: 0) }
        let size = view.frame.size
        let p = WheelPanel(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = .popUpMenu
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        p.contentView = view
        var origin = CGPoint(x: point.x - size.width / 2, y: point.y - size.height / 2)
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(point) })?.visibleFrame {
            origin.x = min(max(origin.x, screen.minX), screen.maxX - size.width)
            origin.y = min(max(origin.y, screen.minY), screen.maxY - size.height)
        }
        p.setFrameOrigin(origin)
        p.alphaValue = 0
        p.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.12; p.animator().alphaValue = 1 }
        if sticky { NSApp.activate(ignoringOtherApps: true); p.makeKey() }
        panel = p
    }

    func hide(after delay: Double) {
        hideWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let p = self?.panel, !(p.contentView as? WheelView)!.sticky || delay == 0 else { return }
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.1; p.animator().alphaValue = 0 }) { p.orderOut(nil) }
            self?.panel = nil
        }
        hideWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: w)
    }
}

final class WheelPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { (contentView as? WheelView)?.dismiss() }
}

/// The wheel: rings of glass petals around the cursor, formats inside, tools in the middle, file actions outside.
/// The view is the only drop target. It finds the petal under the cursor from the angle and the distance to the center.
final class WheelView: NSView {
    let urls: [URL]
    let sticky: Bool
    let onDrop: (Action, [URL]) -> Void
    let dismiss: () -> Void
    /// Layout is in points at full size; the view draws it at this scale.
    static let scale: CGFloat = 0.75
    private struct Ring { let items: [Action]; let inner: CGFloat; let outer: CGFloat }
    private struct Hot: Equatable { let ring: Int, item: Int }
    private let rings: [Ring]
    private let group: Action.Group?
    private let glass = NSVisualEffectView()
    private let canvas = WheelCanvas()
    private let center: CGPoint
    private let hub: CGFloat
    private let chipsHeight: CGFloat
    private let icons: [NSImage]
    private let defaultLabel: (String, String)
    private var hot: Hot? {
        didSet {
            guard hot != oldValue else { return }
            canvas.needsDisplay = true
            updateMask()
            if hot != nil { MainActor.assumeIsolated { Feedback.highlight() } }
        }
    }

    init(urls: [URL], actions: [Action], group: Action.Group?, sticky: Bool, onDrop: @escaping (Action, [URL]) -> Void, dismiss: @escaping () -> Void) {
        self.urls = urls; self.group = group; self.sticky = sticky; self.onDrop = onDrop; self.dismiss = dismiss
        let groups = [Action.Group.format, .tool, .file].map { g in actions.filter { $0.group == g } }.filter { !$0.isEmpty }
        if groups.count == 1 {
            // A single ring grows so that each petal keeps about 62 pt of arc at its middle.
            let mid = max(160, CGFloat(groups[0].count) * 62 / (2 * .pi))
            rings = [Ring(items: groups[0], inner: mid - 62, outer: mid + 62)]
        } else {
            rings = groups.enumerated().map { k, items in Ring(items: items, inner: 92 + CGFloat(k) * 90, outer: 178 + CGFloat(k) * 90) }
        }
        hub = (rings.first?.inner ?? 98) - 12
        chipsHeight = group == nil ? 0 : 52
        let side = ((rings.last?.outer ?? 160) + 18) * 2
        center = CGPoint(x: side / 2, y: chipsHeight + side / 2)
        icons = urls.prefix(3).map { NSWorkspace.shared.icon(forFile: $0.path) }
        defaultLabel = WheelView.summary(urls)
        super.init(frame: CGRect(x: 0, y: 0, width: side * WheelView.scale, height: (side + chipsHeight) * WheelView.scale))
        setBoundsSize(CGSize(width: side, height: side + chipsHeight))
        appearance = NSAppearance(named: .vibrantDark)
        registerForDraggedTypes([.fileURL])

        glass.frame = bounds
        glass.material = .hudWindow
        glass.blendingMode = .behindWindow
        glass.state = .active
        addSubview(glass)
        canvas.frame = bounds
        canvas.drawer = { [weak self] in self?.drawContents() }
        addSubview(canvas)
        updateMask()
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        setAccessibilityRole(.group)
        setAccessibilityLabel("Dropwheel")
        let petals: [PetalElement] = rings.enumerated().flatMap { r, ring in
            ring.items.enumerated().map { i, a in
                PetalElement(label: a.title, frame: petal(r, i).bounds, parent: self) { [weak self] in self?.onDrop(a, []) }
            }
        }
        setAccessibilityChildren(petals)
    }

    required init?(coder: NSCoder) { fatalError() }

    static func summary(_ urls: [URL]) -> (String, String) {
        let exts = Set(urls.map { $0.pathExtension.uppercased() }).filter { !$0.isEmpty }
        let what = exts.count == 1 ? exts.first! : urls.count == 1 ? "Folder" : "Mixed"
        return (urls.count == 1 ? what : "\(urls.count) files", urls.count == 1 ? urls[0].lastPathComponent : what)
    }

    // MARK: Geometry

    /// Compass angle (clockwise from the top, radians) of petal `i` in ring `r`, and the push for a hot petal.
    private func origin(_ r: Int, _ i: Int) -> (mid: CGFloat, step: CGFloat, c: CGPoint, hot: Bool) {
        let step = 2 * .pi / CGFloat(rings[r].items.count), mid = CGFloat(i) * step
        let isHot = hot == Hot(ring: r, item: i), push: CGFloat = isHot ? 10 : 0
        return (mid, step, CGPoint(x: center.x + push * sin(mid), y: center.y + push * cos(mid)), isHot)
    }

    private func petal(_ r: Int, _ i: Int) -> NSBezierPath {
        let o = origin(r, i), ring = rings[r], gap: CGFloat = 3.5
        let ro = ring.outer + (o.hot ? 6 : 0), ri = ring.inner
        let deg = { (a: CGFloat) in 90 - a * 180 / .pi }  // compass angle to AppKit degrees
        let a0 = o.mid - o.step / 2, a1 = o.mid + o.step / 2
        let p = NSBezierPath()
        p.appendArc(withCenter: o.c, radius: ro, startAngle: deg(a0 + gap / ro), endAngle: deg(a1 - gap / ro), clockwise: true)
        p.appendArc(withCenter: o.c, radius: ri, startAngle: deg(a1 - gap / ri), endAngle: deg(a0 + gap / ri), clockwise: false)
        p.close()
        return p
    }

    private func hit(_ p: CGPoint) -> Hot? {
        let dx = p.x - center.x, dy = p.y - center.y, d = hypot(dx, dy)
        var a = atan2(dx, dy)
        if a < 0 { a += 2 * .pi }
        for (r, ring) in rings.enumerated() where d >= ring.inner && d <= ring.outer + (r == rings.count - 1 ? 16 : 2) {
            let step = 2 * .pi / CGFloat(ring.items.count)
            return Hot(ring: r, item: Int((a + step / 2).truncatingRemainder(dividingBy: 2 * .pi) / step) % ring.items.count)
        }
        return nil
    }

    private var hubPath: NSBezierPath { NSBezierPath(ovalIn: CGRect(x: center.x - hub, y: center.y - hub, width: hub * 2, height: hub * 2)) }

    private var chips: [(CGRect, String, Bool)] {
        guard let group else { return [] }
        let items: [(String, Action.Group)] = [("⇧  Convert", .format), ("⌘  Tools", .tool), ("⌃  Actions", .file)]
        let w: CGFloat = 104, gap: CGFloat = 8, x0 = bounds.midX - (w * 3 + gap * 2) / 2
        return items.enumerated().map { k, it in (CGRect(x: x0 + CGFloat(k) * (w + gap), y: 10, width: w, height: 32), it.0, it.1 == group) }
    }

    /// The blur shows only through the petals, the hub and the key chips.
    private func updateMask() {
        let shape = NSBezierPath()
        for (r, ring) in rings.enumerated() { for i in ring.items.indices { shape.append(petal(r, i)) } }
        shape.append(hubPath)
        for c in chips { shape.append(NSBezierPath(roundedRect: c.0, xRadius: 16, yRadius: 16)) }
        glass.maskImage = NSImage(size: bounds.size, flipped: false) { _ in NSColor.black.setFill(); shape.fill(); return true }
    }

    // MARK: Drawing

    private func drawContents() {
        let accent = NSColor.systemOrange
        for (r, ring) in rings.enumerated() {
            for (i, a) in ring.items.enumerated() {
                let o = origin(r, i), path = petal(r, i)
                (o.hot ? accent.withAlphaComponent(0.85) : NSColor.black.withAlphaComponent(0.2)).setFill()
                path.fill()
                NSColor.white.withAlphaComponent(o.hot ? 0.75 : 0.28).setStroke()
                path.lineWidth = o.hot ? 1.5 : 1
                path.stroke()
                let rm = (ring.inner + ring.outer + (o.hot ? 6 : 0)) / 2
                drawMark(a, at: CGPoint(x: o.c.x + rm * sin(o.mid), y: o.c.y + rm * cos(o.mid)), hot: o.hot)
            }
        }
        NSColor.black.withAlphaComponent(0.3).setFill()
        hubPath.fill()
        NSColor.white.withAlphaComponent(0.25).setStroke()
        hubPath.stroke()

        // Up to three file icons, fanned like a stack.
        let size: CGFloat = 44, top = center.y + 10
        for (k, icon) in icons.enumerated().reversed() {
            let off = CGFloat(k) - CGFloat(icons.count - 1) / 2
            icon.draw(in: CGRect(x: center.x - size / 2 + off * 12, y: top - CGFloat(abs(off)) * 3, width: size, height: size))
        }
        let label = hot.map { h -> (String, String) in
            let a = rings[h.ring].items[h.item]
            return (a.title, a.editor ? "Drop to open the editor" : a.group == .format ? "Drop to convert" : "Drop to run")
        } ?? defaultLabel
        drawText(label.0, at: CGPoint(x: center.x, y: center.y - 12), font: .systemFont(ofSize: 17, weight: .bold), width: hub * 1.7)
        drawText(label.1, at: CGPoint(x: center.x, y: center.y - 32), font: .systemFont(ofSize: 11), color: .white.withAlphaComponent(0.78), width: hub * 1.6)

        for (rect, title, active) in chips {
            let p = NSBezierPath(roundedRect: rect, xRadius: 16, yRadius: 16)
            (active ? accent.withAlphaComponent(0.85) : NSColor.black.withAlphaComponent(0.25)).setFill()
            p.fill()
            NSColor.white.withAlphaComponent(0.3).setStroke()
            p.stroke()
            drawText(title, at: CGPoint(x: rect.midX, y: rect.midY), font: .systemFont(ofSize: 12.5, weight: .semibold), color: .white.withAlphaComponent(active ? 1 : 0.8), width: rect.width - 8)
        }
    }

    private func drawMark(_ a: Action, at p: CGPoint, hot: Bool) {
        if a.symbol.isEmpty {
            drawText(a.title, at: p, font: .systemFont(ofSize: hot ? 15 : 13, weight: .bold), width: 64)
            return
        }
        let config = NSImage.SymbolConfiguration(pointSize: hot ? 20 : 16, weight: .medium).applying(.init(paletteColors: [.white]))
        if let img = NSImage(systemSymbolName: a.symbol, accessibilityDescription: nil)?.withSymbolConfiguration(config) {
            img.draw(in: CGRect(x: p.x - img.size.width / 2, y: p.y + 2, width: img.size.width, height: img.size.height))
        }
        drawText(a.title, at: CGPoint(x: p.x, y: p.y - 9), font: .systemFont(ofSize: 10, weight: .semibold), width: 70)
    }

    /// Draws one line centered on `p`, truncated to `width`.
    private func drawText(_ s: String, at p: CGPoint, font: NSFont, color: NSColor = .white, width: CGFloat) {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.lineBreakMode = .byTruncatingMiddle
        let shadow = NSShadow()
        shadow.shadowColor = .black.withAlphaComponent(0.45)
        shadow.shadowOffset = CGSize(width: 0, height: -1)
        shadow.shadowBlurRadius = 2
        let str = NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: style, .shadow: shadow])
        let h = ceil(font.ascender - font.descender)
        str.draw(with: CGRect(x: p.x - width / 2, y: p.y - h / 2 - font.descender, width: width, height: h), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    // MARK: Drag and click

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        hot = hit(convert(sender.draggingLocation, from: nil))
        guard hot != nil else { return [] }
        // A held ⌘ or ⌃ narrows the source mask to generic or link, so accept those too. Never accept a move.
        return [.copy, .generic, .link].first { sender.draggingSourceOperationMask.contains($0) } ?? []
    }
    override func draggingExited(_ sender: NSDraggingInfo?) { hot = nil }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let h = hit(convert(sender.draggingLocation, from: nil)) else { return false }
        let dropped = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        hot = nil
        onDrop(rings[h.ring].items[h.item], dropped)
        return true
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseMoved(with event: NSEvent) { hot = hit(convert(event.locationInWindow, from: nil)) }
    override func mouseExited(with event: NSEvent) { hot = nil }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        // In sticky mode a click on a petal runs it, and a click anywhere else closes the wheel.
        if let h = hit(convert(event.locationInWindow, from: nil)) { onDrop(rings[h.ring].items[h.item], []) } else { dismiss() }
    }
}

/// Draws for WheelView above the blur. It lets every mouse and drag event fall through to the wheel.
final class WheelCanvas: NSView {
    var drawer: () -> Void = {}
    override func draw(_ dirty: NSRect) { drawer() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// One petal for VoiceOver, which presses it like a button.
final class PetalElement: NSAccessibilityElement {
    let press: () -> Void
    init(label: String, frame: CGRect, parent: NSView, press: @escaping () -> Void) {
        self.press = press
        super.init()
        setAccessibilityRole(.button)
        setAccessibilityLabel(label)
        setAccessibilityFrameInParentSpace(frame)
        setAccessibilityParent(parent)
    }
    override func accessibilityPerformPress() -> Bool { press(); return true }
}

// MARK: - Running an action

@MainActor
final class ActionRunner {
    func perform(_ action: Action, _ urls: [URL]) {
        let settings = AppSettings.shared
        switch action.id {
        case "float": FloatManager.shared.create(with: urls)
        case "copyFiles":
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects(urls as [NSURL])
            Feedback.success()
        case "copyPaths":
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(urls.map(\.path).joined(separator: "\n"), forType: .string)
            Feedback.success()
        case "terminal":
            let folders = Set(urls.map { kind(of: $0) == .folder ? $0 : $0.deletingLastPathComponent() })
            NSWorkspace.shared.open(Array(folders), withApplicationAt: URL(fileURLWithPath: settings.terminalApp), configuration: .init()) { _, e in
                if let e { Task { @MainActor in Alerts.show("The terminal app could not open the folder", e.localizedDescription) } }
            }
        case "airdrop":
            guard let s = NSSharingService(named: .sendViaAirDrop), s.canPerform(withItems: urls) else {
                Alerts.show("AirDrop isn’t available", "Turn on Wi-Fi and Bluetooth, then try again."); return
            }
            NSApp.activate(ignoringOtherApps: true)
            s.perform(withItems: urls)
        case "move":
            NSApp.activate(ignoringOtherApps: true)
            let p = NSOpenPanel()
            p.canChooseFiles = false; p.canChooseDirectories = true; p.canCreateDirectories = true
            p.prompt = "Move Here"
            p.message = "Move files and folders to a chosen folder"
            guard p.runModal() == .OK, let dest = p.url else { return }
            var moved: [URL] = [], errors: [String] = []
            for u in urls {
                let target = uniqueURL(dest.appendingPathComponent(u.deletingPathExtension().lastPathComponent), ext: u.pathExtension)
                do { try FileManager.default.moveItem(at: u, to: target); moved.append(target) } catch { errors.append("\(u.lastPathComponent): \(error.localizedDescription)") }
            }
            if !errors.isEmpty { Alerts.show("Some files could not be moved", errors.joined(separator: "\n")) }
            if !moved.isEmpty { Feedback.success(); NSWorkspace.shared.activateFileViewerSelecting(moved) }
        case "readQR":
            Task.detached {
                let results = urls.map { ($0.lastPathComponent, (try? ImageOps.readQRCodes($0)) ?? []) }
                await MainActor.run {
                    _ = Windows.show("qr", title: "QR Codes", size: CGSize(width: 460, height: 320)) { QRResultsView(results: results) }
                }
            }
        default:
            if action.editor {
                Editors.open(action, urls)
                return
            }
            let compression = settings.compression, keepMeta = settings.preserveMetadata
            TaskStore.shared.run(action.group == .format ? "Converting to \(action.title)" : action.title, urls) { progress, cancel in
                try Catalog.run(action.id, urls, settings: compression, preserveMetadata: keepMeta, progress: progress, cancel: cancel)
            }
        }
    }
}
