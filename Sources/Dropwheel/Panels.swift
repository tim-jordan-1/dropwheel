import AppKit
import DropwheelCore
import SwiftUI

// MARK: - Progress

struct ProgressPanel: View {
    @ObservedObject var store = TaskStore.shared
    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                ForEach(store.items) { TaskRow(item: $0) }
            }.padding(10)
        }
        .frame(minWidth: 300, minHeight: 80)
    }
}

struct TaskRow: View {
    @ObservedObject var item: TaskStore.Item
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.title).font(.system(size: 12, weight: .semibold))
                    Text(item.detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                switch item.state {
                case .running:
                    Button { TaskStore.shared.dismiss(item) } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).help("Cancel")
                case .done(let urls):
                    Button("Show") { NSWorkspace.shared.activateFileViewerSelecting(urls) }.controlSize(.small)
                case .failed:
                    Button { TaskStore.shared.dismiss(item) } label: { Image(systemName: "xmark.circle") }.buttonStyle(.plain)
                }
            }
            switch item.state {
            case .running: ProgressView(value: item.progress).progressViewStyle(.linear)
            case .done: Label("Done", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
            case .failed(let msg): Text(msg).font(.caption).foregroundStyle(.red).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
    }
}

// MARK: - QR codes

struct QRResultsView: View {
    let results: [(String, [String])]
    var body: some View {
        let codes = results.flatMap { r in r.1.map { (r.0, $0) } }
        VStack(alignment: .leading) {
            if codes.isEmpty {
                ContentUnavailableView("No QR codes found", systemImage: "qrcode.viewfinder")
            } else {
                List(codes.indices, id: \.self) { i in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(codes[i].1).textSelection(.enabled).lineLimit(3)
                            Text(codes[i].0).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let url = URL(string: codes[i].1), url.scheme?.hasPrefix("http") == true {
                            Button("Open") { NSWorkspace.shared.open(url) }
                        }
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(codes[i].1, forType: .string)
                        }
                    }
                }
                Button("Copy All") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(codes.map(\.1).joined(separator: "\n"), forType: .string)
                }.padding([.horizontal, .bottom])
            }
        }
    }
}

// MARK: - Settings

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
            FormatSettings().tabItem { Label("Formats", systemImage: "circle.hexagongrid") }
            CompressionSettingsView().tabItem { Label("Compression", systemImage: "arrow.down.right.and.arrow.up.left") }
        }
        .padding()
        .frame(minWidth: 520, minHeight: 440)
    }
}

struct GeneralSettings: View {
    @ObservedObject var s = AppSettings.shared
    var body: some View {
        Form {
            Section("Wheels") {
                Text(DragMonitor.keyHelp)
                Text("Tap one key while dragging files. Tap another key to switch wheels.").font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle("Open at login", isOn: Binding(get: { s.launchAtLogin }, set: { s.launchAtLogin = $0 }))
                Toggle("Sound and haptic feedback", isOn: $s.soundAndHaptics)
                Toggle("Show results in Finder", isOn: $s.revealOutputs)
                Toggle("Preserve metadata when converting images", isOn: $s.preserveMetadata)
                LabeledContent("Terminal app") {
                    HStack {
                        Text(URL(fileURLWithPath: s.terminalApp).deletingPathExtension().lastPathComponent)
                        Button("Choose…") {
                            let p = NSOpenPanel()
                            p.directoryURL = URL(fileURLWithPath: "/Applications")
                            p.allowedContentTypes = [.application]
                            if p.runModal() == .OK, let u = p.url { s.terminalApp = u.path }
                        }
                    }
                }
                Toggle("Debug logging", isOn: $s.debugLogging)
            }
            Section("Engines") {
                ForEach(["ffmpeg", "ffprobe", "cwebp", "gif2webp", "bsdtar", "rar"], id: \.self) { t in
                    LabeledContent(t) { Text(Tools.path(t) ?? "Not installed").foregroundStyle(Tools.path(t) == nil ? .red : .secondary).font(.caption) }
                }
                ForEach(["Pages", "Keynote", "Numbers"], id: \.self) { a in
                    LabeledContent(a) { Text(Office.installed(a) ? "Installed" : "Not installed").font(.caption).foregroundStyle(.secondary) }
                }
            }
        }.formStyle(.grouped)
    }
}

