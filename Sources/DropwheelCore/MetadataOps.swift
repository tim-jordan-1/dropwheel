import Foundation
import ImageIO
import PDFKit

public struct MetadataField: Identifiable, Hashable, Sendable {
    public let id: String      // XMP path, for example "tiff:Make"
    public let label: String
    public var value: String
}

public enum MetadataOps {
    /// Editable fields, as XMP paths that ImageIO maps to EXIF, TIFF, GPS and IPTC.
    public static let editable: [(path: String, label: String)] = [
        ("dc:title", "Title"),
        ("dc:description", "Description"),
        ("dc:creator", "Author"),
        ("dc:rights", "Copyright"),
        ("dc:subject", "Keywords"),
        ("tiff:Make", "Camera Make"),
        ("tiff:Model", "Camera Model"),
        ("tiff:Software", "Software"),
        ("exif:DateTimeOriginal", "Date Taken"),
        ("exif:GPSLatitude", "GPS Latitude"),
        ("exif:GPSLongitude", "GPS Longitude"),
        ("exifEX:LensModel", "Lens"),
    ]

    /// Every tag in the image, for the read-only list, plus the editable fields.
    public static func read(_ url: URL) -> (fields: [MetadataField], all: [(String, String)]) {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return ([], []) }
        let meta = CGImageSourceCopyMetadataAtIndex(src, 0, nil)
        var fields: [MetadataField] = []
        for (path, label) in editable {
            var value = ""
            if let meta, let tag = CGImageMetadataCopyTagWithPath(meta, nil, path as CFString) { value = describe(CGImageMetadataTagCopyValue(tag)) }
            fields.append(MetadataField(id: path, label: label, value: value))
        }
        var all: [(String, String)] = []
        if let meta, let tags = CGImageMetadataCopyTags(meta) as? [CGImageMetadataTag] {
            for t in tags {
                let prefix = CGImageMetadataTagCopyPrefix(t) as String? ?? ""
                let name = CGImageMetadataTagCopyName(t) as String? ?? ""
                all.append(("\(prefix):\(name)", describe(CGImageMetadataTagCopyValue(t))))
            }
        }
        return (fields, all.sorted { $0.0 < $1.0 })
    }

    static func describe(_ v: CFTypeRef?) -> String {
        switch v {
        case let s as String: return s
        case let arr as [CGImageMetadataTag]: return arr.map { describe(CGImageMetadataTagCopyValue($0)) }.joined(separator: ", ")
        case let arr as [Any]: return arr.map { describe($0 as CFTypeRef) }.joined(separator: ", ")
        case let d as [String: Any]: return d.values.map { describe($0 as CFTypeRef) }.joined(separator: ", ")
        case let n as NSNumber: return n.stringValue
        default: return v.map { "\($0)" } ?? ""
        }
    }

    /// Lossless metadata rewrite. Pixels are hashed before and after, and a changed image is refused.
    static func rewrite(_ url: URL, suffix: String, metadata: CGImageMetadata, merge: Bool, stripAll: Bool) throws -> URL {
        let out = outputURL(for: url, ext: url.pathExtension, suffix: suffix)
        let before = ImageOps.pixelHash(url)
        return try produce(out, verify: { tmp in
            guard let before, ImageOps.pixelHash(tmp) == before else {
                throw OpError("The image could not be verified. No output was saved.")
            }
        }) { tmp in
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), let type = CGImageSourceGetType(src),
                  let dest = CGImageDestinationCreateWithURL(tmp as CFURL, type, 1, nil) else {
                throw OpError("\(url.lastPathComponent) is not a readable image.")
            }
            var opts: [CFString: Any] = [kCGImageDestinationMetadata: metadata, kCGImageDestinationMergeMetadata: merge]
            if stripAll {
                opts[kCGImageMetadataShouldExcludeGPS] = true
                opts[kCGImageMetadataShouldExcludeXMP] = true
            }
            var err: Unmanaged<CFError>?
            if CGImageDestinationCopyImageSource(dest, src, opts as CFDictionary, &err) { return }
            // Formats ImageIO cannot copy losslessly are re-encoded only when the codec is lossless.
            guard ["png", "tiff", "tif", "bmp"].contains(url.pathExtension.lowercased()) else {
                throw OpError("Dropwheel cannot edit metadata in .\(url.pathExtension) files without changing the image.")
            }
            let d2 = CGImageDestinationCreateWithURL(tmp as CFURL, type, 1, nil)!
            CGImageDestinationAddImageFromSource(d2, src, 0, stripAll ? [:] as CFDictionary : nil)
            guard CGImageDestinationFinalize(d2) else { throw OpError("Could not write the image.") }
        }
    }

    public static func edit(_ url: URL, values: [String: String]) throws -> URL {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { throw OpError("\(url.lastPathComponent) is not a readable image.") }
        let meta = CGImageSourceCopyMetadataAtIndex(src, 0, nil).flatMap { CGImageMetadataCreateMutableCopy($0) } ?? CGImageMetadataCreateMutable()
        for (path, value) in values {
            CGImageMetadataRemoveTagWithPath(meta, nil, path as CFString)
            guard !value.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            let v: CFTypeRef = ["dc:subject", "dc:creator"].contains(path)
                ? value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } as CFArray
                : value as CFString
            if !CGImageMetadataSetValueWithPath(meta, nil, path as CFString, v) {
                throw OpError("Could not set \(path).")
            }
        }
        return try rewrite(url, suffix: "edited", metadata: meta, merge: false, stripAll: false)
    }

    /// Removes metadata from images, media and PDFs. Image and media data are left intact.
    public static func removeAll(_ url: URL) throws -> URL {
        switch kind(of: url) {
        case .image:
            return try rewrite(url, suffix: "no metadata", metadata: CGImageMetadataCreateMutable(), merge: false, stripAll: true)
        case .video, .audio:
            let out = outputURL(for: url, ext: url.pathExtension, suffix: "no metadata")
            return try produce(out, verify: { try verifyMedia($0) }) {
                try run(Tools.ffmpeg, ["-v", "error", "-y", "-i", url.path, "-map", "0", "-map_metadata", "-1", "-map_chapters", "-1",
                                       "-c", "copy", "-fflags", "+bitexact", "-flags:v", "+bitexact", "-flags:a", "+bitexact", $0.path])
            }
        case .pdf:
            let out = outputURL(for: url, ext: "pdf", suffix: "no metadata")
            return try produce(out, verify: verifyPDF) { tmp in
                guard let doc = PDFDocument(url: url) else { throw OpError("\(url.lastPathComponent) is not a readable PDF.") }
                doc.documentAttributes = [:]
                guard doc.write(to: tmp) else { throw OpError("Could not write the PDF.") }
            }
        default:
            throw OpError("Unsupported file type.")
        }
    }
}
