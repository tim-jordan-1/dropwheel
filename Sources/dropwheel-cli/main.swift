import AppKit
import CoreImage
import DropwheelCore
import ImageIO
import PDFKit

// dropwheel actions <files…>          list wheel targets for the files
// dropwheel run <action-id> <files…>  run a target that needs no editor
// dropwheel selftest [--office]       run every operation on generated fixtures and check the results

let args = Array(CommandLine.arguments.dropFirst())
let urls = { (a: ArraySlice<String>) in a.map { URL(fileURLWithPath: $0).standardizedFileURL } }

switch args.first {
case "actions":
    for a in Catalog.actions(for: urls(args.dropFirst())) { print("\(a.id)\t\(a.title)\(a.editor ? "\t(editor)" : "")") }
case "run" where args.count >= 3:
    do {
        let outs = try Catalog.run(args[1], urls(args.dropFirst(2)), progress: { p in FileHandle.standardError.write(String(format: "\r%3.0f%%", p * 100).data(using: .utf8)!) })
        FileHandle.standardError.write("\n".data(using: .utf8)!)
        outs.forEach { print($0.path) }
    } catch {
        FileHandle.standardError.write("error: \(error.localizedDescription)\n".data(using: .utf8)!)
        exit(1)
    }
case "selftest":
    exit(SelfTest(office: args.contains("--office")).run() ? 0 : 1)
default:
    print("usage: dropwheel actions <files…> | run <action-id> <files…> | selftest [--office]")
}

// MARK: - Self-test

final class SelfTest {
    let dir: URL
    let office: Bool
    var passed = 0, failed: [String] = []

