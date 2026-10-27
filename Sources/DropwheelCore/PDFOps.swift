import AppKit
import PDFKit
import Quartz

public struct PageEdit: Hashable, Sendable {
    public var index: Int     // page index in the source
    public var rotation: Int  // extra rotation in degrees, multiple of 90
    public init(index: Int, rotation: Int = 0) { self.index = index; self.rotation = rotation }
}

public enum PDFOps {
    public static func open(_ url: URL) throws -> PDFDocument {
        guard let doc = PDFDocument(url: url) else { throw OpError("\(url.lastPathComponent) is not a readable PDF.") }
        if doc.isLocked { throw OpError("\(url.lastPathComponent) is password protected.") }
        return doc
    }

    public static func render(_ page: PDFPage, scale: CGFloat) -> CGImage? {
        let box = page.bounds(for: .mediaBox)
        let rotated = page.rotation % 180 != 0
        let w = Int((rotated ? box.height : box.width) * scale), h = Int((rotated ? box.width : box.height) * scale)
        guard w > 0, h > 0, w * h < 400_000_000,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(.white); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.scaleBy(x: scale, y: scale)
        page.draw(with: .mediaBox, to: ctx)
        return ctx.makeImage()
    }

    public static func compress(_ url: URL, level: CompressionLevel = .medium) throws -> URL {
        let doc = try open(url)
        let out = outputURL(for: url, ext: "pdf", suffix: "compressed")
        return try produce(out, verify: { tmp in
            guard let d = PDFDocument(url: tmp), d.pageCount == doc.pageCount else { throw OpError("The compressed PDF could not be verified. No output was saved.") }
            try requireSmaller(tmp, than: url)
        }) { tmp in
            var opts: [PDFDocumentWriteOption: Any] = [.optimizeImagesForScreenOption: true]
            if level != .low { opts[.saveImagesAsJPEGOption] = true }
            if level == .high, let f = QuartzFilter(url: URL(fileURLWithPath: "/System/Library/Filters/Reduce File Size.qfilter")) {
                opts[PDFDocumentWriteOption(rawValue: "QuartzFilter")] = f
            }
            guard doc.write(to: tmp, withOptions: opts) else { throw OpError("Could not write the PDF.") }
        }
    }

    /// Writes each page as an image into a new folder.
    public static func toImages(_ url: URL, ext: String = "png", scale: CGFloat = 2) throws -> URL {
        let doc = try open(url)
        if doc.pageCount == 1, let cg = render(doc.page(at: 0)!, scale: scale) {
            return try produce(outputURL(for: url, ext: ext), verify: verifyImage) { try ImageOps.write(cg, to: $0, ext: ext) }
        }
        let tmp = tempURL(ext: "")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let base = url.deletingPathExtension().lastPathComponent
        for i in 0..<doc.pageCount {
            guard let cg = render(doc.page(at: i)!, scale: scale) else { throw OpError("Page \(i + 1) could not be rendered.") }
            let f = tmp.appendingPathComponent(String(format: "%@ page %03d.%@", base, i + 1, ext))
            try ImageOps.write(cg, to: f, ext: ext)
            try verifyImage(f)
        }
        let dir = uniqueURL(url.deletingLastPathComponent().appendingPathComponent("\(base) pages"), ext: "")
        try FileManager.default.moveItem(at: tmp, to: dir)
        return dir
    }

    /// Scales every page to the widest page's width. Text stays vector.
    public static func sameWidth(_ url: URL) throws -> URL {
        let doc = try open(url)
        func size(_ p: PDFPage) -> CGSize {
            let b = p.bounds(for: .cropBox)
            return p.rotation % 180 == 0 ? b.size : CGSize(width: b.height, height: b.width)
        }
        let target = (0..<doc.pageCount).map { size(doc.page(at: $0)!).width }.max() ?? 0
        guard target > 0 else { throw OpError("The PDF has no pages.") }
        let out = outputURL(for: url, ext: "pdf", suffix: "same width")
        return try produce(out, verify: verifyPDF) { tmp in
            guard let ctx = CGContext(tmp as CFURL, mediaBox: nil, nil) else { throw OpError("Could not write the PDF.") }
            for i in 0..<doc.pageCount {
                let page = doc.page(at: i)!
                let s = size(page), k = target / s.width
                var box = CGRect(x: 0, y: 0, width: target, height: s.height * k)
                ctx.beginPage(mediaBox: &box)
                ctx.scaleBy(x: k, y: k)
                page.draw(with: .cropBox, to: ctx)
                ctx.endPage()
            }
            ctx.closePDF()
        }
    }

    /// Saves pages in a new order, with rotations. Leaving a page out deletes it.
    public static func organize(_ url: URL, pages: [PageEdit]) throws -> URL {
        guard !pages.isEmpty else { throw OpError("Keep at least one page.") }
        let doc = try open(url)
        let out = outputURL(for: url, ext: "pdf", suffix: "organized")
        return try produce(out, verify: { tmp in
            guard PDFDocument(url: tmp)?.pageCount == pages.count else { throw OpError("The organized PDF could not be verified. No output was saved.") }
        }) { tmp in
            let result = PDFDocument()
            for (i, e) in pages.enumerated() {
                guard let p = doc.page(at: e.index)?.copy() as? PDFPage else { continue }
                p.rotation = (p.rotation + e.rotation + 360) % 360
                result.insert(p, at: i)
            }
            guard result.write(to: tmp) else { throw OpError("Could not write the PDF.") }
        }
    }

    public static func merge(_ urls: [URL]) throws -> URL {
        guard urls.count >= 2 else { throw OpError("Drop at least two PDFs to combine.") }
        let docs = try urls.map(open)
        let expected = docs.reduce(0) { $0 + $1.pageCount }
        let out = outputURL(for: urls[0], ext: "pdf", suffix: "combined")
        return try produce(out, verify: { tmp in
            guard PDFDocument(url: tmp)?.pageCount == expected else { throw OpError("The combined PDF could not be verified. No output was saved.") }
        }) { tmp in
            let result = PDFDocument()
            for d in docs { for i in 0..<d.pageCount { if let p = d.page(at: i)?.copy() as? PDFPage { result.insert(p, at: result.pageCount) } } }
            guard result.write(to: tmp) else { throw OpError("Could not write the PDF.") }
        }
    }

    /// Text layer of the PDF as rich text, one page after another.
    public static func attributedText(_ url: URL) throws -> NSAttributedString {
        let doc = try open(url)
        let s = NSMutableAttributedString()
        for i in 0..<doc.pageCount {
            if let a = doc.page(at: i)?.attributedString { s.append(a); s.append(NSAttributedString(string: "\n\n")) }
        }
        if s.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw OpError("\(url.lastPathComponent) has no text layer. It may be a scanned document.")
        }
        return s
    }
}
