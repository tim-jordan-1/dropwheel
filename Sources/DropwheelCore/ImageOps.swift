import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO
import PDFKit
import UniformTypeIdentifiers
import Vision

public enum CompressionLevel: String, CaseIterable, Codable, Sendable {
    case low, medium, high
    var jpegQuality: Double { [.low: 0.8, .medium: 0.62, .high: 0.42][self]! }
}

public enum RedactionStyle: String, CaseIterable, Codable, Sendable { case blur, solid }

public enum Background: Sendable {
    case color(CGColor)
    case image(URL)
    case transparent
}

public struct Adjustments: Codable, Sendable, Equatable {
    public var exposure = 0.0      // EV, -2...2
    public var contrast = 1.0      // 0.5...1.5
    public var saturation = 1.0    // 0...2
    public var warmth = 0.0        // -1...1
    public var sharpness = 0.0     // 0...1
    public var vignette = 0.0      // 0...1
    public init() {}
}

public struct CollageOptions: Sendable {
    public enum Style: String, CaseIterable, Sendable { case grid, row, column }
    public var style: Style = .grid
    public var columns = 0            // 0 = automatic
    public var spacing = 24.0
    public var cornerRadius = 0.0
    public var fitWholeImages = false // false = fill each cell
    public var cellSize = 1000.0
    public var background: CGColor = .white
    public init() {}
}

public enum ImageOps {
    static let ci = CIContext(options: [.useSoftwareRenderer: false])

    // MARK: Load and save

    /// Loads the first frame with EXIF orientation applied.
    public static func load(_ url: URL) throws -> CGImage {
        if url.pathExtension.lowercased() == "svg" || url.pathExtension.lowercased() == "webp" {
            if let img = NSImage(contentsOf: url) {
                var r = CGRect(origin: .zero, size: img.size)
                if let cg = img.cgImage(forProposedRect: &r, context: nil, hints: nil) { return cg }
            }
            if url.pathExtension.lowercased() == "webp", let dw = Tools.path("dwebp") {
                let tmp = tempURL(ext: "png"); defer { try? FileManager.default.removeItem(at: tmp) }
                try run(dw, [url.path, "-o", tmp.path])
                return try load(tmp)
            }
        }
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else {
            throw OpError("\(url.lastPathComponent) is not a readable image.")
        }
        let w = props[kCGImagePropertyPixelWidth] as? Int ?? 0, h = props[kCGImagePropertyPixelHeight] as? Int ?? 0
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(w, h, 1),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else {
            throw OpError("\(url.lastPathComponent) is not a readable image.")
        }
        return cg
    }

    static func utType(_ ext: String) -> UTType? {
        switch ext.lowercased() {
        case "jpg", "jpeg": return .jpeg
        case "tif": return .tiff
        default: return UTType(filenameExtension: ext.lowercased())
        }
    }