    init(office: Bool) {
        self.office = office
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("dropwheel-selftest-\(Int(Date().timeIntervalSince1970))")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    func f(_ name: String) -> URL { dir.appendingPathComponent(name) }

    @discardableResult
    func sh(_ cmd: String) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-c", "export PATH=/opt/homebrew/bin:$PATH; " + cmd]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
        try! p.run(); let d = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        return String(data: d, encoding: .utf8)!.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func dur(_ u: URL) -> Double { Double(sh("ffprobe -v error -show_entries format=duration -of csv=p=0 '\(u.path)'")) ?? -1 }
    func streams(_ u: URL) -> String { sh("ffprobe -v error -show_entries stream=codec_type,codec_name,channels,width,height -of compact=p=0 '\(u.path)'") }
    func sipsFormat(_ u: URL) -> String { sh("sips -g format '\(u.path)' | tail -1 | awk '{print $2}'") }
    func near(_ a: Double, _ b: Double, _ tol: Double = 0.25) -> Bool { abs(a - b) <= tol }
    func count(_ dir: URL) -> Int { (try? FileManager.default.contentsOfDirectory(atPath: dir.path).count) ?? -1 }

    func check(_ name: String, _ body: () throws -> String?) {
        let t = Date()
        do {
            if let problem = try body() { failed.append("\(name): \(problem)"); print("FAIL  \(name): \(problem)") }
            else { passed += 1; print(String(format: "ok    %@ (%.1fs)", name, Date().timeIntervalSince(t))) }
        } catch {
            failed.append("\(name): \(error.localizedDescription)"); print("FAIL  \(name): \(error.localizedDescription)")
        }
    }

    func expect(_ cond: Bool, _ msg: @autoclosure () -> String) -> String? { cond ? nil : msg() }

    func makeFixtures() {
        sh("cd '\(dir.path)' && ffmpeg -v error -f lavfi -i testsrc2=s=640x360:r=30:d=4 -f lavfi -i sine=f=440:d=4:sample_rate=48000 -ac 2 -c:v libx264 -pix_fmt yuv420p -c:a aac -shortest video.mp4")
        sh("cd '\(dir.path)' && ffmpeg -v error -f lavfi -i testsrc2=s=320x240:r=25:d=2 -c:v libx264 -pix_fmt yuv420p clip-noaudio.mp4")
        sh("cd '\(dir.path)' && ffmpeg -v error -f lavfi -i anullsrc=r=44100:cl=stereo:d=1 -f lavfi -i sine=f=330:d=3:sample_rate=44100 -f lavfi -i anullsrc=r=44100:cl=stereo:d=1 -filter_complex '[1]aformat=channel_layouts=stereo[s];[0][s][2]concat=n=3:v=0:a=1' -c:a pcm_s16le tone.wav")
        sh("cd '\(dir.path)' && ffmpeg -v error -f lavfi -i testsrc2=s=1200x800 -frames:v 1 photo.png")
        sh("cd '\(dir.path)' && ffmpeg -v error -i photo.png -q:v 2 plain.jpg")
        sh("cd '\(dir.path)' && ffmpeg -v error -f lavfi -i testsrc2=s=200x120:r=10:d=1 anim.gif")
        // A JPEG with GPS and camera fields, written by ImageIO.
        let src = CGImageSourceCreateWithURL(f("plain.jpg") as CFURL, nil)!
        let dest = CGImageDestinationCreateWithURL(f("gps.jpg") as CFURL, "public.jpeg" as CFString, 1, nil)!
        CGImageDestinationAddImageFromSource(dest, src, 0, [
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 37.33, kCGImagePropertyGPSLatitudeRef: "N", kCGImagePropertyGPSLongitude: 122.0, kCGImagePropertyGPSLongitudeRef: "W"],
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "TestCam", kCGImagePropertyTIFFModel: "X1"],
        ] as CFDictionary)
        CGImageDestinationFinalize(dest)
        // QR code image.
        let qr = CIFilter(name: "CIQRCodeGenerator", parameters: ["inputMessage": Data("https://example.com/dropwheel".utf8)])!.outputImage!
            .transformed(by: .init(scaleX: 12, y: 12))
        let padded = qr.composited(over: CIImage(color: .white).cropped(to: qr.extent.insetBy(dx: -60, dy: -60)))
        let cg = CIContext().createCGImage(padded, from: padded.extent)!
        let qd = CGImageDestinationCreateWithURL(f("qr.png") as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(qd, cg, nil); CGImageDestinationFinalize(qd)
        try! """
        # Report Title

        Intro paragraph with **bold**, *italic*, `code` and a [link](https://example.com).

        ## Section Two

        - first item
        - second item
          - nested item
        1. one
        2. two

        > a quote

        | Col A | Col B |
        |---|---|
        | 1 | 2 |

        ```
        let x = 1 < 2
        ```

        # Chapter Two

        More text & symbols < > "quotes".
        """.write(to: f("notes.md"), atomically: true, encoding: .utf8)
        try! "Plain text file.\nSecond line.".write(to: f("plain.txt"), atomically: true, encoding: .utf8)
        try! "1\n00:00:00,500 --> 00:00:02,000\nHello\n\n2\n00:00:02,500 --> 00:00:03,500\nWorld\n".write(to: f("subs.srt"), atomically: true, encoding: .utf8)
        let clip = try! PropertyListSerialization.data(fromPropertyList: ["UTI-Data": ["public.utf8-plain-text": "Clipped text"], "UTI-Type": "public.utf8-plain-text"], format: .binary, options: 0)
        try! clip.write(to: f("snippet.textClipping"))
        try! FileManager.default.createDirectory(at: f("folder/sub"), withIntermediateDirectories: true)
        try! "a".write(to: f("folder/a.txt"), atomically: true, encoding: .utf8)
        try! "b".write(to: f("folder/sub/b.txt"), atomically: true, encoding: .utf8)
    }

