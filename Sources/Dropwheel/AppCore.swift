import AppKit
import DropwheelCore
import os
import ServiceManagement
import SwiftUI

let log = Logger(subsystem: "com.timjordan.Dropwheel", category: "app")

// MARK: - Settings

@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    private let d = UserDefaults.standard

    @Published var hiddenActions: Set<String> { didSet { d.set(Array(hiddenActions), forKey: "hiddenActions") } }
    @Published var compression: CompressionSettings { didSet { d.set(try? JSONEncoder().encode(compression), forKey: "compression") } }
    @Published var soundAndHaptics: Bool { didSet { d.set(soundAndHaptics, forKey: "soundAndHaptics") } }
    @Published var revealOutputs: Bool { didSet { d.set(revealOutputs, forKey: "revealOutputs") } }
    @Published var preserveMetadata: Bool { didSet { d.set(preserveMetadata, forKey: "preserveMetadata") } }
    @Published var terminalApp: String { didSet { d.set(terminalApp, forKey: "terminalApp") } }
    @Published var debugLogging: Bool { didSet { d.set(debugLogging, forKey: "debugLogging") } }
    @Published var completedWelcome: Bool { didSet { d.set(completedWelcome, forKey: "completedWelcome") } }

    private init() {
        d.register(defaults: ["soundAndHaptics": true, "revealOutputs": false,
                              "preserveMetadata": true, "terminalApp": "/System/Applications/Utilities/Terminal.app"])
        hiddenActions = Set(d.stringArray(forKey: "hiddenActions") ?? [])
        compression = d.data(forKey: "compression").flatMap { try? JSONDecoder().decode(CompressionSettings.self, from: $0) } ?? .init()
        soundAndHaptics = d.bool(forKey: "soundAndHaptics")
        revealOutputs = d.bool(forKey: "revealOutputs")
        preserveMetadata = d.bool(forKey: "preserveMetadata")
        terminalApp = d.string(forKey: "terminalApp")!
        debugLogging = d.bool(forKey: "debugLogging")
        completedWelcome = d.bool(forKey: "completedWelcome")
    }

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do { try newValue ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister() }
            catch { Alerts.show("Could not change the login item", error.localizedDescription) }
            objectWillChange.send()
        }
    }
}

// MARK: - Tasks

@MainActor
final class TaskStore: ObservableObject {
    static let shared = TaskStore()

    final class Item: ObservableObject, Identifiable {
        enum State { case running, done([URL]), failed(String) }
        let id = UUID()
        let title: String
        let detail: String
        let cancel = Cancellation()
        @Published var progress = 0.0
        @Published var state = State.running
        init(title: String, detail: String) { self.title = title; self.detail = detail }
        var isRunning: Bool { if case .running = state { return true }; return false }
    }

    @Published var items: [Item] = []
    private var hideWork: DispatchWorkItem?

    var running: Bool { items.contains { $0.isRunning } }

    /// Runs `work` off the main thread and shows it in the progress panel.
    func run(_ title: String, _ urls: [URL], work: @escaping @Sendable (_ progress: @escaping DropwheelCore.Progress, _ cancel: Cancellation) throws -> [URL]) {
        let detail = urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) files"
        let item = Item(title: title, detail: detail)
        items.append(item)
        Windows.showProgress()
        hideWork?.cancel()
        let cancel = item.cancel
        Task.detached(priority: .userInitiated) {
            let result: Result<[URL], Error>
            do {
                result = .success(try work({ p in Task { @MainActor in item.progress = p } }, cancel))
            } catch let partial as PartialFailure {
                result = partial.outputs.isEmpty ? .failure(partial) : .success(partial.outputs)
                await MainActor.run { Alerts.show("Finished with errors", partial.errors.joined(separator: "\n")) }
            } catch {
                result = .failure(error)
            }
            await MainActor.run { self.finish(item, result) }
        }
    }

    private func finish(_ item: Item, _ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            item.progress = 1
            item.state = .done(urls)
            Feedback.success()
            if AppSettings.shared.revealOutputs, !urls.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(urls) }
        case .failure(let e):
            item.state = .failed(e.localizedDescription)
            log.error("\(item.title, privacy: .public) failed: \(e.localizedDescription, privacy: .public)")
            Feedback.failure()
        }
        scheduleHide()
    }

    func scheduleHide() {
        hideWork?.cancel()
        guard !running, !items.contains(where: { if case .failed = $0.state { return true }; return false }) else { return }
        let w = DispatchWorkItem { [weak self] in
            guard let self, !self.running else { return }
            self.items.removeAll()
            Windows.close("progress")
        }
        hideWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: w)
    }

    func dismiss(_ item: Item) {
        item.cancel.cancel()
        items.removeAll { $0.id == item.id }
        if items.isEmpty { Windows.close("progress") }
    }
}

