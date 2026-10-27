import Foundation

// MARK: - Settings shared by the app and the CLI

public struct CompressionSettings: Codable, Equatable, Sendable {
    public enum Mode: String, Codable, CaseIterable, Sendable { case preset, targetSize }
    public var mode: Mode = .preset
    public var level: CompressionLevel = .medium
    public var imageTargetKB = 500
    public var videoTargetMB = 25
    public var maxVideoHeight = 0 // 0 = keep original dimensions
    public var encoding: VideoEncoding = .h264
    public init() {}

    var video: VideoCompression {
        VideoCompression(level: level, targetBytes: mode == .targetSize ? Int64(videoTargetMB) * 1_000_000 : nil,
                         maxHeight: maxVideoHeight > 0 ? maxVideoHeight : nil, encoding: encoding)
    }
    var imageTarget: Int64? { mode == .targetSize ? Int64(imageTargetKB) * 1000 : nil }
}

// MARK: - Actions

public struct Action: Identifiable, Hashable, Sendable {
    public enum Group: String, Sendable { case format, tool, file }
    public let id: String
    public let title: String
    public let symbol: String
    public let group: Group
    public let editor: Bool

    public static func format(_ ext: String) -> Action {
        Action(id: "convert:\(ext)", title: ext.uppercased(), symbol: "", group: .format, editor: false)
    }
}

public enum Catalog {
    static func tool(_ id: String, _ title: String, _ symbol: String, editor: Bool = false) -> Action {
        Action(id: id, title: title, symbol: symbol, group: .tool, editor: editor)
    }
    static func file(_ id: String, _ title: String, _ symbol: String) -> Action {
        Action(id: id, title: title, symbol: symbol, group: .file, editor: false)
    }

    public static let compress = tool("compress", "Compress", "arrow.down.right.and.arrow.up.left")
    public static let removeMetadata = tool("removeMetadata", "Remove Metadata", "eye.slash")
    public static let readQR = tool("readQR", "Read QR Codes", "qrcode.viewfinder")

    public static let fileActions: [Action] = [
        file("float", "Float", "pin"),
        file("move", "Move to…", "folder"),
        file("copyFiles", "Copy Files", "doc.on.doc"),
        file("copyPaths", "Copy Paths", "link"),
        file("terminal", "Terminal", "terminal"),
        file("airdrop", "AirDrop", "airplayaudio"),
        file("archive:zip", "ZIP", "archivebox"),
        file("archive:7z", "7Z", "archivebox"),
        file("archive:tar.gz", "TAR.GZ", "archivebox"),
        file("archive:rar", "RAR", "archivebox"),
    ]

    /// Every target the wheel can show for these files, in display order.
    public static func actions(for urls: [URL]) -> [Action] {
        guard !urls.isEmpty else { return [] }
        let kinds = Set(urls.map(kind(of:)))
        let n = urls.count
        let exts = Set(urls.map { $0.pathExtension.lowercased() == "jpeg" ? "jpg" : $0.pathExtension.lowercased() })
        var a: [Action] = []
        func formats(_ list: [String]) { a += list.filter { !(exts.count == 1 && exts.contains($0)) }.map(Action.format) }

        if kinds.count == 1 {
            switch kinds.first! {
            case .image:
                formats(Formats.imageOut + (exts == ["gif"] ? ["mp4", "webm"] : []))
                a += [compress,
                      tool("resize", "Resize", "arrow.up.left.and.arrow.down.right", editor: true),
                      tool("crop", "Crop", "crop", editor: true),
                      tool("annotate", "Annotate", "pencil.tip.crop.circle", editor: true),
                      tool("redact", "Redact", "eye.trianglebadge.exclamationmark", editor: true),
                      tool("background", "Background", "person.crop.rectangle", editor: true),
                      tool("adjust", "Adjust", "slider.horizontal.3", editor: true),
                      tool("metadata", "Metadata", "info.circle", editor: true),
                      removeMetadata, readQR]
                if n >= 2 { a.insert(tool("collage", "Collage", "square.grid.2x2", editor: true), at: a.firstIndex(of: compress)!) }
            case .video:
                formats(Formats.videoOut)
                a += [compress,
                      tool("trim", "Trim", "timeline.selection", editor: true),
                      tool("split", "Split", "scissors", editor: true),
                      tool("crop", "Crop", "crop", editor: true),
                      tool("speed", "Speed", "gauge.with.dots.needle.67percent", editor: true),
                      tool("frames", "Frames", "photo.on.rectangle", editor: true),
                      tool("redact", "Redact", "eye.trianglebadge.exclamationmark", editor: true),
                      tool("bleep", "Bleep", "speaker.slash", editor: true),
                      tool("normalize", "Normalize", "waveform.badge.magnifyingglass", editor: true),
                      removeMetadata]
                if n >= 2 { a.insert(tool("join", "Join", "film.stack"), at: a.firstIndex(of: compress)!) }
            case .audio:
                formats(Formats.audioOut)
                a += [compress,
                      tool("trim", "Trim", "timeline.selection", editor: true),
                      tool("bleep", "Bleep", "speaker.slash", editor: true),
                      tool("normalize", "Normalize", "waveform.badge.magnifyingglass", editor: true),
                      tool("channels", "Channels", "speaker.wave.2", editor: true),
                      tool("visualizer", "Visualizer", "waveform", editor: true),
                      removeMetadata]
                if n >= 2 { a.insert(tool("join", "Join", "music.note.list"), at: a.firstIndex(of: compress)!) }
            case .pdf:
                formats(["png", "jpg", "docx", "rtf", "txt", "epub", "pages"])
                a += [compress,
                      tool("organize", "Organize", "rectangle.grid.1x2", editor: true),
                      tool("sameWidth", "Same Width", "arrow.left.and.right.square"),
                      removeMetadata, readQR]
                if n >= 2 { a.insert(tool("merge", "Combine", "doc.on.doc.fill"), at: 0) }
            case .document:
                formats(Formats.documentOut)
            case .office:
                formats(Formats.officeOut + ["jpg"])
            case .subtitle:
                formats(Formats.subtitleOut)
            case .archive:
                a.append(tool("extract", "Extract", "shippingbox.and.arrow.backward"))
            case .folder, .other:
                break
            }
        } else if kinds == [.video, .subtitle] {
            a.append(tool("subtitles", "Add Subtitles", "captions.bubble"))
        } else if kinds == [.audio, .image] {
            a.append(tool("visualizer", "Visualizer", "waveform", editor: true))
        } else if kinds.isSubset(of: [.image, .pdf]) {
            a.append(tool("merge", "Combine PDF", "doc.on.doc.fill"))
        }
        let hasRar = Tools.path("rar") != nil
        return a + fileActions.filter { $0.id != "archive:rar" || hasRar }
    }

