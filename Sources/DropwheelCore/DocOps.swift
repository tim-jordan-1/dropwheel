import AppKit
import PDFKit

/// AppKit's HTML importer must run on the main thread.
func onMain<T>(_ body: () throws -> T) rethrows -> T {
    if Thread.isMainThread { return try body() }
    return try DispatchQueue.main.sync(execute: body)
}

public enum DocOps {
    static let maxBytes: Int64 = 50_000_000

    // MARK: Read

    public static func read(_ url: URL) throws -> (text: NSAttributedString, title: String) {
        guard fileSize(url) <= maxBytes || url.pathExtension.lowercased() == "rtfd" else { throw OpError("\(url.lastPathComponent) is too large to convert.") }
        let title = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "md", "markdown":
            let md = try String(contentsOf: url, encoding: .utf8)
            return (try html(Markdown.toHTML(md, baseURL: url.deletingLastPathComponent())), title)
        case "textclipping":
            return (NSAttributedString(string: try textClipping(url), attributes: bodyAttrs), title)
        case "epub":
            return (try html(EPUB.readHTML(url)), title)
        case "pages":
            return (try readPages(url), title)
        case "pdf":
            return (try PDFOps.attributedText(url), title)
        case "txt":
            let s = try (try? String(contentsOf: url, encoding: .utf8)) ?? String(contentsOf: url, encoding: .isoLatin1)
            return (NSAttributedString(string: s, attributes: bodyAttrs), title)
        default:
            return try onMain {
                var attrs: NSDictionary?
                let s = try NSAttributedString(url: url, options: [:], documentAttributes: &attrs)
                return (s, (attrs?[NSAttributedString.DocumentAttributeKey.title] as? String) ?? title)
            }
        }
    }

    static var bodyAttrs: [NSAttributedString.Key: Any] { [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.black] }

    static func html(_ html: String) throws -> NSAttributedString {
        let styled = "<html><head><meta charset=\"utf-8\"><style>body{font-family:Helvetica Neue,Helvetica;font-size:12pt;color:#000}pre,code{font-family:Menlo;font-size:10.5pt}blockquote{color:#555}</style></head><body>\(html)</body></html>"
        return try onMain {
            try NSAttributedString(data: Data(styled.utf8), options: [.documentType: NSAttributedString.DocumentType.html, .characterEncoding: String.Encoding.utf8.rawValue],
                                   documentAttributes: nil)
        }
    }

    /// Text clippings store their text in a property list in the data fork.
    static func textClipping(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        guard let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let utis = plist["UTI-Data"] as? [String: Any] else { throw OpError("\(url.lastPathComponent) is not a readable text clipping.") }
        if let s = utis["public.utf8-plain-text"] as? String { return s }
        if let d = utis["public.utf8-plain-text"] as? Data, let s = String(data: d, encoding: .utf8) { return s }
        if let s = utis["public.utf16-plain-text"] as? String { return s }
        if let rtf = utis["public.rtf"] as? Data, let a = NSAttributedString(rtf: rtf, documentAttributes: nil) { return a.string }
        throw OpError("\(url.lastPathComponent) holds no text.")
    }

    /// Pages files carry a preview PDF. Pages.app gives better fidelity when it is installed.
    static func readPages(_ url: URL) throws -> NSAttributedString {
        if Office.installed("Pages") {
            let docx = tempURL(ext: "docx"); defer { try? FileManager.default.removeItem(at: docx) }
            try Office.export(app: "Pages", url, to: docx, as: "Microsoft Word")
            return try onMain { try NSAttributedString(url: docx, options: [:], documentAttributes: nil) }
        }
        let pdf = try pagesPreviewPDF(url)
        defer { try? FileManager.default.removeItem(at: pdf) }
        return try PDFOps.attributedText(pdf)
    }

    static func pagesPreviewPDF(_ url: URL) throws -> URL {
        let out = tempURL(ext: "pdf")
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        if isDir.boolValue {
            try FileManager.default.copyItem(at: url.appendingPathComponent("QuickLook/Preview.pdf"), to: out)
        } else {
            try run("/bin/sh", ["-c", "unzip -p \"$1\" QuickLook/Preview.pdf > \"$2\"", "sh", url.path, out.path])
        }
        try verifyPDF(out)
        return out
    }

    // MARK: Write

    public static func convert(_ url: URL, to ext: String) throws -> URL {
        let e = ext.lowercased()
        let src = url.pathExtension.lowercased()
        let out = outputURL(for: url, ext: e)
        // Shortcuts that keep full fidelity.
        if src == "pages", e == "pdf" {
            if Office.installed("Pages") { return try Office.convert(url, to: "pdf") }
            return try produce(out, verify: verifyPDF) { tmp in
                let p = try pagesPreviewPDF(url); try FileManager.default.moveItem(at: p, to: tmp)
            }
        }
        if ["docx", "doc", "rtf", "odt"].contains(src), e == "pages" || (e == "pdf" && Office.installed("Pages") && src != "rtf") {
            return try Office.convert(url, to: e)
        }
        let (text, title) = try read(url)
        return try write(text, title: title, like: url, ext: e)
    }

    public static func write(_ text: NSAttributedString, title: String, like url: URL, ext: String) throws -> URL {
        let out = outputURL(for: url, ext: ext)
        switch ext {
        case "pdf":
            return try produce(out, verify: verifyPDF) { try pdf(text, to: $0) }
        case "epub":
            return try produce(out, verify: EPUB.verify) { try EPUB.write(text, title: title, to: $0) }
        case "pages":
            let docx = tempURL(ext: "docx"); defer { try? FileManager.default.removeItem(at: docx) }
            try data(text, type: .officeOpenXML).write(to: docx)
            return try produce(out, verify: { if fileSize($0) == 0 && !FileManager.default.fileExists(atPath: $0.appendingPathComponent("Index").path) { throw OpError("The Pages document could not be verified.") } }) {
                try Office.save(app: "Pages", docx, to: $0)
            }
        case "rtfd":
            return try produce(out, verify: { _ in }) { tmp in
                guard let w = text.rtfdFileWrapper(from: NSRange(location: 0, length: text.length), documentAttributes: [:]) else { throw OpError("Could not write RTFD.") }
                try w.write(to: tmp, options: .atomic, originalContentsURL: nil)
            }
        case "txt", "md":
            return try produce(out, verify: { _ in }) { try text.string.write(to: $0, atomically: true, encoding: .utf8) }
        default:
            let type: NSAttributedString.DocumentType = ["docx": .officeOpenXML, "rtf": .rtf, "html": .html, "odt": .openDocument, "doc": .docFormat][ext] ?? .rtf
            return try produce(out, verify: { tmp in
                let ok = try? onMain { try NSAttributedString(url: tmp, options: [:], documentAttributes: nil) }
                if ok == nil { throw OpError("The converted document could not be verified. No output was saved.") }
            }) { try data(text, type: type).write(to: $0) }
        }
    }

    static func data(_ text: NSAttributedString, type: NSAttributedString.DocumentType) throws -> Data {
        try onMain { try text.data(from: NSRange(location: 0, length: text.length), documentAttributes: [.documentType: type]) }
    }

    /// Lays text out on US Letter pages with TextKit and draws each page into a PDF.
    public static func pdf(_ text: NSAttributedString, to url: URL, page: CGSize = CGSize(width: 612, height: 792), margin: CGFloat = 54) throws {
        try onMain {
            let storage = NSTextStorage(attributedString: text.length > 0 ? text : NSAttributedString(string: " "))
            let lm = NSLayoutManager()
            storage.addLayoutManager(lm)
            var containers: [NSTextContainer] = []
            repeat {
                let tc = NSTextContainer(size: CGSize(width: page.width - 2 * margin, height: page.height - 2 * margin))
                lm.addTextContainer(tc)
                containers.append(tc)
            } while NSMaxRange(lm.glyphRange(for: containers.last!)) < lm.numberOfGlyphs && containers.count < 10_000
            var box = CGRect(origin: .zero, size: page)
            guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else { throw OpError("Could not write the PDF.") }
            for tc in containers {
                ctx.beginPDFPage(nil)
                ctx.translateBy(x: 0, y: page.height)
                ctx.scaleBy(x: 1, y: -1)
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
                let r = lm.glyphRange(for: tc)
                lm.drawBackground(forGlyphRange: r, at: CGPoint(x: margin, y: margin))
                lm.drawGlyphs(forGlyphRange: r, at: CGPoint(x: margin, y: margin))
                NSGraphicsContext.restoreGraphicsState()
                ctx.endPDFPage()
            }
            ctx.closePDF()
        }
    }
}

