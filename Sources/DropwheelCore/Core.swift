import Foundation
import ImageIO
import PDFKit

// MARK: - File kinds

public enum FileKind: String, CaseIterable, Sendable {
    case image, video, audio, pdf, document, office, archive, subtitle, folder, other
}

public enum Formats {
    public static let image = ["jpg", "jpeg", "png", "heic", "heif", "webp", "avif", "tiff", "tif", "gif", "bmp", "svg", "psd", "ico", "icns", "jp2", "tga"]
    public static let video = ["mp4", "mov", "m4v", "mkv", "webm", "avi", "mpg", "mpeg", "wmv", "flv", "3gp", "ts"]
    public static let audio = ["mp3", "m4a", "aac", "wav", "aiff", "aif", "flac", "ogg", "opus", "caf", "wma"]
    public static let document = ["docx", "doc", "rtf", "rtfd", "txt", "md", "markdown", "html", "htm", "epub", "textclipping", "odt", "pages"]
    public static let office = ["pptx", "ppt", "key", "xlsx", "xls", "csv", "numbers"]
    public static let archive = ["zip", "rar", "7z", "tar", "gz", "tgz", "xz", "txz", "bz2", "tbz"]
    public static let subtitle = ["srt", "vtt"]

    /// Output formats offered on the wheel for each kind.
    public static let imageOut = ["jpg", "png", "heic", "webp", "avif", "tiff", "gif", "bmp", "pdf"]
    public static let videoOut = ["mp4", "mov", "mkv", "webm", "avi", "m4v", "gif", "mp3", "m4a", "wav"]
    public static let audioOut = ["mp3", "m4a", "aac", "wav", "aiff", "flac", "ogg", "opus"]
    public static let documentOut = ["pdf", "epub", "pages", "docx", "rtf", "txt", "html"]
    public static let pdfOut = ["png", "jpg", "docx", "rtf", "txt"]
    public static let officeOut = ["pdf", "png"]
    public static let subtitleOut = ["srt", "vtt"]
    public static let archiveOut = ["zip", "7z", "tar.gz", "tar.xz", "rar"]
}

public func kind(of url: URL) -> FileKind {
    let ext = url.pathExtension.lowercased()
    if Formats.image.contains(ext) { return .image }
    if Formats.video.contains(ext) { return .video }
    if Formats.audio.contains(ext) { return .audio }
    if ext == "pdf" { return .pdf }
    if Formats.document.contains(ext) { return .document }
    if Formats.office.contains(ext) { return .office }
    if Formats.archive.contains(ext) { return .archive }
    if Formats.subtitle.contains(ext) { return .subtitle }
    var isDir: ObjCBool = false
    if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue { return .folder }
    return .other
}

// MARK: - Errors

public struct OpError: LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

// MARK: - Output naming

/// Returns a path next to `input` that does not exist yet. Dropwheel never overwrites a file.
public func outputURL(for input: URL, ext: String, suffix: String? = nil, in dir: URL? = nil) -> URL {
    let folder = dir ?? input.deletingLastPathComponent()
    var base = input.deletingPathExtension().lastPathComponent
    if base.hasSuffix(".tar") { base = String(base.dropLast(4)) }
    if let suffix { base += " (\(suffix))" }
    else if ext.lowercased() == input.pathExtension.lowercased() { base += " (converted)" }
    return uniqueURL(folder.appendingPathComponent(base), ext: ext)
}

public func uniqueURL(_ stem: URL, ext: String) -> URL {
    let fm = FileManager.default
    let dot = ext.isEmpty ? "" : "." + ext
    var candidate = URL(fileURLWithPath: stem.path + dot)
    var n = 2
    while fm.fileExists(atPath: candidate.path) {
        candidate = URL(fileURLWithPath: "\(stem.path) \(n)\(dot)")
        n += 1
    }
    return candidate
}

public func tempURL(ext: String) -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Dropwheel", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent(UUID().uuidString + (ext.isEmpty ? "" : "." + ext))
}

/// Writes to a temp path, verifies the result, then moves it to `final`.
/// A failed verification leaves nothing behind.
@discardableResult
public func produce(_ final: URL, verify: (URL) throws -> Void, _ make: (URL) throws -> Void) throws -> URL {
    let ext = final.lastPathComponent.hasSuffix(".tar.gz") ? "tar.gz" : final.lastPathComponent.hasSuffix(".tar.xz") ? "tar.xz" : final.pathExtension
    let tmp = tempURL(ext: ext)
    defer { try? FileManager.default.removeItem(at: tmp) }
    try make(tmp)
    guard FileManager.default.fileExists(atPath: tmp.path) else { throw OpError("No output was produced.") }
    try verify(tmp)
    try FileManager.default.moveItem(at: tmp, to: final)
    return final
}