    /// Runs an action that needs no editor. File actions that need AppKit run in the app.
    public static func run(_ id: String, _ urls: [URL], settings: CompressionSettings = .init(), preserveMetadata: Bool = true,
                           progress: Progress? = nil, cancel: Cancellation? = nil) throws -> [URL] {
        let parts = id.split(separator: ":", maxSplits: 1).map(String.init)
        switch parts[0] {
        case "convert":
            let ext = parts[1]
            if ext == "pdf", urls.count > 1, urls.allSatisfy({ kind(of: $0) == .image }) { return [try ImageOps.imagesToPDF(urls)] }
            return try each(urls, progress) { u in
                switch kind(of: u) {
                case .image: return try ImageOps.convert(u, to: ext, preserveMetadata: preserveMetadata)
                case .video: return try VideoOps.convert(u, to: ext, progress: progress, cancel: cancel)
                case .audio: return try AudioOps.convert(u, to: ext, progress: progress, cancel: cancel)
                case .pdf: return ["png", "jpg"].contains(ext) ? try PDFOps.toImages(u, ext: ext) : try DocOps.convert(u, to: ext)
                case .document: return try DocOps.convert(u, to: ext)
                case .office: return try Office.convert(u, to: ext)
                case .subtitle: return try VideoOps.convertSubtitles(u, to: ext)
                default: throw OpError("Unsupported file type.")
                }
            }
        case "compress":
            return try each(urls, progress) { u in
                switch kind(of: u) {
                case .image: return try ImageOps.compress(u, level: settings.level, targetBytes: settings.imageTarget)
                case .video: return try VideoOps.compress(u, settings.video, progress: progress, cancel: cancel)
                case .audio: return try AudioOps.compress(u, level: settings.level, targetBytes: settings.mode == .targetSize ? Int64(settings.videoTargetMB) * 1_000_000 : nil, progress: progress, cancel: cancel)
                case .pdf: return try PDFOps.compress(u, level: settings.level)
                default: throw OpError("Unsupported file type.")
                }
            }
        case "removeMetadata": return try each(urls, progress, MetadataOps.removeAll)
        case "sameWidth": return try each(urls, progress, PDFOps.sameWidth)
        case "extract": return try each(urls, progress) { try ArchiveOps.extract($0, cancel: cancel) }
        case "archive": return [try ArchiveOps.create(urls, format: parts[1], cancel: cancel)]
        case "merge":
            if urls.allSatisfy({ kind(of: $0) == .pdf }) { return [try PDFOps.merge(urls)] }
            // Mixed images and PDFs: images become pages first.
            var tmp: [URL] = []
            defer { tmp.forEach { try? FileManager.default.removeItem(at: $0) } }
            let pdfs = try urls.map { u -> URL in
                guard kind(of: u) == .image else { return u }
                let p = try ImageOps.imagesToPDF([u]); tmp.append(p); return p
            }
            return [try PDFOps.merge(pdfs)]
        case "join":
            return [kind(of: urls[0]) == .video ? try VideoOps.join(urls, progress: progress, cancel: cancel) : try AudioOps.join(urls, progress: progress, cancel: cancel)]
        case "subtitles":
            let subs = urls.filter { kind(of: $0) == .subtitle }
            guard let s = subs.first else { throw OpError("Drop a subtitle file with the video.") }
            return try urls.filter { kind(of: $0) == .video }.map { try VideoOps.addSubtitles($0, s, progress: progress, cancel: cancel) }
        default:
            throw OpError("\(id) needs the Dropwheel app.")
        }
    }

    static func each(_ urls: [URL], _ progress: Progress?, _ body: (URL) throws -> URL) throws -> [URL] {
        var outs: [URL] = [], errors: [String] = []
        for (i, u) in urls.enumerated() {
            do { outs.append(try body(u)) } catch { errors.append("\(u.lastPathComponent): \(error.localizedDescription)") }
            progress?(Double(i + 1) / Double(urls.count))
        }
        if outs.isEmpty, !errors.isEmpty { throw OpError(errors.joined(separator: "\n")) }
        if !errors.isEmpty { throw PartialFailure(outputs: outs, errors: errors) }
        return outs
    }
}

public struct PartialFailure: LocalizedError, Sendable {
    public let outputs: [URL]
    public let errors: [String]
    public var errorDescription: String? { "Finished with errors:\n" + errors.joined(separator: "\n") }
}
