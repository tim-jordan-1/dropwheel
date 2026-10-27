import AppKit

// MARK: - Office documents through Keynote, Numbers and Pages

/// Office files are rendered by Apple's iWork apps over AppleScript.
/// The first run asks for Automation permission for each app.
public enum Office {
    public static func installed(_ app: String) -> Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID(app)) != nil
    }

    static func bundleID(_ app: String) -> String {
        ["Keynote": "com.apple.iWork.Keynote", "Numbers": "com.apple.iWork.Numbers", "Pages": "com.apple.iWork.Pages"][app]!
    }

    static func app(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "pptx", "ppt", "key": return "Keynote"
        case "xlsx", "xls", "csv", "numbers": return "Numbers"
        default: return "Pages"
        }
    }

    static func quote(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }

    static func osascript(_ script: String) throws {
        do { try run("/usr/bin/osascript", ["-e", script]) } catch {
            let msg = (error as? OpError)?.message ?? "\(error)"
            if msg.contains("-1743") { throw OpError("Dropwheel needs permission to control iWork apps. Allow it in System Settings > Privacy & Security > Automation.") }
            throw OpError(msg)
        }
    }

    /// iWork apps are sandboxed, so they write into their own container and Dropwheel moves the file out.
    static func scratch(_ app: String, ext: String) -> URL {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers/\(bundleID(app))/Data/tmp", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("dropwheel-\(UUID().uuidString).\(ext)")
    }

    static func export(app: String, _ input: URL, to out: URL, as format: String) throws {
        guard installed(app) else { throw OpError("\(app) is needed to convert \(input.lastPathComponent). Install it free from the App Store.") }
        let tmp = scratch(app, ext: out.pathExtension)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try osascript("""
        tell application "\(app)"
            set d to open (POSIX file \(quote(input.path)) as alias)
            export d to (POSIX file \(quote(tmp.path))) as \(format)
            close d saving no
        end tell
        """)
        try FileManager.default.moveItem(at: tmp, to: out)
    }

    static func save(app: String, _ input: URL, to out: URL) throws {
        guard installed(app) else { throw OpError("\(app) is needed to write .\(out.pathExtension) files. Install it free from the App Store.") }
        let tmp = scratch(app, ext: out.pathExtension)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try osascript("""
        tell application "\(app)"
            set d to open (POSIX file \(quote(input.path)) as alias)
            save d in (POSIX file \(quote(tmp.path)))
            close d saving no
        end tell
        """)
        try FileManager.default.moveItem(at: tmp, to: out)
    }

    /// PowerPoint, Keynote, Excel, Numbers, CSV and Word to PDF or page images.
    public static func convert(_ url: URL, to ext: String) throws -> URL {
        let app = app(for: url)
        if ext == "png" || ext == "jpg" {
            // Render from a staged PDF named after the original, then move the images next to it.
            let stage = tempURL(ext: "")
            try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: stage) }
            let staged = stage.appendingPathComponent(url.deletingPathExtension().lastPathComponent + ".pdf")
            try export(app: app, url, to: staged, as: "PDF")
            let rendered = try PDFOps.toImages(staged, ext: ext)
            let isDir = (try? rendered.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            let final = isDir ? uniqueURL(url.deletingLastPathComponent().appendingPathComponent(rendered.lastPathComponent), ext: "")
                              : outputURL(for: url, ext: ext)
            try FileManager.default.moveItem(at: rendered, to: final)
            return final
        }
        let out = outputURL(for: url, ext: ext)
        switch ext {
        case "pdf": return try produce(out, verify: verifyPDF) { try export(app: app, url, to: $0, as: "PDF") }
        case "pages": return try produce(out, verify: { _ in }) { try save(app: "Pages", url, to: $0) }
        case "docx": return try produce(out, verify: { _ in }) { try export(app: "Pages", url, to: $0, as: "Microsoft Word") }
        default: throw OpError("Unsupported file type.")
        }
    }
}

// MARK: - Archives