struct FormatSettings: View {
    @ObservedObject var s = AppSettings.shared
    let groups: [(String, [String])] = [
        ("Image", Formats.imageOut), ("Video", Formats.videoOut), ("Audio", Formats.audioOut),
        ("Document", Formats.documentOut), ("Subtitles", Formats.subtitleOut),
    ]
    var body: some View {
        Form {
            Text("Choose which targets appear on the wheel.").foregroundStyle(.secondary)
            ForEach(groups, id: \.0) { name, exts in
                Section(name) {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 5), alignment: .leading) {
                        ForEach(exts, id: \.self) { e in toggle("convert:\(e)", e.uppercased()) }
                    }
                }
            }
            Section("File actions") {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3), alignment: .leading) {
                    ForEach(Catalog.fileActions) { a in toggle(a.id, a.title) }
                }
            }
        }.formStyle(.grouped)
    }

    func toggle(_ id: String, _ title: String) -> some View {
        Toggle(title, isOn: Binding(get: { !s.hiddenActions.contains(id) }, set: { on in if on { s.hiddenActions.remove(id) } else { s.hiddenActions.insert(id) } }))
    }
}

struct CompressionSettingsView: View {
    @ObservedObject var s = AppSettings.shared
    var body: some View {
        Form {
            Section("Compression mode") {
                Picker("Mode", selection: $s.compression.mode) {
                    Text("Preset").tag(CompressionSettings.Mode.preset)
                    Text("Target file size").tag(CompressionSettings.Mode.targetSize)
                }.pickerStyle(.segmented)
                if s.compression.mode == .preset {
                    Picker("Compression preset", selection: $s.compression.level) {
                        Text("Light").tag(CompressionLevel.low); Text("Balanced").tag(CompressionLevel.medium); Text("Strong").tag(CompressionLevel.high)
                    }
                } else {
                    Stepper("Images: \(s.compression.imageTargetKB) KB", value: $s.compression.imageTargetKB, in: 20...20000, step: 50)
                    Stepper("Video and audio: \(s.compression.videoTargetMB) MB", value: $s.compression.videoTargetMB, in: 1...4000)
                }
            }
            Section("Video") {
                Picker("Maximum video height", selection: $s.compression.maxVideoHeight) {
                    Text("Keep original dimensions").tag(0)
                    ForEach([2160, 1440, 1080, 720, 480], id: \.self) { Text("\($0)p").tag($0) }
                }
                Picker("Encoding", selection: $s.compression.encoding) {
                    Text("H.264 (most compatible)").tag(VideoEncoding.h264); Text("HEVC (smaller)").tag(VideoEncoding.hevc)
                }
            }
            Text("Dropwheel never saves a compressed file that is larger than the original.").font(.caption).foregroundStyle(.secondary)
            Button("Restore Compression Defaults") { s.compression = .init() }
        }.formStyle(.grouped)
    }
}

// MARK: - Welcome

struct WelcomeView: View {
    @ObservedObject var s = AppSettings.shared
    @State private var step = 0
    var body: some View {
        VStack(spacing: 18) {
            switch step {
            case 0:
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 112, height: 112)
                Text("Welcome to Dropwheel").font(.largeTitle.bold())
                Text("Convert, compress and edit files without opening an app. Everything happens on your Mac.").multilineTextAlignment(.center).foregroundStyle(.secondary)
            case 1:
                Text("How it works").font(.title.bold())
                VStack(alignment: .leading, spacing: 12) {
                    Label("Start dragging any files, in Finder or any app.", systemImage: "hand.draw")
                    Label("While dragging, tap a key. Its wheel opens around the cursor.", systemImage: "keyboard")
                    Label("Drop on a format or tool. The result is saved next to the original.", systemImage: "circle.hexagongrid")
                    Label("Drop on Float to keep files in a shelf for later.", systemImage: "pin")
                }
                Text(DragMonitor.keyHelp).font(.headline).padding(.top)
            default:
                Image(systemName: "checkmark.circle.fill").font(.system(size: 60)).foregroundStyle(.green)
                Text("Dropwheel is ready").font(.title.bold())
                Toggle("Open at login. Ready whenever you turn on your Mac.", isOn: Binding(get: { s.launchAtLogin }, set: { s.launchAtLogin = $0 }))
                Text("You find Dropwheel in the menu bar.").foregroundStyle(.secondary)
            }
            Spacer()
            HStack {
                if step > 0 { Button("Back") { step -= 1 } }
                Spacer()
                Button(step < 2 ? "Continue" : "Get Started") {
                    if step < 2 { step += 1 } else { s.completedWelcome = true; Windows.close("welcome") }
                }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            }
        }
        .padding(32)
        .frame(width: 560, height: 520)
    }
}