public func fileSize(_ url: URL) -> Int64 {
    (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
}

/// Compressed output that is not smaller than the input is refused.
public func requireSmaller(_ out: URL, than input: URL) throws {
    if fileSize(out) >= fileSize(input) {
        throw OpError("\(input.lastPathComponent) is already well compressed. The result was not smaller, so no output was saved.")
    }
}

// MARK: - External tools

public enum Tools {
    /// Finds a helper. A copy in the app bundle wins over Homebrew and system copies.
    public static func path(_ name: String) -> String? {
        var dirs: [String] = []
        if let res = Bundle.main.resourceURL?.appendingPathComponent("Tools").path { dirs.append(res) }
        dirs += ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        return dirs.map { "\($0)/\(name)" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    public static func require(_ name: String, hint: String) throws -> String {
        guard let p = path(name) else { throw OpError("\(name) is not installed. \(hint)") }
        return p
    }

    public static var ffmpeg: String { get throws { try require("ffmpeg", hint: "Install it with: brew install ffmpeg") } }
    public static var ffprobe: String { get throws { try require("ffprobe", hint: "Install it with: brew install ffmpeg") } }
}

public final class Cancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    public init() {}
    public var isCancelled: Bool { lock.withLock { cancelled } }
    public func cancel() { lock.withLock { cancelled = true; process?.terminate() } }
    func attach(_ p: Process) { lock.withLock { process = p } }
}

public typealias Progress = @Sendable (Double) -> Void

/// Runs a tool and returns stdout. `onLine` sees each stdout line as it arrives.
@discardableResult
public func run(_ exe: String, _ args: [String], cwd: URL? = nil, cancel: Cancellation? = nil,
                onLine: ((String) -> Void)? = nil) throws -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: exe)
    p.arguments = args
    if let cwd { p.currentDirectoryURL = cwd }
    let out = Pipe(), err = Pipe()
    p.standardOutput = out
    p.standardError = err
    p.standardInput = FileHandle.nullDevice
    var collected = Data()
    let lock = NSLock()
    out.fileHandleForReading.readabilityHandler = { h in
        let d = h.availableData
        guard !d.isEmpty else { return }
        lock.withLock { collected.append(d) }
        if let onLine, let s = String(data: d, encoding: .utf8) { s.split(separator: "\n").forEach { onLine(String($0)) } }
    }
    var errData = Data()
    err.fileHandleForReading.readabilityHandler = { h in
        let d = h.availableData
        lock.withLock { errData.append(d); if errData.count > 200_000 { errData.removeFirst(100_000) } }
    }
    try p.run()
    cancel?.attach(p)
    p.waitUntilExit()
    out.fileHandleForReading.readabilityHandler = nil
    err.fileHandleForReading.readabilityHandler = nil
    collected.append(out.fileHandleForReading.readDataToEndOfFile())
    if cancel?.isCancelled == true { throw OpError("Cancelled.") }
    guard p.terminationStatus == 0 else {
        let tail = String(data: errData, encoding: .utf8)?.split(separator: "\n").suffix(4).joined(separator: "\n") ?? ""
        throw OpError("\(URL(fileURLWithPath: exe).lastPathComponent) failed: \(tail)")
    }
    return String(data: collected, encoding: .utf8) ?? ""
}

// MARK: - Verification

public func verifyImage(_ url: URL) throws {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(src) > 0,
          CGImageSourceCreateImageAtIndex(src, 0, nil) != nil else {
        // ImageIO cannot read WebP on every macOS version. cwebp output gets its own check.
        if url.pathExtension.lowercased() == "webp", let head = try? FileHandle(forReadingFrom: url).read(upToCount: 12),
           head.count == 12, String(data: head[8..<12], encoding: .ascii) == "WEBP" { return }
        throw OpError("The converted image could not be verified. No output was saved.")
    }
}

public func verifyPDF(_ url: URL) throws {
    guard let doc = PDFDocument(url: url), doc.pageCount > 0 else {
        throw OpError("The converted PDF could not be verified. No output was saved.")
    }
}

public struct MediaInfo: Sendable {
    public var duration: Double
    public var width: Int
    public var height: Int
    public var hasVideo: Bool
    public var hasAudio: Bool
    public var audioChannels: Int
    public var sampleRate: Int
    public var videoCodec: String
    public var audioCodec: String
    public var fps: Double
}

public func probe(_ url: URL) throws -> MediaInfo {
    let json = try run(Tools.ffprobe, ["-v", "error", "-print_format", "json", "-show_format", "-show_streams", url.path])
    guard let obj = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else { throw OpError("Could not read media info.") }
    let streams = obj["streams"] as? [[String: Any]] ?? []
    let format = obj["format"] as? [String: Any] ?? [:]
    // Still images (cover art) count as video only when they are not attached pictures.
    let v = streams.first { $0["codec_type"] as? String == "video" && (($0["disposition"] as? [String: Any])?["attached_pic"] as? Int ?? 0) == 0 }
    let a = streams.first { $0["codec_type"] as? String == "audio" }
    var fps = 30.0
    if let r = v?["avg_frame_rate"] as? String {
        let parts = r.split(separator: "/").compactMap { Double($0) }
        if parts.count == 2, parts[1] > 0, parts[0] > 0 { fps = parts[0] / parts[1] }
    }
    return MediaInfo(
        duration: Double(format["duration"] as? String ?? "") ?? 0,
        width: v?["width"] as? Int ?? 0, height: v?["height"] as? Int ?? 0,
        hasVideo: v != nil, hasAudio: a != nil,
        audioChannels: a?["channels"] as? Int ?? 0,
        sampleRate: Int(a?["sample_rate"] as? String ?? "") ?? 44100,
        videoCodec: v?["codec_name"] as? String ?? "", audioCodec: a?["codec_name"] as? String ?? "",
        fps: fps)
}

public func verifyMedia(_ url: URL, video: Bool? = nil, audio: Bool? = nil) throws {
    guard let info = try? probe(url), info.duration > 0 || info.hasVideo else {
        throw OpError("The converted file could not be verified. No output was saved.")
    }
    if video == true, !info.hasVideo { throw OpError("The output has no video track. No output was saved.") }
    if audio == true, !info.hasAudio { throw OpError("The output has no audio track. No output was saved.") }
}

public func verifyArchive(_ url: URL) throws {
    let list = try run(Tools.require("bsdtar", hint: ""), ["-tf", url.path])
    if list.split(separator: "\n").isEmpty { throw OpError("The archive could not be verified. No output was saved.") }
}

public func verifyDirectoryNotEmpty(_ url: URL) throws {
    if (try? FileManager.default.contentsOfDirectory(atPath: url.path))?.isEmpty ?? true {
        throw OpError("No files were produced.")
    }
}