// MARK: - Feedback

enum Feedback {
    @MainActor static func highlight() {
        guard AppSettings.shared.soundAndHaptics else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        NSSound(named: "Tink")?.play()
    }
    @MainActor static func success() {
        guard AppSettings.shared.soundAndHaptics else { return }
        NSSound(named: "Glass")?.play()
    }
    @MainActor static func failure() {
        guard AppSettings.shared.soundAndHaptics else { return }
        NSSound(named: "Basso")?.play()
    }
}

enum Alerts {
    @MainActor static func show(_ title: String, _ message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = title
        a.informativeText = message
        a.runModal()
    }
}

// MARK: - Windows

@MainActor
enum Windows {
    private static var open: [String: NSWindow] = [:]
    private static var closers: [String: NSObjectProtocol] = [:]

    /// Shows a SwiftUI view in a window, reusing the window when `id` is already open.
    @discardableResult
    static func show<V: View>(_ id: String, title: String, size: CGSize, resizable: Bool = true, panel: Bool = false, activate: Bool = true, @ViewBuilder _ view: () -> V) -> NSWindow {
        if let w = open[id] {
            if activate { NSApp.activate(ignoringOtherApps: true) }
            w.makeKeyAndOrderFront(nil)
            return w
        }
        var style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable]
        if resizable { style.insert(.resizable) }
        let w: NSWindow = panel ? NSPanel(contentRect: CGRect(origin: .zero, size: size), styleMask: style.union(.utilityWindow), backing: .buffered, defer: false)
                                : NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: style, backing: .buffered, defer: false)
        w.title = title
        w.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: view().frame(minWidth: min(size.width, 360), maxWidth: .infinity, minHeight: min(size.height, 240), maxHeight: .infinity))
        // Keep the window at the requested size instead of shrinking it to the SwiftUI minimum.
        host.sizingOptions = [.minSize]
        w.contentView = host
        w.setContentSize(size)
        w.center()
        open[id] = w
        closers[id] = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
            MainActor.assumeIsolated {
                open[id] = nil
                if let c = closers.removeValue(forKey: id) { NotificationCenter.default.removeObserver(c) }
                if open.values.allSatisfy({ !$0.isVisible || $0 is NSPanel }) { NSApp.setActivationPolicy(.accessory) }
            }
        }
        if activate {
            // Editor windows need a Dock presence to take keyboard focus reliably.
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        }
        w.makeKeyAndOrderFront(nil)
        return w
    }

    static func close(_ id: String) { open[id]?.close() }

    static func showProgress() {
        let w = show("progress", title: "Dropwheel", size: CGSize(width: 340, height: 220), resizable: true, panel: true, activate: false) { ProgressPanel() }
        w.level = .floating
        if let screen = NSScreen.main?.visibleFrame { w.setFrameOrigin(CGPoint(x: screen.maxX - w.frame.width - 20, y: screen.minY + 20)) }
        w.orderFrontRegardless()
    }

    static func showSettings() { show("settings", title: "Dropwheel Settings", size: CGSize(width: 560, height: 480)) { SettingsView() } }
    static func showWelcome() { show("welcome", title: "Welcome to Dropwheel", size: CGSize(width: 560, height: 520), resizable: false) { WelcomeView() } }
}