    static func metadata(of url: URL) -> [CFString: Any] {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              var p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return [:] }
        p[kCGImagePropertyOrientation] = 1 // pixels are already upright
        p[kCGImagePropertyPixelWidth] = nil
        p[kCGImagePropertyPixelHeight] = nil
        if var tiff = p[kCGImagePropertyTIFFDictionary] as? [CFString: Any] { tiff[kCGImagePropertyTIFFOrientation] = 1; p[kCGImagePropertyTIFFDictionary] = tiff }
        return p
    }

    static func flattened(_ cg: CGImage, on color: CGColor = .white) -> CGImage {
        let ctx = CGContext(data: nil, width: cg.width, height: cg.height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(color); ctx.fill(CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        return ctx.makeImage()!
    }

    /// Encodes `cg` as `ext`. WebP goes through cwebp because ImageIO cannot write it.
    public static func write(_ cg: CGImage, to url: URL, ext: String, quality: Double = 0.9, metadata: [CFString: Any] = [:]) throws {
        let e = ext.lowercased()
        if e == "webp" {
            let cw = try Tools.require("cwebp", hint: "Install it with: brew install webp")
            let png = tempURL(ext: "png"); defer { try? FileManager.default.removeItem(at: png) }
            try write(cg, to: png, ext: "png")
            try run(cw, ["-quiet", "-q", String(Int(quality * 100)), "-metadata", "none", png.path, "-o", url.path])
            return
        }
        if e == "pdf" {
            let doc = PDFDocument()
            let page = PDFPage(image: NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height)))!
            doc.insert(page, at: 0)
            guard doc.write(to: url) else { throw OpError("Could not write the PDF.") }
            return
        }
        guard let type = utType(e), let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
            throw OpError("Dropwheel cannot write .\(e) images.")
        }
        var image = cg
        let noAlpha = ["jpg", "jpeg", "bmp"].contains(e)
        if noAlpha, cg.alphaInfo != .none, cg.alphaInfo != .noneSkipLast, cg.alphaInfo != .noneSkipFirst { image = flattened(cg) }
        if e == "ico", max(cg.width, cg.height) > 256 { image = scaled(image, maxSide: 256) }
        var props = metadata
        props[kCGImageDestinationLossyCompressionQuality] = quality
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw OpError("Could not write the .\(e) image.") }
    }

    /// Saves an edited image next to the original, in the original's format.
    public static func save(_ cg: CGImage, like input: URL, suffix: String, ext: String? = nil) throws -> URL {
        var e = ext ?? input.pathExtension.lowercased()
        if ["svg", "psd", "icns"].contains(e) { e = "png" }
        let out = outputURL(for: input, ext: e, suffix: suffix)
        return try produce(out, verify: verifyImage) { try write(cg, to: $0, ext: e, quality: 0.92, metadata: metadata(of: input)) }
    }

    // MARK: Convert

    public static func convert(_ url: URL, to ext: String, preserveMetadata: Bool = true) throws -> URL {
        let e = ext.lowercased()
        let out = outputURL(for: url, ext: e)
        if url.pathExtension.lowercased() == "gif", ["mp4", "mov", "webm"].contains(e) {
            return try VideoOps.convert(url, to: e)
        }
        if url.pathExtension.lowercased() == "gif", e == "webp", isAnimated(url), let g2w = Tools.path("gif2webp") {
            return try produce(out, verify: verifyImage) { try run(g2w, ["-quiet", "-q", "85", url.path, "-o", $0.path]) }
        }
        let cg = try load(url)
        let meta = preserveMetadata ? metadata(of: url) : [:]
        return try produce(out, verify: e == "pdf" ? verifyPDF : verifyImage) { try write(cg, to: $0, ext: e, quality: 0.9, metadata: meta) }
    }

    public static func isAnimated(_ url: URL) -> Bool {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return false }
        return CGImageSourceGetCount(src) > 1
    }

    /// Several images become one PDF, one image per page, in drop order.
    public static func imagesToPDF(_ urls: [URL]) throws -> URL {
        guard let first = urls.first else { throw OpError("Drop at least one item.") }
        let out = outputURL(for: first, ext: "pdf", suffix: urls.count > 1 ? "\(urls.count) images" : nil)
        return try produce(out, verify: verifyPDF) { tmp in
            let doc = PDFDocument()
            for u in urls {
                let cg = try load(u)
                guard let page = PDFPage(image: NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))) else { continue }
                doc.insert(page, at: doc.pageCount)
            }
            guard doc.write(to: tmp) else { throw OpError("Could not write the PDF.") }
        }
    }

    // MARK: Compress

    public static func compress(_ url: URL, level: CompressionLevel = .medium, targetBytes: Int64? = nil) throws -> URL {
        var e = url.pathExtension.lowercased()
        if ["bmp", "tiff", "tif", "psd", "svg"].contains(e) { e = "jpg" }
        let out = outputURL(for: url, ext: e, suffix: "compressed")
        let meta = metadata(of: url)
        let cg = try load(url)

        if e == "png" || e == "gif" {
            return try produce(out, verify: { try verifyImage($0); try requireSmaller($0, than: url) }) { tmp in
                var img = cg
                while true {
                    if e == "png" {
                        try palettize(img, to: tmp, colors: level == .low ? 256 : level == .medium ? 192 : 96)
                    } else {
                        try write(img, to: tmp, ext: e)
                    }
                    guard let target = targetBytes, fileSize(tmp) > target, img.width > 64 else { break }
                    img = scaled(img, factor: max(0.5, (Double(target) / Double(fileSize(tmp))).squareRoot()))
                }
            }
        }

        return try produce(out, verify: { try verifyImage($0); try requireSmaller($0, than: url) }) { tmp in
            guard let target = targetBytes else {
                try write(cg, to: tmp, ext: e, quality: level.jpegQuality, metadata: meta)
                return
            }
            var img = cg
            for _ in 0..<6 {
                // Binary search the quality that lands just under the target.
                var lo = 0.05, hi = 0.95, best: Double?
                for _ in 0..<7 {
                    let q = (lo + hi) / 2
                    try write(img, to: tmp, ext: e, quality: q, metadata: meta)
                    if fileSize(tmp) <= target { best = q; lo = q } else { hi = q }
                }
                if let best { try write(img, to: tmp, ext: e, quality: best, metadata: meta); return }
                img = scaled(img, factor: 0.75)
            }
            throw OpError("Could not reach the target file size.")
        }
    }

    /// Reduces a PNG to a palette with ffmpeg, the same idea as pngquant.
    static func palettize(_ cg: CGImage, to url: URL, colors: Int) throws {
        let src = tempURL(ext: "png"); defer { try? FileManager.default.removeItem(at: src) }
        try write(cg, to: src, ext: "png")
        try run(Tools.ffmpeg, ["-v", "error", "-y", "-i", src.path, "-vf",
                               "split[a][b];[a]palettegen=max_colors=\(colors):reserve_transparent=1:stats_mode=single[p];[b][p]paletteuse=dither=sierra2_4a",
                               "-frames:v", "1", url.path])
    }

    // MARK: Geometry

    public static func scaled(_ cg: CGImage, factor: Double) -> CGImage {
        resized(cg, width: max(1, Int(Double(cg.width) * factor)), height: max(1, Int(Double(cg.height) * factor)))
    }

    public static func scaled(_ cg: CGImage, maxSide: Int) -> CGImage {
        let f = Double(maxSide) / Double(max(cg.width, cg.height))
        return f >= 1 ? cg : scaled(cg, factor: f)
    }

    public static func resized(_ cg: CGImage, width: Int, height: Int) -> CGImage {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()!
    }

    public static func resize(_ url: URL, width: Int, height: Int) throws -> URL {
        guard width > 0, height > 0, width <= 20000, height <= 20000 else { throw OpError("Choose a size between 1 and 20000 pixels.") }
        return try save(resized(try load(url), width: width, height: height), like: url, suffix: "\(width)×\(height)")
    }

    /// `rect` is in pixels with a top-left origin, as editors show it.
    public static func cropped(_ cg: CGImage, _ rect: CGRect) throws -> CGImage {
        let r = rect.integral.intersection(CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        guard r.width >= 2, r.height >= 2, let c = cg.cropping(to: r) else { throw OpError("Make the crop at least 2 pixels wide and tall.") }
        return c
    }

    public static func crop(_ url: URL, rect: CGRect) throws -> URL {
        try save(try cropped(try load(url), rect), like: url, suffix: "cropped")
    }

    // MARK: Redact

    public static func redacted(_ cg: CGImage, rects: [CGRect], style: RedactionStyle) -> CGImage {
        let base = CIImage(cgImage: cg)
        var result = base
        let h = CGFloat(cg.height)
        for r in rects {
            let ciRect = CGRect(x: r.minX, y: h - r.maxY, width: r.width, height: r.height).integral
            let patch: CIImage
            switch style {
            case .solid:
                patch = CIImage(color: .black).cropped(to: ciRect)
            case .blur:
                // Pixellate first so the blur cannot be reversed, then blur the blocks.
                let scale = max(12, min(ciRect.width, ciRect.height) / 6)
                let px = base.clampedToExtent().applyingFilter("CIPixellate", parameters: [kCIInputScaleKey: scale, kCIInputCenterKey: CIVector(x: ciRect.minX, y: ciRect.minY)])
                patch = px.applyingGaussianBlur(sigma: scale / 2).cropped(to: ciRect)
            }
            result = patch.composited(over: result)
        }
        return ci.createCGImage(result.cropped(to: base.extent), from: base.extent)!
    }

    public static func redact(_ url: URL, rects: [CGRect], style: RedactionStyle) throws -> URL {
        guard !rects.isEmpty else { throw OpError("Add at least one redaction rectangle.") }
        return try save(redacted(try load(url), rects: rects, style: style), like: url, suffix: "redacted")
    }

    // MARK: Adjust

    public static func adjusted(_ cg: CGImage, _ a: Adjustments) -> CGImage {
        var img = CIImage(cgImage: cg)
        let extent = img.extent
        img = img.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: a.exposure])
        img = img.applyingFilter("CIColorControls", parameters: [kCIInputContrastKey: a.contrast, kCIInputSaturationKey: a.saturation])
        if a.warmth != 0 {
            img = img.applyingFilter("CITemperatureAndTint", parameters: ["inputNeutral": CIVector(x: 6500, y: 0), "inputTargetNeutral": CIVector(x: 6500 - a.warmth * 2500, y: 0)])
        }
        if a.sharpness > 0 { img = img.applyingFilter("CISharpenLuminance", parameters: [kCIInputSharpnessKey: a.sharpness]) }
        if a.vignette > 0 { img = img.applyingFilter("CIVignette", parameters: [kCIInputIntensityKey: a.vignette * 2, kCIInputRadiusKey: 2]) }
        return ci.createCGImage(img.cropped(to: extent), from: extent)!
    }

    public static func adjust(_ url: URL, _ a: Adjustments) throws -> URL {
        try save(adjusted(try load(url), a), like: url, suffix: "adjusted")
    }

    // MARK: Background

    /// Lifts the subject with Vision. Returns nil when Vision finds no subject.
    public static func subjectMask(_ cg: CGImage) throws -> CIImage? {
        let req = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: cg)
        try handler.perform([req])
        guard let result = req.results?.first else { return nil }
        let buf = try result.generateScaledMaskForImage(forInstances: result.allInstances, from: handler)
        return CIImage(cvPixelBuffer: buf)
    }

    static func hasAlpha(_ cg: CGImage) -> Bool {
        ![.none, .noneSkipFirst, .noneSkipLast].contains(cg.alphaInfo)
    }

    public static func withBackground(_ cg: CGImage, _ bg: Background) throws -> CGImage {
        let fg = CIImage(cgImage: cg)
        let extent = fg.extent
        var subject = fg
        if !hasAlpha(cg) {
            guard let mask = try subjectMask(cg) else { throw OpError("No subject was found in this image.") }
            subject = fg.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: CIImage.empty(), kCIInputMaskImageKey: mask])
        }
        let back: CIImage
        switch bg {
        case .transparent: back = .empty()
        case .color(let c): back = CIImage(color: CIColor(cgColor: c)).cropped(to: extent)
        case .image(let u):
            let b = CIImage(cgImage: try load(u))
            // Aspect-fill the background image.
            let s = max(extent.width / b.extent.width, extent.height / b.extent.height)
            let t = b.transformed(by: .init(scaleX: s, y: s))
            back = t.transformed(by: .init(translationX: (extent.width - t.extent.width) / 2, y: (extent.height - t.extent.height) / 2)).cropped(to: extent)
        }
        return ci.createCGImage(subject.composited(over: back), from: extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))!
    }

    public static func changeBackground(_ url: URL, _ bg: Background) throws -> URL {
        let out = try withBackground(try load(url), bg)
        let keepsAlpha = { if case .transparent = bg { return true }; return false }()
        return try save(out, like: url, suffix: "background", ext: keepsAlpha ? "png" : nil)
    }

    // MARK: Collage

    public static func collageImage(_ images: [CGImage], _ o: CollageOptions) -> CGImage {
        let n = images.count
        let cols: Int
        switch o.style {
        case .row: cols = n
        case .column: cols = 1
        case .grid: cols = o.columns > 0 ? o.columns : Int(Double(n).squareRoot().rounded(.up))
        }
        let rows = Int((Double(n) / Double(cols)).rounded(.up))
        let cell = o.cellSize, sp = o.spacing
        let W = Int(Double(cols) * cell + Double(cols + 1) * sp), H = Int(Double(rows) * cell + Double(rows + 1) * sp)
        let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.interpolationQuality = .high
        ctx.setFillColor(o.background); ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
        for (i, img) in images.enumerated() {
            let c = i % cols, r = i / cols
            let frame = CGRect(x: sp + Double(c) * (cell + sp), y: Double(H) - sp - Double(r + 1) * cell - Double(r) * sp, width: cell, height: cell)
            let iw = Double(img.width), ih = Double(img.height)
            let s = o.fitWholeImages ? min(cell / iw, cell / ih) : max(cell / iw, cell / ih)
            let dw = iw * s, dh = ih * s
            let dest = CGRect(x: frame.midX - dw / 2, y: frame.midY - dh / 2, width: dw, height: dh)
            ctx.saveGState()
            let clip = o.fitWholeImages ? dest : frame
            ctx.addPath(CGPath(roundedRect: clip, cornerWidth: o.cornerRadius, cornerHeight: o.cornerRadius, transform: nil))
            ctx.clip()
            ctx.draw(img, in: dest)
            ctx.restoreGState()
        }
        return ctx.makeImage()!
    }

    public static func collage(_ urls: [URL], _ o: CollageOptions = .init()) throws -> URL {
        guard urls.count >= 2 else { throw OpError("Drop at least two images to make a collage.") }
        let imgs = try urls.map { scaled(try load($0), maxSide: Int(o.cellSize * 1.5)) }
        let out = outputURL(for: urls[0], ext: o.background.alpha < 1 ? "png" : "jpg", suffix: "collage")
        return try produce(out, verify: verifyImage) { try write(collageImage(imgs, o), to: $0, ext: out.pathExtension, quality: 0.9) }
    }

    // MARK: QR codes

    public static func readCodes(_ cg: CGImage) throws -> [String] {
        let req = VNDetectBarcodesRequest()
        try VNImageRequestHandler(cgImage: cg).perform([req])
        return (req.results ?? []).compactMap(\.payloadStringValue)
    }

    /// Reads QR and other barcodes from images and every page of PDFs.
    public static func readQRCodes(_ url: URL) throws -> [String] {
        if url.pathExtension.lowercased() == "pdf", let doc = PDFDocument(url: url) {
            var all: [String] = []
            for i in 0..<doc.pageCount {
                if let cg = PDFOps.render(doc.page(at: i)!, scale: 2) { all += try readCodes(cg) }
            }
            return all
        }
        return try readCodes(try load(url))
    }

    // MARK: Integrity

    /// Hash of decoded RGBA pixels. Equal hashes mean a metadata edit left the image alone.
    public static func pixelHash(_ url: URL) -> Int? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        var h = Hasher()
        for i in 0..<CGImageSourceGetCount(src) {
            guard let cg = CGImageSourceCreateImageAtIndex(src, i, nil) else { return nil }
            let ctx = CGContext(data: nil, width: cg.width, height: cg.height, bitsPerComponent: 8, bytesPerRow: cg.width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
            h.combine(bytes: UnsafeRawBufferPointer(start: ctx.data, count: cg.width * cg.height * 4))
        }
        return h.finalize()
    }
}