public enum ArchiveOps {
    static let maxEntries = 200_000
    static let tarSuffixes = [".tar.gz", ".tgz", ".tar.xz", ".txz", ".tar.bz2", ".tbz", ".tar"]

    /// Extracts next to the archive. A single top-level item is placed directly, like Archive Utility.
    public static func extract(_ url: URL, cancel: Cancellation? = nil) throws -> URL {
        let name = url.lastPathComponent.lowercased()
        let fm = FileManager.default
        let work = tempURL(ext: "")
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }
        let isTar = tarSuffixes.contains { name.hasSuffix($0) }
        let single: [String: String] = ["gz": "gunzip", "xz": "xz", "bz2": "bzip2"]
        if !isTar, let tool = single[url.pathExtension.lowercased()] {
            let out = work.appendingPathComponent(url.deletingPathExtension().lastPathComponent)
            try run("/bin/sh", ["-c", "\"$1\" -dc \"$2\" > \"$3\"", "sh", try Tools.require(tool, hint: ""), url.path, out.path], cancel: cancel)
        } else {
            let bsdtar = try Tools.require("bsdtar", hint: "")
            let entries = try run(bsdtar, ["-tf", url.path], cancel: cancel).split(separator: "\n")
            guard !entries.isEmpty else { throw OpError("The archive is empty.") }
            guard entries.count <= maxEntries else { throw OpError("The archive has too many files.") }
            // bsdtar refuses absolute paths and ".." unless -P is passed.
            try run(bsdtar, ["-xf", url.path, "-C", work.path], cancel: cancel)
        }
        let root = work.standardizedFileURL.resolvingSymlinksInPath().path
        let walker = fm.enumerator(at: work, includingPropertiesForKeys: [.isSymbolicLinkKey])
        while let f = walker?.nextObject() as? URL {
            if (try? f.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true,
               !f.resolvingSymlinksInPath().path.hasPrefix(root) {
                throw OpError("The archive contains a link that points outside it. Nothing was extracted.")
            }
        }
        let top = try fm.contentsOfDirectory(at: work, includingPropertiesForKeys: nil).filter { $0.lastPathComponent != "__MACOSX" }
        guard !top.isEmpty else { throw OpError("The archive is empty.") }
        var base = url.deletingPathExtension().lastPathComponent
        if base.lowercased().hasSuffix(".tar") { base = String(base.dropLast(4)) }
        if top.count == 1 {
            let item = top[0]
            let ext = item.pathExtension
            let stem = url.deletingLastPathComponent().appendingPathComponent(item.deletingPathExtension().lastPathComponent)
            let dest = uniqueURL(stem, ext: ext)
            try fm.moveItem(at: item, to: dest)
            return dest
        }
        let dest = uniqueURL(url.deletingLastPathComponent().appendingPathComponent(base), ext: "")
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)
        for item in top { try fm.moveItem(at: item, to: dest.appendingPathComponent(item.lastPathComponent)) }
        return dest
    }

    /// Creates zip, 7z, tar.gz or tar.xz with bsdtar, or RAR with the rar tool when it is installed.
    public static func create(_ urls: [URL], format: String, cancel: Cancellation? = nil) throws -> URL {
        guard let first = urls.first else { throw OpError("Drop at least one item.") }
        let stem = urls.count == 1 ? first.deletingPathExtension().lastPathComponent : "Archive"
        let out = uniqueURL(first.deletingLastPathComponent().appendingPathComponent(stem), ext: format)
        return try produce(out, verify: verifyArchive) { tmp in
            if format == "rar" {
                let rar = try Tools.require("rar", hint: "RAR creation needs the rar command-line tool from rarlab.com.")
                try run(rar, ["a", "-ep1", "-r", "-idq", tmp.path] + urls.map(\.path), cancel: cancel)
                return
            }
            var args = ["-a", "-cf", tmp.path, "--no-mac-metadata"]
            for u in urls { args += ["-C", u.deletingLastPathComponent().path, u.lastPathComponent] }
            try run(try Tools.require("bsdtar", hint: ""), args, cancel: cancel)
        }
    }
}