// MARK: - Markdown

public enum Markdown {
    static let maxLines = 200_000, maxDepth = 16

    public static func toHTML(_ md: String, baseURL: URL? = nil) throws -> String {
        let lines = md.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        guard lines.count <= maxLines else { throw OpError("Markdown has too many lines.") }
        var html = "", para: [String] = [], listStack: [(tag: String, indent: Int)] = [], inCode = false, code = "", quote: [String] = []
        var i = 0

        func flushPara() { if !para.isEmpty { html += "<p>\(inline(para.joined(separator: " "), baseURL))</p>\n"; para = [] } }
        func closeLists(to indent: Int) { while let l = listStack.last, l.indent >= indent { html += "</li></\(l.tag)>\n"; listStack.removeLast() } }
        func flushQuote() throws { if !quote.isEmpty { html += "<blockquote>\(try toHTML(quote.joined(separator: "\n"), baseURL: baseURL))</blockquote>\n"; quote = [] } }

        while i < lines.count {
            let line = lines[i]; i += 1
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                if inCode { html += "<pre><code>\(escape(code))</code></pre>\n"; code = ""; inCode = false }
                else { flushPara(); try flushQuote(); closeLists(to: 0); inCode = true }
                continue
            }
            if inCode { code += line + "\n"; continue }
            if trimmed.hasPrefix(">") {
                flushPara(); closeLists(to: 0)
                quote.append(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)); continue
            }
            try flushQuote()
            if trimmed.isEmpty { flushPara(); continue }
            if let m = trimmed.firstMatch(of: /^(#{1,6})\s+(.*?)\s*#*$/) {
                flushPara(); closeLists(to: 0)
                html += "<h\(m.1.count)>\(inline(String(m.2), baseURL))</h\(m.1.count)>\n"; continue
            }
            if trimmed.wholeMatch(of: /(\*\s*){3,}|(-\s*){3,}|(_\s*){3,}/) != nil, para.isEmpty {
                closeLists(to: 0); html += "<hr/>\n"; continue
            }
            if trimmed.hasPrefix("|"), i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).wholeMatch(of: /\|?[\s:\-|]+\|?/) != nil {
                flushPara(); closeLists(to: 0)
                func cells(_ s: String) -> [String] { s.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "|")).components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) } }
                html += "<table border=\"1\" cellpadding=\"4\"><tr>" + cells(trimmed).map { "<th>\(inline($0, baseURL))</th>" }.joined() + "</tr>\n"
                i += 1
                while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                    html += "<tr>" + cells(lines[i]).map { "<td>\(inline($0, baseURL))</td>" }.joined() + "</tr>\n"; i += 1
                }
                html += "</table>\n"; continue
            }
            let indent = line.prefix { $0 == " " || $0 == "\t" }.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
            if let m = trimmed.firstMatch(of: /^([-*+]|\d{1,9}[.)])\s+(.*)$/) {
                flushPara()
                let tag = m.1.first!.isNumber ? "ol" : "ul"
                if let last = listStack.last, indent > last.indent {
                    guard listStack.count < maxDepth else { throw OpError("Markdown is nested too deeply.") }
                    html += "<\(tag)>"; listStack.append((tag, indent))
                } else {
                    closeLists(to: indent + 1)
                    if let last = listStack.last, last.indent == indent { html += "</li>" }
                    else { html += "<\(tag)>"; listStack.append((tag, indent)) }
                }
                var item = String(m.2)
                if let t = item.firstMatch(of: /^\[( |x|X)\]\s+(.*)$/) { item = (t.1 == " " ? "☐ " : "☑ ") + t.2 }
                html += "<li>\(inline(item, baseURL))"; continue
            }
            if !listStack.isEmpty, indent > 0, para.isEmpty { html += " " + inline(trimmed, baseURL); continue }
            closeLists(to: 0)
            if para.isEmpty, let next = lines[safe: i]?.trimmingCharacters(in: .whitespaces), next.wholeMatch(of: /=+|-+/) != nil {
                flushPara(); html += next.hasPrefix("=") ? "<h1>\(inline(trimmed, baseURL))</h1>\n" : "<h2>\(inline(trimmed, baseURL))</h2>\n"; i += 1; continue
            }
            para.append(trimmed)
        }
        if inCode { html += "<pre><code>\(escape(code))</code></pre>\n" }
        flushPara(); try flushQuote(); closeLists(to: 0)
        return html
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    static let italic = try! NSRegularExpression(pattern: #"(?<![\w*])\*(?!\s)(.+?)(?<!\s)\*(?!\*)|(?<!\w)_(?!\s)(.+?)(?<!\s)_(?!\w)"#)

    static func inline(_ s: String, _ base: URL?) -> String {
        // Protect code spans first so their content is not formatted.
        var codes: [String] = []
        var t = s.replacing(/`([^`]+)`/) { m in codes.append(escape(String(m.1))); return "\u{1}\(codes.count - 1)\u{1}" }
        t = escape(t)
        t = t.replacing(/!\[([^\]]*)\]\(([^)\s]+)[^)]*\)/) { m in
            let src = String(m.2)
            let resolved = src.contains("://") ? src : (base?.appendingPathComponent(src).absoluteString ?? src)
            return "<img src=\"\(resolved)\" alt=\"\(m.1)\"/>"
        }
        t = t.replacing(/\[([^\]]+)\]\(([^)\s]+)[^)]*\)/) { "<a href=\"\($0.2)\">\($0.1)</a>" }
        t = t.replacing(/&lt;(https?:\/\/[^&\s]+)&gt;/) { "<a href=\"\($0.1)\">\($0.1)</a>" }
        t = t.replacing(/\*\*(.+?)\*\*|__(.+?)__/) { "<strong>\($0.1 ?? $0.2 ?? "")</strong>" }
        // Swift Regex has no lookbehind, so italics use ICU.
        t = italic.stringByReplacingMatches(in: t, range: NSRange(t.startIndex..., in: t), withTemplate: "<em>$1$2</em>")
        t = t.replacing(/~~(.+?)~~/) { "<del>\($0.1)</del>" }
        t = t.replacing(/\u{1}(\d+)\u{1}/) { "<code>\(codes[Int($0.1)!])</code>" }
        return t
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

// MARK: - EPUB

enum EPUB {
    static let maxEntries = 10_000, maxDepth = 64

    /// Unpacks an EPUB safely and returns its spine as one HTML body.
    static func readHTML(_ url: URL) throws -> String {
        let bsdtar = try Tools.require("bsdtar", hint: "")
        let entries = try run(bsdtar, ["-tf", url.path]).split(separator: "\n")
        guard entries.count <= maxEntries else { throw OpError("The EPUB has too many files.") }
        if entries.contains(where: { $0.hasPrefix("/") || $0.split(separator: "/").contains("..") }) { throw OpError("The EPUB contains unsafe paths.") }
        let dir = tempURL(ext: "")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try run(bsdtar, ["-xf", url.path, "-C", dir.path])
        let walker = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.isSymbolicLinkKey])
        while let f = walker?.nextObject() as? URL {
            if (try? f.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { throw OpError("EPUB symbolic links are not supported.") }
        }
        let container = try XMLDocument(contentsOf: dir.appendingPathComponent("META-INF/container.xml"), options: [])
        guard let opfPath = try container.nodes(forXPath: "//*[local-name()='rootfile']/@full-path").first?.stringValue else { throw OpError("The EPUB has no package file.") }
        let opfURL = dir.appendingPathComponent(opfPath).standardizedFileURL
        guard opfURL.path.hasPrefix(dir.standardizedFileURL.path) else { throw OpError("An EPUB path escaped its workspace.") }
        let opf = try XMLDocument(contentsOf: opfURL, options: [])
        var manifest: [String: String] = [:]
        for item in try opf.nodes(forXPath: "//*[local-name()='item']") {
            if let el = item as? XMLElement, let id = el.attribute(forName: "id")?.stringValue, let href = el.attribute(forName: "href")?.stringValue { manifest[id] = href }
        }
        var body = ""
        for ref in try opf.nodes(forXPath: "//*[local-name()='itemref']/@idref") {
            guard let href = manifest[ref.stringValue ?? ""]?.removingPercentEncoding else { continue }
            let file = opfURL.deletingLastPathComponent().appendingPathComponent(href).standardizedFileURL
            guard file.path.hasPrefix(dir.standardizedFileURL.path) else { throw OpError("An EPUB path escaped its workspace.") }
            guard let doc = try? XMLDocument(contentsOf: file, options: [.documentTidyHTML]),
                  let b = try doc.nodes(forXPath: "//*[local-name()='body']").first as? XMLElement else { continue }
            // Images are dropped because the workspace is deleted after reading.
            for img in try b.nodes(forXPath: ".//*[local-name()='img' or local-name()='image']") { img.detach() }
            body += (b.children ?? []).map { $0.xmlString }.joined() + "<hr/>"
        }
        guard !body.isEmpty else { throw OpError("The EPUB has no readable chapters.") }
        return body
    }

    /// Converts attributed text to XHTML, one chapter per top-level heading.
    static func chapters(_ text: NSAttributedString) -> [(title: String, xhtml: String)] {
        var chapters: [(String, String)] = [], current = "", currentTitle = "", listOpen = false
        let ns = text.string as NSString
        // Headings are detected relative to the most common body size, since importers scale fonts differently.
        var sizes: [CGFloat: Int] = [:]
        text.enumerateAttribute(.font, in: NSRange(location: 0, length: text.length)) { v, r, _ in sizes[(v as? NSFont)?.pointSize ?? 12, default: 0] += r.length }
        let bodySize = sizes.max { $0.value < $1.value }?.key ?? 12
        var loc = 0
        func push() { if !current.isEmpty { chapters.append((currentTitle.isEmpty ? "Chapter \(chapters.count + 1)" : currentTitle, current)) }; current = "" }
        while loc < ns.length {
            let pr = ns.paragraphRange(for: NSRange(location: loc, length: 0))
            loc = NSMaxRange(pr)
            var body = ""
            text.enumerateAttributes(in: pr, options: []) { attrs, r, _ in
                var s = Markdown.escape(ns.substring(with: r).replacingOccurrences(of: "\n", with: "").replacingOccurrences(of: "\u{2028}", with: " ").replacingOccurrences(of: "\u{fffc}", with: ""))
                guard !s.isEmpty else { return }
                let traits = (attrs[.font] as? NSFont)?.fontDescriptor.symbolicTraits ?? []
                if traits.contains(.bold) { s = "<strong>\(s)</strong>" }
                if traits.contains(.italic) { s = "<em>\(s)</em>" }
                if let link = attrs[.link] { s = "<a href=\"\(Markdown.escape("\((link as? URL)?.absoluteString ?? "\(link)")"))\">\(s)</a>" }
                body += s
            }
            let plain = ns.substring(with: pr).trimmingCharacters(in: .whitespacesAndNewlines)
            if plain.isEmpty { continue }
            let attrs = text.attributes(at: pr.location, effectiveRange: nil)
            let size = (attrs[.font] as? NSFont)?.pointSize ?? 12
            let isList = !((attrs[.paragraphStyle] as? NSParagraphStyle)?.textLists.isEmpty ?? true)
            if isList != listOpen { current += isList ? "<ul>\n" : "</ul>\n"; listOpen = isList }
            if isList {
                current += "<li>\(body.replacing(/^\s*(\t|•|◦|▪|-|\d+[.)])\s*/, with: ""))</li>\n"
            } else if size >= bodySize * 1.75 {
                if listOpen { current += "</ul>\n"; listOpen = false }
                push(); currentTitle = plain
                current += "<h1>\(body)</h1>\n"
            } else if size >= bodySize * 1.15 {
                current += "<h2>\(body)</h2>\n"
            } else {
                current += "<p>\(body)</p>\n"
            }
        }
        if listOpen { current += "</ul>\n" }
        push()
        return chapters.isEmpty ? [("Chapter 1", "<p></p>")] : chapters
    }

    static func write(_ text: NSAttributedString, title: String, to url: URL) throws {
        let dir = tempURL(ext: "")
        let fm = FileManager.default
        try fm.createDirectory(at: dir.appendingPathComponent("META-INF"), withIntermediateDirectories: true)
        try fm.createDirectory(at: dir.appendingPathComponent("OEBPS"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let t = Markdown.escape(title)
        try "application/epub+zip".write(to: dir.appendingPathComponent("mimetype"), atomically: true, encoding: .ascii)
        try """
        <?xml version="1.0" encoding="UTF-8"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>
        """.write(to: dir.appendingPathComponent("META-INF/container.xml"), atomically: true, encoding: .utf8)
        try "body{font-family:serif;line-height:1.5}h1,h2{font-family:sans-serif}".write(to: dir.appendingPathComponent("OEBPS/style.css"), atomically: true, encoding: .utf8)
        let chs = chapters(text)
        var items = "", spine = "", nav = ""
        for (i, ch) in chs.enumerated() {
            let name = "chapter\(i + 1).xhtml"
            try """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE html>
            <html xmlns="http://www.w3.org/1999/xhtml" xml:lang="en"><head><title>\(Markdown.escape(ch.title))</title><link rel="stylesheet" href="style.css"/></head>
            <body>
            \(ch.xhtml)</body></html>
            """.write(to: dir.appendingPathComponent("OEBPS/\(name)"), atomically: true, encoding: .utf8)
            items += "<item id=\"c\(i + 1)\" href=\"\(name)\" media-type=\"application/xhtml+xml\"/>\n"
            spine += "<itemref idref=\"c\(i + 1)\"/>\n"
            nav += "<li><a href=\"\(name)\">\(Markdown.escape(ch.title))</a></li>\n"
        }
        try """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><head><title>\(t)</title></head>
        <body><nav epub:type="toc" id="toc"><h1>Contents</h1><ol>
        \(nav)</ol></nav></body></html>
        """.write(to: dir.appendingPathComponent("OEBPS/nav.xhtml"), atomically: true, encoding: .utf8)
        let modified = ISO8601DateFormatter().string(from: Date()).prefix(19) + "Z"
        try """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid">
        <metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="uid">urn:uuid:\(UUID().uuidString)</dc:identifier><dc:title>\(t)</dc:title><dc:language>en</dc:language><meta property="dcterms:modified">\(modified)</meta></metadata>
        <manifest><item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/><item id="css" href="style.css" media-type="text/css"/>
        \(items)</manifest>
        <spine>\(spine)</spine>
        </package>
        """.write(to: dir.appendingPathComponent("OEBPS/content.opf"), atomically: true, encoding: .utf8)
        let zip = try Tools.require("zip", hint: "")
        // The mimetype entry must come first and be stored uncompressed.
        try run(zip, ["-X0q", url.path, "mimetype"], cwd: dir)
        try run(zip, ["-Xr9Dq", url.path, "META-INF", "OEBPS"], cwd: dir)
    }

    static func verify(_ url: URL) throws {
        let list = try run(Tools.require("bsdtar", hint: ""), ["-tf", url.path]).split(separator: "\n")
        guard list.first == "mimetype", list.contains("META-INF/container.xml") else { throw OpError("The generated EPUB could not be verified.") }
        for entry in list where entry.hasSuffix(".xhtml") || entry.hasSuffix(".opf") {
            let xml = try run("/usr/bin/unzip", ["-p", url.path, String(entry)])
            guard (try? XMLDocument(xmlString: xml, options: [])) != nil else { throw OpError("The generated EPUB could not be verified.") }
        }
    }
}