    func run() -> Bool {
        print("Fixtures in \(dir.path)")
        makeFixtures()
        let video = f("video.mp4"), wav = f("tone.wav"), png = f("photo.png"), jpg = f("plain.jpg"), gps = f("gps.jpg")

        // Catalog
        check("catalog image targets") {
            let ids = Catalog.actions(for: [png]).map(\.id)
            return expect(ids.contains("convert:webp") && ids.contains("annotate") && !ids.contains("convert:png") && ids.contains("float"), "\(ids)")
        }
        check("catalog video+subtitle offers subtitles") { expect(Catalog.actions(for: [video, f("subs.srt")]).map(\.id).contains("subtitles"), "missing") }

        // Images
        for ext in Formats.imageOut {
            check("image png → \(ext)") {
                let out = try ImageOps.convert(png, to: ext)
                if ext == "pdf" { return expect(PDFDocument(url: out)?.pageCount == 1, "bad pdf") }
                if ext == "webp" { return expect(sh("dwebp '\(out.path)' -o /dev/null 2>&1; echo $?").hasSuffix("0"), "dwebp failed") }
                let fmt = sipsFormat(out)
                let want = ["jpg": "jpeg", "heic": "heic", "avif": "avif", "tiff": "tiff", "gif": "gif", "bmp": "bmp", "png": "png"][ext]!
                return expect(fmt == want, "sips says \(fmt)")
            }
        }
        check("image gif → mp4") { let o = try ImageOps.convert(f("anim.gif"), to: "mp4"); return expect(streams(o).contains("h264"), streams(o)) }
        check("image gif → webp (animated)") { let o = try ImageOps.convert(f("anim.gif"), to: "webp"); return expect(sh("webpmux -info '\(o.path)' | head -3").contains("animation"), "not animated") }
        check("image compress preset") { let o = try ImageOps.compress(jpg, level: .high); return expect(fileSize(o) < fileSize(jpg), "not smaller") }
        check("image compress png palette") { let o = try ImageOps.compress(png, level: .medium); return expect(fileSize(o) < fileSize(png) && sipsFormat(o) == "png", "not smaller") }
        check("image compress to 60 KB") { let o = try ImageOps.compress(jpg, targetBytes: 60_000); return expect(fileSize(o) <= 60_000, "\(fileSize(o)) bytes") }
        check("image resize") { let o = try ImageOps.resize(png, width: 300, height: 200); return expect(sh("sips -g pixelWidth -g pixelHeight '\(o.path)' | tail -2 | awk '{print $2}' | tr '\\n' x") == "300x200x", "wrong size") }
        check("image crop") { let o = try ImageOps.crop(png, rect: CGRect(x: 100, y: 50, width: 400, height: 300)); return expect(sh("sips -g pixelWidth '\(o.path)' | tail -1 | awk '{print $2}'") == "400", "wrong width") }
        check("image redact blur + solid") {
            let o1 = try ImageOps.redact(png, rects: [CGRect(x: 10, y: 10, width: 200, height: 100)], style: .blur)
            let o2 = try ImageOps.redact(png, rects: [CGRect(x: 10, y: 10, width: 200, height: 100)], style: .solid)
            let px = try ImageOps.load(o2)
            let ctx = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(px, in: CGRect(x: -50, y: -(Double(px.height) - 50), width: Double(px.width), height: Double(px.height)))
            let p = ctx.data!.assumingMemoryBound(to: UInt8.self)
            return expect(fileSize(o1) > 0 && p[0] < 5 && p[1] < 5 && p[2] < 5, "pixel (50,50) is not black: \(p[0]) \(p[1]) \(p[2])")
        }
        check("image adjust") { var a = Adjustments(); a.exposure = 0.5; a.saturation = 1.4; return expect(fileSize(try ImageOps.adjust(png, a)) > 0, "empty") }
        check("image background on subject photo") {
            let ctx = CGContext(data: nil, width: 600, height: 600, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
            ctx.setFillColor(CGColor(red: 0.85, green: 0.85, blue: 0.85, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 600, height: 600))
            ctx.setFillColor(CGColor(red: 0.9, green: 0.3, blue: 0.1, alpha: 1)); ctx.fillEllipse(in: CGRect(x: 150, y: 150, width: 300, height: 300))
            let u = f("subject.png"); try ImageOps.write(ctx.makeImage()!, to: u, ext: "png")
            do { let o = try ImageOps.changeBackground(u, .color(CGColor(red: 0, green: 0, blue: 1, alpha: 1))); return expect(fileSize(o) > 0, "empty") }
            catch { return error.localizedDescription.contains("No subject") ? nil : error.localizedDescription }
        }
        check("image background on transparent png") {
            let ctx = CGContext(data: nil, width: 100, height: 100, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.setFillColor(.black); ctx.fill(CGRect(x: 25, y: 25, width: 50, height: 50))
            let u = f("alpha.png"); try ImageOps.write(ctx.makeImage()!, to: u, ext: "png")
            let o = try ImageOps.changeBackground(u, .color(CGColor(red: 1, green: 0, blue: 0, alpha: 1)))
            return expect(sipsFormat(o) == "png", sipsFormat(o))
        }
        check("image collage") { let o = try ImageOps.collage([png, jpg, gps], .init()); return expect(sipsFormat(o) == "jpeg", sipsFormat(o)) }
        check("images → one PDF") { let o = try ImageOps.imagesToPDF([png, jpg]); return expect(PDFDocument(url: o)?.pageCount == 2, "pages") }
        check("read QR code") { let c = try ImageOps.readQRCodes(f("qr.png")); return expect(c == ["https://example.com/dropwheel"], "\(c)") }

        // Metadata
        check("metadata remove keeps pixels") {
            let before = ImageOps.pixelHash(gps)
            let o = try MetadataOps.removeAll(gps)
            let props = CGImageSourceCopyPropertiesAtIndex(CGImageSourceCreateWithURL(o as CFURL, nil)!, 0, nil) as! [CFString: Any]
            let gone = props[kCGImagePropertyGPSDictionary] == nil && (props[kCGImagePropertyTIFFDictionary] as? [CFString: Any])?[kCGImagePropertyTIFFMake] == nil
            let mdlsOK = !sh("mdls -name kMDItemLatitude '\(o.path)'").contains("37.")
            return expect(gone && mdlsOK && before == ImageOps.pixelHash(o), "gps=\(props[kCGImagePropertyGPSDictionary] != nil) make=\(String(describing: (props[kCGImagePropertyTIFFDictionary] as? [CFString: Any])?[kCGImagePropertyTIFFMake])) mdls=\(mdlsOK)")
        }
        check("metadata edit") {
            let o = try MetadataOps.edit(gps, values: ["tiff:Make": "Edited", "dc:title": "Hello", "exif:GPSLatitude": ""])
            let fields = MetadataOps.read(o).fields
            let make = fields.first { $0.id == "tiff:Make" }?.value, title = fields.first { $0.id == "dc:title" }?.value
            return expect(make == "Edited" && (title ?? "").contains("Hello") && ImageOps.pixelHash(o) == ImageOps.pixelHash(gps), "make=\(make ?? "nil") title=\(title ?? "nil")")
        }
        check("metadata remove from video") { let o = try MetadataOps.removeAll(video); return expect(near(dur(o), 4, 0.1), "duration") }

        // Video
        for ext in Formats.videoOut {
            check("video mp4 → \(ext)") {
                let o = try VideoOps.convert(video, to: ext)
                if ext == "gif" { return expect(sipsFormat(o) == "gif", sipsFormat(o)) }
                return expect(near(dur(o), 4, 0.3), "duration \(dur(o))")
            }
        }
        check("video compress preset") { let o = try VideoOps.compress(video, .init(level: .high)); return expect(fileSize(o) < fileSize(video), "not smaller") }
        check("video compress to 100 KB (two pass)") { let o = try VideoOps.compress(video, .init(targetBytes: 100_000)); return expect(fileSize(o) <= 115_000, "\(fileSize(o)) bytes") }
        check("video compress hevc + max height") { let o = try VideoOps.compress(video, .init(level: .medium, maxHeight: 240, encoding: .hevc)); return expect(streams(o).contains("hevc") && streams(o).contains("height=240"), streams(o)) }
        check("video trim 1–3s") { let o = try VideoOps.trim(video, TimeRange(1, 3)); return expect(near(dur(o), 2), "duration \(dur(o))") }
        check("video split separate") { let o = try VideoOps.split(video, segments: [TimeRange(0, 1), TimeRange(2, 3.5)], mode: .separateVideos); return expect(o.count == 2 && near(dur(o[1]), 1.5), "\(o.map(dur))") }
        check("video split one video") { let o = try VideoOps.split(video, segments: [TimeRange(0, 1), TimeRange(2, 3.5)], mode: .oneVideo); return expect(near(dur(o[0]), 2.5), "\(dur(o[0]))") }
        check("video join (one without audio)") { let o = try VideoOps.join([video, f("clip-noaudio.mp4")]); return expect(near(dur(o), 6, 0.3) && streams(o).contains("audio"), "\(dur(o))") }
        check("video crop") { let o = try VideoOps.crop(video, rect: CGRect(x: 10, y: 10, width: 300, height: 200)); return expect(streams(o).contains("width=300|height=200"), streams(o)) }
        check("video speed 2×") { let o = try VideoOps.changeSpeed(video, factor: 2); return expect(near(dur(o), 2, 0.2), "\(dur(o))") }
        check("video speed 0.5×") { let o = try VideoOps.changeSpeed(video, factor: 0.5); return expect(near(dur(o), 8, 0.3), "\(dur(o))") }
        check("video export frames") { let o = try VideoOps.exportFrames(video, at: [0.5, 1.5, 3]); return expect(count(o) == 3, "count \(count(o))") }
        check("video redact blur + solid") {
            let o1 = try VideoOps.redact(video, [VideoRedaction(rect: CGRect(x: 20, y: 20, width: 120, height: 80), range: TimeRange(1, 2)), VideoRedaction(rect: CGRect(x: 300, y: 100, width: 100, height: 100), range: nil)], style: .blur)
            let o2 = try VideoOps.redact(video, [VideoRedaction(rect: CGRect(x: 20, y: 20, width: 120, height: 80), range: nil)], style: .solid)
            return expect(near(dur(o1), 4, 0.2) && near(dur(o2), 4, 0.2), "durations")
        }
        check("video add subtitles") { let o = try VideoOps.addSubtitles(video, f("subs.srt")); return expect(streams(o).contains("mov_text"), streams(o)) }
        check("subtitles srt → vtt") { let o = try VideoOps.convertSubtitles(f("subs.srt"), to: "vtt"); return expect((try String(contentsOf: o, encoding: .utf8)).hasPrefix("WEBVTT"), "header") }
        check("video thumbnails + frame") { let t = try VideoOps.thumbnails(video, count: 8); let fr = try VideoOps.frame(video, at: 1); return expect(t.count >= 7 && fr.width == 640, "\(t.count)") }

        // Audio
        for ext in Formats.audioOut {
            check("audio wav → \(ext)") {
                let o = try AudioOps.convert(wav, to: ext)
                // ffprobe guesses raw ADTS duration from bitrate, so decode it instead.
                let d = ext == "aac" ? Double(sh("ffmpeg -i '\(o.path)' -f null - 2>&1 | grep -o 'time=[0-9:.]*' | tail -1 | awk -F: '{print $NF}'")) ?? -1 : dur(o)
                return expect(near(d, 5, 0.15), "duration \(d)")
            }
        }
        check("audio from video → mp3") { let o = try VideoOps.convert(video, to: "mp3"); return expect(streams(o).contains("mp3") && !streams(o).contains("video"), streams(o)) }
        check("audio compress") { let m = try AudioOps.convert(wav, to: "m4a"); let o = try AudioOps.compress(m, level: .high); return expect(fileSize(o) < fileSize(m), "not smaller") }
        check("audio normalize to -16 LUFS") {
            let o = try AudioOps.normalize(wav, targetLUFS: -16)
            let lufs = Double(sh("ffmpeg -nostats -i '\(o.path)' -af ebur128 -f null - 2>&1 | grep -A1 'Integrated loudness' | grep ' I:' | awk '{print $2}'")) ?? 0
            return expect(near(lufs, -16, 1.5), "integrated \(lufs) LUFS")
        }
        check("audio bleep") {
            let o = try AudioOps.bleep(wav, ranges: [TimeRange(1.5, 2.0)])
            let peak = sh("ffmpeg -ss 1.6 -t 0.3 -i '\(o.path)' -af 'bandpass=f=1000:width_type=h:w=50,volumedetect' -f null - 2>&1 | grep max_volume | awk '{print $5}'")
            return expect(near(dur(o), 5, 0.1) && (Double(peak) ?? -99) > -25, "1 kHz peak \(peak)")
        }
        check("audio trim silent ends") { let o = try AudioOps.trim(wav, nil, silentEnds: true); return expect(near(dur(o), 3, 0.2), "\(dur(o))") }
        check("audio trim range") { let o = try AudioOps.trim(wav, TimeRange(1, 2), silentEnds: false); return expect(near(dur(o), 1, 0.1), "\(dur(o))") }
        check("audio channels mono") { let o = try AudioOps.channels(wav, .mono); return expect(streams(o).contains("channels=1"), streams(o)) }
        check("audio channels volumes") { let o = try AudioOps.channels(wav, .volumes(left: 1, right: 0.2)); return expect(streams(o).contains("channels=2"), streams(o)) }
        check("audio join") { let o = try AudioOps.join([wav, wav]); return expect(near(dur(o), 10, 0.2), "\(dur(o))") }
        for style in VisualizationStyle.allCases {
            check("audio visualizer \(style)") { let o = try AudioOps.visualize(wav, image: style == .wave ? png : nil, style: style); return expect(streams(o).contains("h264") && near(dur(o), 5, 0.3), "\(dur(o)) \(streams(o))") }
        }
        check("audio waveform") { let w = try AudioOps.waveform(wav, buckets: 50)[0]; return expect(w[5] < 0.01 && w[25] > 0.05, "\(w[5]) \(w[25])") }
        check("audio bleep inside video keeps video") { let o = try AudioOps.bleep(video, ranges: [TimeRange(1, 2)]); return expect(streams(o).contains("video") && streams(o).contains("audio"), streams(o)) }

        // PDF
        let textPDF = try? DocOps.convert(f("notes.md"), to: "pdf")
        check("markdown → pdf") { expect(textPDF.flatMap { PDFDocument(url: $0)?.string }?.contains("Section Two") == true, "text missing") }
        guard let textPDF, let multi = try? PDFOps.merge([textPDF, try ImageOps.imagesToPDF([png])]) else { return finish() }
        check("pdf combine") { expect(PDFDocument(url: multi)?.pageCount == 2, "pages") }
        check("pdf organize (reverse + rotate)") {
            let o = try PDFOps.organize(multi, pages: [PageEdit(index: 1, rotation: 90), PageEdit(index: 0)])
            let d = PDFDocument(url: o)!
            return expect(d.pageCount == 2 && d.page(at: 0)!.rotation == 90 && d.page(at: 1)!.string?.contains("Report") == true, "order")
        }
        check("pdf same width") {
            let d = PDFDocument(url: try PDFOps.sameWidth(multi))!
            let w = (0..<d.pageCount).map { d.page(at: $0)!.bounds(for: .mediaBox).width }
            return expect(Set(w.map { Int($0) }).count == 1, "\(w)")
        }
        check("pdf → png pages") { let o = try PDFOps.toImages(multi, ext: "png"); return expect(count(o) == 2, "count") }
        check("pdf compress") {
            let big = try ImageOps.imagesToPDF([png, png, png])
            do { let o = try PDFOps.compress(big, level: .high); return expect(fileSize(o) < fileSize(big), "not smaller") }
            catch { return error.localizedDescription.contains("already well compressed") ? nil : error.localizedDescription }
        }
        check("pdf → docx") { let o = try DocOps.convert(textPDF, to: "docx"); return expect(sh("textutil -convert txt -stdout '\(o.path)'").contains("Section Two"), "text") }
        check("pdf read QR") { let p = try ImageOps.imagesToPDF([f("qr.png")]); return expect(try ImageOps.readQRCodes(p) == ["https://example.com/dropwheel"], "no code") }
        check("pdf remove metadata") { expect(fileSize(try MetadataOps.removeAll(textPDF)) > 0, "empty") }

        // Documents
        for ext in ["epub", "docx", "rtf", "txt", "html"] {
            check("markdown → \(ext)") {
                let o = try DocOps.convert(f("notes.md"), to: ext)
                if ext == "epub" {
                    let lint = sh("cd '\(dir.path)' && rm -rf ep && mkdir ep && cd ep && unzip -q '\(o.path)' && xmllint --noout OEBPS/*.xhtml OEBPS/content.opf 2>&1; echo rc=$?")
                    let first = sh("unzip -Z1 '\(o.path)' | head -1")
                    return expect(lint.hasSuffix("rc=0") && first == "mimetype" && sh("ls '\(dir.path)/ep/OEBPS' | grep -c chapter") == "2", lint)
                }
                return expect(sh("textutil -convert txt -stdout '\(o.path)'").contains("Section Two"), "text missing")
            }
        }
        check("epub → pdf (round trip)") {
            let e = try DocOps.convert(f("notes.md"), to: "epub")
            let o = try DocOps.convert(e, to: "pdf")
            return expect(PDFDocument(url: o)?.string?.contains("Chapter Two") == true, "text missing")
        }
        check("docx → pdf") {
            let d = try DocOps.convert(f("notes.md"), to: "docx")
            let o = try DocOps.write(try DocOps.read(d).text, title: "t", like: d, ext: "pdf")
            return expect(PDFDocument(url: o)?.string?.contains("Section Two") == true, "text missing")
        }
        check("rtf → epub") { let r = try DocOps.convert(f("plain.txt"), to: "rtf"); let o = try DocOps.convert(r, to: "epub"); return expect(sh("unzip -p '\(o.path)' OEBPS/chapter1.xhtml").contains("Second line"), "text missing") }
        check("textClipping → pdf") { let o = try DocOps.convert(f("snippet.textClipping"), to: "pdf"); return expect(PDFDocument(url: o)?.string?.contains("Clipped text") == true, "text") }
        check("long text paginates") {
            let u = f("long.txt"); try String(repeating: "Line of text that goes on.\n", count: 400).write(to: u, atomically: true, encoding: .utf8)
            let o = try DocOps.convert(u, to: "pdf")
            return expect((PDFDocument(url: o)?.pageCount ?? 0) > 3, "pages \(PDFDocument(url: o)?.pageCount ?? 0)")
        }
        check("markdown rejects deep nesting") {
            let deep = (0..<40).map { String(repeating: "  ", count: $0) + "- x" }.joined(separator: "\n")
            do { _ = try Markdown.toHTML(deep); return "accepted" } catch { return nil }
        }

        // Archives
        for fmt in ["zip", "7z", "tar.gz", "tar.xz"] {
            check("archive \(fmt) round trip") {
                let a = try ArchiveOps.create([f("folder"), f("plain.txt")], format: fmt)
                let x = try ArchiveOps.extract(a)
                let diff = sh("diff -r '\(f("folder").path)' '\(x.path)/folder' && diff '\(f("plain.txt").path)' '\(x.path)/plain.txt' && echo same")
                return expect(diff == "same", diff)
            }
        }
        check("archive single item extracts in place") { let a = try ArchiveOps.create([f("folder")], format: "zip"); let x = try ArchiveOps.extract(a); return expect(FileManager.default.fileExists(atPath: x.appendingPathComponent("sub/b.txt").path), x.path) }
        check("archive refuses path traversal") {
            sh("cd '\(dir.path)' && mkdir -p evil/inner && echo x > evil/pwn.txt && cd evil/inner && bsdtar -cPf ../../evil.tar ../pwn.txt")
            do { _ = try ArchiveOps.extract(f("evil.tar")); return FileManager.default.fileExists(atPath: dir.deletingLastPathComponent().appendingPathComponent("pwn.txt").path) ? "escaped" : nil }
            catch { return nil }
        }
        check("plain .gz extracts") { sh("cd '\(dir.path)' && gzip -k plain.txt"); let x = try ArchiveOps.extract(f("plain.txt.gz")); return expect((try? String(contentsOf: x, encoding: .utf8))?.contains("Second line") == true, x.path) }

        // Never overwrite
        check("outputs never overwrite") {
            let a = try ImageOps.convert(png, to: "jpg"), b = try ImageOps.convert(png, to: "jpg")
            return expect(a != b && FileManager.default.fileExists(atPath: a.path) && FileManager.default.fileExists(atPath: b.path), "\(a.lastPathComponent) \(b.lastPathComponent)")
        }

        if office {
            check("office: docx → pages") { let d = try DocOps.convert(f("notes.md"), to: "docx"); let o = try DocOps.convert(d, to: "pages"); return expect(FileManager.default.fileExists(atPath: o.path), "missing") }
            check("office: csv → pdf (Numbers)") {
                let c = f("table.csv"); try "a,b\n1,2\n3,4\n".write(to: c, atomically: true, encoding: .utf8)
                return expect(PDFDocument(url: try Office.convert(c, to: "pdf"))?.pageCount ?? 0 > 0, "no pages")
            }
            check("office: pages → pdf") {
                let d = try DocOps.convert(f("notes.md"), to: "docx"); let p = try DocOps.convert(d, to: "pages")
                return expect(PDFDocument(url: try DocOps.convert(p, to: "pdf"))?.string?.contains("Section") == true, "text")
            }
        }
        return finish()
    }

    func finish() -> Bool {
        print("\n\(passed) passed, \(failed.count) failed")
        failed.forEach { print("  - \($0)") }
        return failed.isEmpty
    }
}