// MARK: - App delegate

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    let monitor = DragMonitor()
    let wheel = WheelController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "circle.hexagongrid.fill", accessibilityDescription: "Dropwheel")
        statusItem.menu = buildMenu()
        monitor.onTrigger = { [weak self] point, urls, group in self?.wheel.show(at: point, urls: urls, group: group) }
        monitor.onDragEnd = { [weak self] in self?.wheel.hide(after: 0.15) }
        monitor.start()
        // `--editor <action-id> <files…>` opens one tool directly, for scripting and UI checks.
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--editor"), args.count > i + 2 {
            let files = args[(i + 2)...].map { URL(fileURLWithPath: $0) }
            if let action = Catalog.actions(for: files).first(where: { $0.id == args[i + 1] }) { wheel.runner.perform(action, files) }
            else if args[i + 1] == "settings" { Windows.showSettings() }
            else if args[i + 1] == "float" { FloatManager.shared.create(with: files) }
            else if args[i + 1] == "wheel" { wheel.show(at: NSEvent.mouseLocation, urls: files, sticky: true) }
            else if let g = Action.Group(rawValue: args[i + 1]) { wheel.show(at: NSEvent.mouseLocation, urls: files, group: g, sticky: true) }
        } else if !AppSettings.shared.completedWelcome { Windows.showWelcome() }
        // Debug aid: write a PNG of every window, since screen capture needs a permission the build may not have.
        if let dir = ProcessInfo.processInfo.environment["DROPWHEEL_SNAPSHOT_DIR"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                for (i, w) in NSApp.windows.enumerated() where w.isVisible {
                    guard let v = w.contentView?.superview ?? w.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { continue }
                    v.cacheDisplay(in: v.bounds, to: rep)
                    let name = w.title.isEmpty ? "window-\(i)" : w.title.replacingOccurrences(of: "/", with: "-")
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
                }
                NSApp.terminate(nil)
            }
        }
        // Files opened with the app icon (Dock or "Open With") show the wheel at the cursor.
        log.info("Monitoring drag-to-convert gestures")
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        wheel.show(at: NSEvent.mouseLocation, urls: urls, sticky: true)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        Windows.showSettings(); return true
    }

    func buildMenu() -> NSMenu {
        let m = NSMenu()
        m.delegate = self
        let status = NSMenuItem(title: "Dropwheel is ready", action: nil, keyEquivalent: "")
        status.tag = 1
        m.addItem(status)
        m.addItem(.separator())
        m.addItem(item("Create a New Float", #selector(newFloat), "n"))
        m.addItem(item("Choose Files to Convert…", #selector(chooseFiles), "o"))
        m.addItem(.separator())
        m.addItem(item("Getting Started…", #selector(welcome), ""))
        m.addItem(item("Settings…", #selector(settings), ","))
        m.addItem(.separator())
        m.addItem(item("Quit Dropwheel", #selector(NSApplication.terminate(_:)), "q"))
        return m
    }

    func item(_ title: String, _ action: Selector, _ key: String) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = action == #selector(NSApplication.terminate(_:)) ? NSApp : self
        return i
    }

    @objc func newFloat() { FloatManager.shared.create(with: []) }
    @objc func welcome() { Windows.showWelcome() }
    @objc func settings() { Windows.showSettings() }
    @objc func chooseFiles() {
        NSApp.activate(ignoringOtherApps: true)
        let p = NSOpenPanel()
        p.allowsMultipleSelection = true
        p.canChooseDirectories = true
        if p.runModal() == .OK { wheel.show(at: NSEvent.mouseLocation, urls: p.urls, sticky: true) }
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        menu.item(withTag: 1)?.title = TaskStore.shared.running ? "Dropwheel is working…" : "Ready. Drag files and tap ⇧, ⌘ or ⌃."
    }
}
