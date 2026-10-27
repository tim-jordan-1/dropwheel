import CoreGraphics
import Foundation

public struct TimeRange: Codable, Hashable, Sendable {
    public var start: Double
    public var end: Double
    public init(_ start: Double, _ end: Double) { self.start = min(start, end); self.end = max(start, end) }
    public var duration: Double { end - start }
}

public enum VideoEncoding: String, CaseIterable, Codable, Sendable { case h264, hevc }

public struct VideoCompression: Codable, Sendable {
    public var level: CompressionLevel = .medium
    public var targetBytes: Int64? = nil
    public var maxHeight: Int? = nil
    public var encoding: VideoEncoding = .h264
    public init(level: CompressionLevel = .medium, targetBytes: Int64? = nil, maxHeight: Int? = nil, encoding: VideoEncoding = .h264) {
        self.level = level; self.targetBytes = targetBytes; self.maxHeight = maxHeight; self.encoding = encoding
    }
}

public struct VideoRedaction: Codable, Sendable {
    public var rect: CGRect      // pixels, top-left origin
    public var range: TimeRange? // nil = entire video
    public init(rect: CGRect, range: TimeRange?) { self.rect = rect; self.range = range }
}

public enum SplitExportMode: String, CaseIterable, Sendable { case separateVideos, oneVideo }

public enum ChannelMode: Codable, Hashable, Sendable {
    case mono, stereo, leftToBoth, rightToBoth, swap
    case volumes(left: Double, right: Double)
}

public enum VisualizationStyle: String, CaseIterable, Codable, Sendable { case wave, line, bars, spectrum }

func ffmpeg(_ args: [String], duration: Double = 0, progress: Progress? = nil, cancel: Cancellation? = nil) throws {
    try run(Tools.ffmpeg, ["-v", "error", "-y", "-nostdin", "-progress", "pipe:1", "-nostats"] + args, cancel: cancel) { line in
        if line.hasPrefix("out_time_us="), duration > 0, let us = Double(line.dropFirst(12)) { progress?(max(0, min(1, us / 1e6 / duration))) }
    }
}

func even(_ v: Double) -> Int { max(2, Int(v) / 2 * 2) }
func ts(_ t: Double) -> String { String(format: "%.3f", max(0, t)) }

// MARK: - Video

public enum VideoOps {
    static let h264 = ["-c:v", "libx264", "-preset", "medium", "-crf", "20", "-pix_fmt", "yuv420p"]
    static let evenScale = "scale=trunc(iw/2)*2:trunc(ih/2)*2"

    static func videoArgs(for ext: String, crf: Int = 20) -> [String] {
        switch ext {
        case "webm": return ["-c:v", "libvpx-vp9", "-crf", "\(crf + 12)", "-b:v", "0", "-row-mt", "1", "-deadline", "good", "-cpu-used", "4", "-pix_fmt", "yuv420p"]
        case "avi": return ["-c:v", "mpeg4", "-q:v", "3", "-vtag", "xvid"]
        default: return ["-c:v", "libx264", "-preset", "medium", "-crf", "\(crf)", "-pix_fmt", "yuv420p"]
        }
    }

    static func audioArgs(for ext: String) -> [String] {
        switch ext {
        case "webm": return ["-c:a", "libopus", "-b:a", "128k"]
        case "avi": return ["-c:a", "libmp3lame", "-q:a", "3"]
        default: return ["-c:a", "aac", "-b:a", "192k"]
        }
    }

    static func containerArgs(_ ext: String) -> [String] { ["mp4", "m4v", "mov"].contains(ext) ? ["-movflags", "+faststart"] : [] }

    /// Re-encodes with the default codecs for `ext`, applying optional filters.
    static func encode(_ input: [String], to url: URL, ext: String, vf: String? = nil, af: String? = nil, info: MediaInfo,
                       duration: Double? = nil, progress: Progress?, cancel: Cancellation?) throws {
        var args = input + ["-map", "0:v:0"] + (info.hasAudio ? ["-map", "0:a:0"] : [])
        args += ["-vf", [vf, evenScale].compactMap { $0 }.joined(separator: ",")]
        if let af { args += ["-af", af] }
        args += videoArgs(for: ext) + (info.hasAudio ? audioArgs(for: ext) : []) + containerArgs(ext) + [url.path]
        try ffmpeg(args, duration: duration ?? info.duration, progress: progress, cancel: cancel)
    }

    public static func convert(_ url: URL, to ext: String, progress: Progress? = nil, cancel: Cancellation? = nil) throws -> URL {
        let e = ext.lowercased()
        let info = try probe(url)
        if Formats.audioOut.contains(e) { return try AudioOps.convert(url, to: e, progress: progress, cancel: cancel) }
        let out = outputURL(for: url, ext: e)
        if e == "gif" {
            return try produce(out, verify: verifyImage) {
                try ffmpeg(["-i", url.path, "-vf", "fps=12,scale='min(640,iw)':-2:flags=lanczos,split[a][b];[a]palettegen=stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=4",
                            "-loop", "0", $0.path], duration: info.duration, progress: progress, cancel: cancel)
            }
        }
        return try produce(out, verify: { try verifyMedia($0, video: true) }) { tmp in
            // Remux without re-encoding when the codecs already fit the container.
            let mp4Safe = ["h264", "hevc"].contains(info.videoCodec) && (!info.hasAudio || ["aac", "mp3", "alac"].contains(info.audioCodec))
            if (["mp4", "m4v", "mov"].contains(e) && mp4Safe) || e == "mkv" && info.videoCodec != "gif" {
                do {
                    try ffmpeg(["-i", url.path, "-map", "0:v:0"] + (info.hasAudio ? ["-map", "0:a:0"] : []) + ["-c", "copy"] + (info.videoCodec == "hevc" ? ["-tag:v", "hvc1"] : []) + containerArgs(e) + [tmp.path],
                               duration: info.duration, progress: progress, cancel: cancel)
                    return
                } catch { if cancel?.isCancelled == true { throw error } }
            }
            try encode(["-i", url.path], to: tmp, ext: e, info: info, progress: progress, cancel: cancel)
        }
    }

    public static func compress(_ url: URL, _ o: VideoCompression = .init(), progress: Progress? = nil, cancel: Cancellation? = nil) throws -> URL {
        let info = try probe(url)
        guard info.duration > 0 else { throw OpError("Could not read the video duration.") }
        let ext = ["mov", "mp4", "m4v"].contains(url.pathExtension.lowercased()) ? url.pathExtension.lowercased() : "mp4"
        let out = outputURL(for: url, ext: ext, suffix: "compressed")
        var vf = evenScale
        if let mh = o.maxHeight, info.height > mh { vf = "scale=-2:\(mh)" }
        let codec: [String] = o.encoding == .hevc ? ["-c:v", "libx265", "-tag:v", "hvc1", "-preset", "medium"] : ["-c:v", "libx264", "-preset", "medium"]
        var audio: [String] = info.hasAudio ? ["-c:a", "aac", "-b:a", "128k"] : ["-an"]
        let audioMap: [String] = info.hasAudio ? ["-map", "0:a:0"] : []
        if let t = o.targetBytes, info.hasAudio { audio[3] = "\(max(32, min(128, Int(Double(t) * 8 / info.duration / 1000 * 0.96 * 0.2))))k" }
        return try produce(out, verify: { try verifyMedia($0, video: true); try requireSmaller($0, than: url) }) { tmp in
            if let target = o.targetBytes {
                let totalKbps = Double(target) * 8 / info.duration / 1000 * 0.96
                let audioKbps = info.hasAudio ? max(32, min(128, Int(totalKbps * 0.2))) : 0
                let videoKbps = Int(totalKbps) - audioKbps
                guard videoKbps >= 80 else { throw OpError("The target file size is too small for a \(Int(info.duration)) second video.") }
                let log = tempURL(ext: "").path
                defer { try? FileManager.default.removeItem(atPath: log + "-0.log"); try? FileManager.default.removeItem(atPath: log + "-0.log.mbtree") }
                let base: [String] = ["-i", url.path, "-map", "0:v:0", "-vf", vf, "-pix_fmt", "yuv420p"] + codec + ["-b:v", "\(videoKbps)k", "-maxrate", "\(Int(Double(videoKbps) * 1.5))k", "-bufsize", "\(videoKbps * 2)k"]
                if o.encoding == .h264 {
                    try ffmpeg(base + ["-pass", "1", "-passlogfile", log, "-an", "-f", "null", "/dev/null"], duration: info.duration * 2,
                               progress: progress, cancel: cancel)
                    try ffmpeg(base + ["-pass", "2", "-passlogfile", log] + audioMap + audio + containerArgs(ext) + [tmp.path],
                               duration: info.duration * 2, progress: { p in progress?(0.5 + p) }, cancel: cancel)
                } else {
                    try ffmpeg(base + audioMap + audio + containerArgs(ext) + [tmp.path], duration: info.duration, progress: progress, cancel: cancel)
                }
            } else {
                let crf = [CompressionLevel.low: 23, .medium: 27, .high: 31][o.level]! + (o.encoding == .hevc ? 2 : 0)
                try ffmpeg(["-i", url.path, "-map", "0:v:0"] + audioMap + ["-vf", vf, "-pix_fmt", "yuv420p"] + codec + ["-crf", "\(crf)"] + audio + containerArgs(ext) + [tmp.path],
                           duration: info.duration, progress: progress, cancel: cancel)
            }
        }
    }

    public static func trim(_ url: URL, _ r: TimeRange, progress: Progress? = nil, cancel: Cancellation? = nil) throws -> URL {
        let info = try probe(url)
        guard r.duration > 0.05 else { throw OpError("Drag the ends to trim. The selection is empty.") }
        let ext = mediaExt(url)
        let out = outputURL(for: url, ext: ext, suffix: "trimmed")
        return try produce(out, verify: { try verifyMedia($0, video: true) }) {
            try encode(["-ss", ts(r.start), "-to", ts(r.end), "-i", url.path], to: $0, ext: ext, info: info, duration: r.duration, progress: progress, cancel: cancel)
        }
    }

    static func mediaExt(_ url: URL) -> String {
        let e = url.pathExtension.lowercased()
        return ["mp4", "mov", "m4v", "mkv", "webm"].contains(e) ? e : "mp4"
    }

    /// Exports kept segments either as separate files or joined into one video.
    public static func split(_ url: URL, segments: [TimeRange], mode: SplitExportMode, progress: Progress? = nil, cancel: Cancellation? = nil) throws -> [URL] {
        guard !segments.isEmpty else { throw OpError("Keep at least one segment.") }
        let info = try probe(url)
        let ext = mediaExt(url)
        switch mode {
        case .separateVideos:
            var outs: [URL] = []
            for (i, s) in segments.enumerated() {
                let out = outputURL(for: url, ext: ext, suffix: "part \(i + 1)")
                outs.append(try produce(out, verify: { try verifyMedia($0, video: true) }) {
                    try encode(["-ss", ts(s.start), "-to", ts(s.end), "-i", url.path], to: $0, ext: ext, info: info, duration: s.duration,
                               progress: { p in progress?((Double(i) + p) / Double(segments.count)) }, cancel: cancel)
                })
            }
            return outs
        case .oneVideo:
            var graph = "", labels = ""
            for (i, s) in segments.enumerated() {
                graph += "[0:v]trim=\(ts(s.start)):\(ts(s.end)),setpts=PTS-STARTPTS[v\(i)];"
                if info.hasAudio { graph += "[0:a]atrim=\(ts(s.start)):\(ts(s.end)),asetpts=PTS-STARTPTS[a\(i)];" }
                labels += "[v\(i)]" + (info.hasAudio ? "[a\(i)]" : "")
            }
            graph += "\(labels)concat=n=\(segments.count):v=1:a=\(info.hasAudio ? 1 : 0)[v]" + (info.hasAudio ? "[a]" : "") + ";[v]\(evenScale)[vo]"
            let total = segments.reduce(0) { $0 + $1.duration }
            let out = outputURL(for: url, ext: ext, suffix: "edited")
            return [try produce(out, verify: { try verifyMedia($0, video: true) }) {
                try ffmpeg(["-i", url.path, "-filter_complex", graph, "-map", "[vo]"] + (info.hasAudio ? ["-map", "[a]"] : []) + videoArgs(for: ext) + (info.hasAudio ? audioArgs(for: ext) : []) + containerArgs(ext) + [$0.path],
                           duration: total, progress: progress, cancel: cancel)
            }]
        }
    }

    /// Joins videos in drop order. Each clip is letterboxed to the first clip's size.
    public static func join(_ urls: [URL], progress: Progress? = nil, cancel: Cancellation? = nil) throws -> URL {
        guard urls.count >= 2 else { throw OpError("Drop at least two videos to join.") }
        let infos = try urls.map(probe)
        let W = even(Double(infos[0].width)), H = even(Double(infos[0].height))
        var inputs: [String] = [], graph = "", labels = ""
        for u in urls { inputs += ["-i", u.path] }
        for (i, info) in infos.enumerated() {
            graph += "[\(i):v:0]scale=\(W):\(H):force_original_aspect_ratio=decrease,pad=\(W):\(H):(ow-iw)/2:(oh-ih)/2,setsar=1,fps=30,format=yuv420p[v\(i)];"
            if info.hasAudio {
                graph += "[\(i):a:0]aresample=48000,aformat=channel_layouts=stereo[a\(i)];"
            } else {
                graph += "anullsrc=r=48000:cl=stereo,atrim=0:\(ts(info.duration))[a\(i)];"
            }
            labels += "[v\(i)][a\(i)]"
        }
        graph += "\(labels)concat=n=\(urls.count):v=1:a=1[v][a]"
        let out = outputURL(for: urls[0], ext: "mp4", suffix: "joined")
        let total = infos.reduce(0) { $0 + $1.duration }
        return try produce(out, verify: { try verifyMedia($0, video: true, audio: true) }) {
            try ffmpeg(inputs + ["-filter_complex", graph, "-map", "[v]", "-map", "[a]"] + h264 + ["-c:a", "aac", "-b:a", "192k", "-movflags", "+faststart", $0.path],
                       duration: total, progress: progress, cancel: cancel)
        }
    }

    public static func crop(_ url: URL, rect: CGRect, progress: Progress? = nil, cancel: Cancellation? = nil) throws -> URL {
        let info = try probe(url)
        let r = rect.integral.intersection(CGRect(x: 0, y: 0, width: info.width, height: info.height))
        guard r.width >= 16, r.height >= 16 else { throw OpError("Make the crop at least 16 pixels wide and tall.") }
        let ext = mediaExt(url)
        let out = outputURL(for: url, ext: ext, suffix: "cropped")
        return try produce(out, verify: { try verifyMedia($0, video: true) }) {
            try encode(["-i", url.path], to: $0, ext: ext, vf: "crop=\(even(r.width)):\(even(r.height)):\(Int(r.minX)):\(Int(r.minY))", info: info, progress: progress, cancel: cancel)
        }
    }

    static func atempo(_ factor: Double) -> String {
        var f = factor, parts: [String] = []
        while f > 2 { parts.append("atempo=2"); f /= 2 }
        while f < 0.5 { parts.append("atempo=0.5"); f /= 0.5 }
        parts.append(String(format: "atempo=%.4f", f))
        return parts.joined(separator: ",")
    }

    public static func changeSpeed(_ url: URL, factor: Double, progress: Progress? = nil, cancel: Cancellation? = nil) throws -> URL {
        guard (0.1...10).contains(factor), factor != 1 else { throw OpError("Choose a speed between 0.1× and 10×.") }
        let info = try probe(url)
        let ext = mediaExt(url)
        let out = outputURL(for: url, ext: ext, suffix: String(format: "%g×", factor))
        return try produce(out, verify: { try verifyMedia($0, video: true) }) {
            try encode(["-i", url.path], to: $0, ext: ext, vf: String(format: "setpts=(PTS-STARTPTS)/%.4f", factor), af: info.hasAudio ? atempo(factor) : nil,
                       info: info, duration: info.duration / factor, progress: progress, cancel: cancel)
        }
    }

    /// Saves PNG snapshots at the given times into a new folder.
    public static func exportFrames(_ url: URL, at times: [Double], cancel: Cancellation? = nil) throws -> URL {
        guard !times.isEmpty else { throw OpError("Add at least one frame.") }
        let dir = uniqueURL(url.deletingLastPathComponent().appendingPathComponent(url.deletingPathExtension().lastPathComponent + " frames"), ext: "")
        let tmp = tempURL(ext: "")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        for (i, t) in times.sorted().enumerated() {
            let name = String(format: "Frame %02d (%@).png", i + 1, timecode(t).replacingOccurrences(of: ":", with: "."))
            try ffmpeg(["-ss", ts(t), "-i", url.path, "-frames:v", "1", tmp.appendingPathComponent(name).path], cancel: cancel)
        }
        for f in try FileManager.default.contentsOfDirectory(at: tmp, includingPropertiesForKeys: nil) { try verifyImage(f) }
        try verifyDirectoryNotEmpty(tmp)
        try FileManager.default.moveItem(at: tmp, to: dir)
        return dir
    }

    /// One frame as an image, for editor previews.
    public static func frame(_ url: URL, at t: Double, maxSide: Int? = nil) throws -> CGImage {
        let tmp = tempURL(ext: "png"); defer { try? FileManager.default.removeItem(at: tmp) }
        var args = ["-ss", ts(t), "-i", url.path, "-frames:v", "1"]
        if let m = maxSide { args += ["-vf", "scale='min(\(m),iw)':-2"] }
        try ffmpeg(args + [tmp.path])
        return try ImageOps.load(tmp)
    }

    /// Small frames spread over the video, for timelines.
    public static func thumbnails(_ url: URL, count: Int, height: Int = 60) throws -> [CGImage] {
        let info = try probe(url)
        let dir = tempURL(ext: "")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let rate = Double(count) / max(info.duration, 0.1)
        try ffmpeg(["-i", url.path, "-vf", String(format: "fps=%.5f,scale=-2:%d", rate, height), "-frames:v", "\(count)", dir.appendingPathComponent("t%03d.png").path])
        return try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .sorted { $0.lastPathComponent < $1.lastPathComponent }.map(ImageOps.load)
    }

    public static func redact(_ url: URL, _ items: [VideoRedaction], style: RedactionStyle, progress: Progress? = nil, cancel: Cancellation? = nil) throws -> URL {
        guard !items.isEmpty else { throw OpError("Add at least one redaction.") }
        let info = try probe(url)
        let bounds = CGRect(x: 0, y: 0, width: info.width, height: info.height)
        var graph: String
        if style == .solid {
            let boxes = items.map { item -> String in
                let r = item.rect.integral.intersection(bounds)
                let en = item.range.map { ":enable='between(t,\(ts($0.start)),\(ts($0.end)))'" } ?? ""
                return "drawbox=x=\(Int(r.minX)):y=\(Int(r.minY)):w=\(Int(r.width)):h=\(Int(r.height)):color=black:t=fill\(en)"
            }
            graph = "[0:v]" + boxes.joined(separator: ",") + ",\(evenScale)[v]"
        } else {
            graph = "[0:v]split=\(items.count + 1)[base]" + items.indices.map { "[c\($0)]" }.joined() + ";"
            var last = "base"
            for (i, item) in items.enumerated() {
                let r = item.rect.integral.intersection(bounds)
                let w = even(r.width), h = even(r.height)
                let radius = max(4, min(w, h) / 6)
                let en = item.range.map { ":enable='between(t,\(ts($0.start)),\(ts($0.end)))'" } ?? ""
                graph += "[c\(i)]crop=\(w):\(h):\(Int(r.minX)):\(Int(r.minY)),boxblur=\(min(radius, h / 2 - 1)):3[b\(i)];"
                graph += "[\(last)][b\(i)]overlay=\(Int(r.minX)):\(Int(r.minY))\(en)[o\(i)];"
                last = "o\(i)"
            }
            graph += "[\(last)]\(evenScale)[v]"
        }
        let ext = mediaExt(url)
        let out = outputURL(for: url, ext: ext, suffix: "redacted")
        return try produce(out, verify: { try verifyMedia($0, video: true) }) {
            try ffmpeg(["-i", url.path, "-filter_complex", graph, "-map", "[v]"] + (info.hasAudio ? ["-map", "0:a:0", "-c:a", "copy"] : []) + videoArgs(for: ext) + containerArgs(ext) + [$0.path],
                       duration: info.duration, progress: progress, cancel: cancel)
        }
    }

    /// Adds a subtitle file as a soft subtitle track.
    public static func addSubtitles(_ video: URL, _ subs: URL, progress: Progress? = nil, cancel: Cancellation? = nil) throws -> URL {
        var ext = video.pathExtension.lowercased()
        if !["mp4", "m4v", "mov", "mkv", "webm"].contains(ext) { ext = "mkv" }
        let codec = ["mp4", "m4v", "mov"].contains(ext) ? "mov_text" : ext == "webm" ? "webvtt" : "srt"
        let info = try probe(video)
        let out = outputURL(for: video, ext: ext, suffix: "subtitled")
        return try produce(out, verify: { try verifyMedia($0, video: true) }) {
            try ffmpeg(["-i", video.path, "-i", subs.path, "-map", "0:v", "-map", "0:a?", "-map", "1:0", "-c:v", "copy", "-c:a", "copy", "-c:s", codec,
                        "-metadata:s:s:0", "language=eng"] + containerArgs(ext) + [$0.path], duration: info.duration, progress: progress, cancel: cancel)
        }
    }

    public static func convertSubtitles(_ url: URL, to ext: String) throws -> URL {
        let out = outputURL(for: url, ext: ext)
        return try produce(out, verify: { tmp in
            let text = (try? String(contentsOf: tmp, encoding: .utf8)) ?? ""
            if !text.contains("-->") { throw OpError("The converted subtitles could not be verified.") }
        }) { try ffmpeg(["-i", url.path, $0.path]) }
    }
}

public func timecode(_ t: Double) -> String {
    let s = Int(t), ms = Int((t - Double(s)) * 10)
    return s >= 3600 ? String(format: "%d:%02d:%02d.%d", s / 3600, s / 60 % 60, s % 60, ms) : String(format: "%d:%02d.%d", s / 60, s % 60, ms)
}

// MARK: - Audio

public enum AudioOps {
    public static func codecArgs(_ ext: String) -> [String] {
        switch ext {
        case "mp3": return ["-c:a", "libmp3lame", "-q:a", "2"]
        case "m4a": return ["-c:a", "aac", "-b:a", "192k"]
        case "aac": return ["-c:a", "aac", "-b:a", "192k", "-f", "adts"]
        case "wav": return ["-c:a", "pcm_s16le"]
        case "aiff", "aif": return ["-c:a", "pcm_s16be"]
        case "flac": return ["-c:a", "flac"]
        case "ogg": return ["-c:a", "libopus", "-b:a", "160k"]
        case "opus": return ["-c:a", "libopus", "-b:a", "128k"]
        case "caf": return ["-c:a", "alac"]
        default: return ["-c:a", "aac", "-b:a", "192k"]
        }
    }

    static func outExt(_ url: URL) -> String {
        let e = url.pathExtension.lowercased()
        return Formats.audioOut.contains(e) ? e : "m4a"
    }

    /// Runs an audio filter. Video files keep their video stream untouched.
    static func filtered(_ url: URL, suffix: String, af: String? = nil, filterComplex: String? = nil, pre: [String] = [], extraInputs: [String] = [],
                         outDuration: Double? = nil, progress: Progress?, cancel: Cancellation?) throws -> URL {
        let info = try probe(url)
        guard info.hasAudio else { throw OpError("\(url.lastPathComponent) has no audio.") }
        let isVideo = kind(of: url) == .video
        let ext = isVideo ? VideoOps.mediaExt(url) : outExt(url)
        let out = outputURL(for: url, ext: ext, suffix: suffix)
        var args = pre + ["-i", url.path] + extraInputs
        if let filterComplex {
            args += ["-filter_complex", filterComplex, "-map", "[out]"]
        } else {
            args += ["-map", "0:a:0"]
            if let af { args += ["-af", af] }
        }
        if isVideo {
            args += ["-map", "0:v:0", "-c:v", "copy"] + VideoOps.audioArgs(for: ext) + VideoOps.containerArgs(ext)
        } else {
            args += ["-vn", "-ar", "\(info.sampleRate)"] + codecArgs(ext)
        }
        return try produce(out, verify: { try verifyMedia($0, audio: true) }) {
            try ffmpeg(args + [$0.path], duration: outDuration ?? info.duration, progress: progress, cancel: cancel)
        }
    }

    public static func convert(_ url: URL, to ext: String, progress: Progress? = nil, cancel: Cancellation? = nil) throws -> URL {
        let info = try probe(url)
        guard info.hasAudio else { throw OpError("\(url.lastPathComponent) has no audio.") }
        let out = outputURL(for: url, ext: ext)
        return try produce(out, verify: { try verifyMedia($0, audio: true) }) {
            try ffmpeg(["-i", url.path, "-map", "0:a:0", "-vn"] + codecArgs(ext) + [$0.path], duration: info.duration, progress: progress, cancel: cancel)
        }
    }

    public static func compress(_ url: URL, level: CompressionLevel = .medium, targetBytes: Int64? = nil, progress: Progress? = nil, cancel: Cancellation? = nil) throws -> URL {
        let info = try probe(url)
        var ext = url.pathExtension.lowercased()
        if !["mp3", "m4a", "aac", "ogg", "opus"].contains(ext) { ext = "m4a" }
        var kbps = [CompressionLevel.low: 192, .medium: 128, .high: 96][level]!
        if let t = targetBytes, info.duration > 0 { kbps = Int(Double(t) * 8 / info.duration / 1000 * 0.97) }
        guard kbps >= 24 else { throw OpError("The target file size is too small for this audio.") }
        let codec = ext == "mp3" ? "libmp3lame" : ["ogg", "opus"].contains(ext) ? "libopus" : "aac"
        let out = outputURL(for: url, ext: ext, suffix: "compressed")
        return try produce(out, verify: { try verifyMedia($0, audio: true); try requireSmaller($0, than: url) }) {
            try ffmpeg(["-i", url.path, "-map", "0:a:0", "-vn", "-c:a", codec, "-b:a", "\(kbps)k"] + (ext == "aac" ? ["-f", "adts"] : []) + [$0.path],
                       duration: info.duration, progress: progress, cancel: cancel)
        }
    }

    public static func join(_ urls: [URL], progress: Progress? = nil, cancel: Cancellation? = nil) throws -> URL {
        guard urls.count >= 2 else { throw OpError("Drop at least two audio files to join.") }
        let infos = try urls.map(probe)
        var inputs: [String] = [], graph = ""
        for (i, u) in urls.enumerated() {
            inputs += ["-i", u.path]
            graph += "[\(i):a:0]aresample=48000,aformat=channel_layouts=stereo[a\(i)];"
        }
        graph += urls.indices.map { "[a\($0)]" }.joined() + "concat=n=\(urls.count):v=0:a=1[out]"
        let ext = outExt(urls[0])
        let out = outputURL(for: urls[0], ext: ext, suffix: "joined")
        return try produce(out, verify: { try verifyMedia($0, audio: true) }) {
            try ffmpeg(inputs + ["-filter_complex", graph, "-map", "[out]"] + codecArgs(ext) + [$0.path],
                       duration: infos.reduce(0) { $0 + $1.duration }, progress: progress, cancel: cancel)
        }
    }

    /// EBU R128 loudness normalization in two passes.
    public static func normalize(_ url: URL, targetLUFS: Double = -16, progress: Progress? = nil, cancel: Cancellation? = nil) throws -> URL {
        let measure = "loudnorm=I=\(targetLUFS):TP=-1.5:LRA=11:print_format=json"
        var json = ""
        let p = Process()
        p.executableURL = URL(fileURLWithPath: try Tools.ffmpeg)
        p.arguments = ["-hide_banner", "-nostdin", "-i", url.path, "-map", "0:a:0", "-af", measure, "-f", "null", "-"]
        let pipe = Pipe(); p.standardError = pipe; p.standardOutput = FileHandle.nullDevice
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        json = String(data: data, encoding: .utf8) ?? ""
        var af = "loudnorm=I=\(targetLUFS):TP=-1.5:LRA=11"
        if let start = json.lastIndex(of: "{"), let end = json.lastIndex(of: "}"),
           let obj = try? JSONSerialization.jsonObject(with: Data(json[start...end].utf8)) as? [String: String],
           let i = obj["input_i"], let tp = obj["input_tp"], let lra = obj["input_lra"], let th = obj["input_thresh"], let off = obj["target_offset"],
           Double(i)?.isFinite == true {
            af += ":measured_I=\(i):measured_TP=\(tp):measured_LRA=\(lra):measured_thresh=\(th):offset=\(off):linear=true"
        }
        progress?(0.5)
        return try filtered(url, suffix: "normalized", af: af, progress: { progress?(0.5 + $0 / 2) }, cancel: cancel)
    }

    /// Mutes each range and plays a 1 kHz tone over it. `tone: false` leaves silence.
    public static func bleep(_ url: URL, ranges: [TimeRange], tone: Bool = true, progress: Progress? = nil, cancel: Cancellation? = nil) throws -> URL {
        guard !ranges.isEmpty else { throw OpError("Drag to add a bleep.") }
        let info = try probe(url)
        let gate = ranges.map { "between(t,\(ts($0.start)),\(ts($0.end)))" }.joined(separator: "+")
        let layout = info.audioChannels == 1 ? "mono" : "stereo"
        var graph = "[0:a:0]aformat=channel_layouts=\(layout),volume=0:enable='\(gate)'[m]"
        if tone {
            graph += ";aevalsrc='0.3*sin(2*PI*1000*t)*gt(\(gate),0)':s=\(info.sampleRate):c=\(layout):d=\(ts(info.duration))[s];[m][s]amix=inputs=2:duration=first:normalize=0[out]"
        } else {
            graph += ";[m]anull[out]"
        }
        return try filtered(url, suffix: "bleeped", filterComplex: graph, progress: progress, cancel: cancel)
    }

    public static func trim(_ url: URL, _ r: TimeRange?, silentEnds: Bool, thresholdDB: Double = -50, progress: Progress? = nil, cancel: Cancellation? = nil) throws -> URL {
        var pre: [String] = []
        if let r { pre = ["-ss", ts(r.start), "-to", ts(r.end)] }
        let sr = "silenceremove=start_periods=1:start_threshold=\(Int(thresholdDB))dB:start_silence=0.05"
        let af = silentEnds ? "\(sr),areverse,\(sr),areverse" : nil
        guard r != nil || silentEnds else { throw OpError("Drag the ends to trim, or trim silent ends automatically.") }
        return try filtered(url, suffix: "trimmed", af: af, pre: pre, outDuration: r?.duration, progress: progress, cancel: cancel)
    }

    public static func channels(_ url: URL, _ mode: ChannelMode, progress: Progress? = nil, cancel: Cancellation? = nil) throws -> URL {
        let info = try probe(url)
        let mono = info.audioChannels == 1
        let pan: String
        switch mode {
        case .mono: pan = mono ? "anull" : "pan=mono|c0=0.5*c0+0.5*c1"
        case .stereo: pan = mono ? "pan=stereo|c0=c0|c1=c0" : "anull"
        case .leftToBoth: pan = "pan=stereo|c0=c0|c1=c0"
        case .rightToBoth: pan = mono ? "pan=stereo|c0=c0|c1=c0" : "pan=stereo|c0=c1|c1=c1"
        case .swap: pan = mono ? "anull" : "pan=stereo|c0=c1|c1=c0"
        case let .volumes(l, r): pan = mono ? "pan=stereo|c0=\(l)*c0|c1=\(r)*c0" : "pan=stereo|c0=\(l)*c0|c1=\(r)*c1"
        }
        if pan == "anull" { throw OpError("The audio already has that channel layout.") }
        return try filtered(url, suffix: "channels", af: pan, progress: progress, cancel: cancel)
    }

    /// Makes a video of the audio's waveform, over a still image or a solid color.
    public static func visualize(_ url: URL, image: URL?, style: VisualizationStyle, color: String = "ffffff", background: String = "101014",
                                 progress: Progress? = nil, cancel: Cancellation? = nil) throws -> URL {
        let info = try probe(url)
        guard info.hasAudio else { throw OpError("\(url.lastPathComponent) has no audio.") }
        var W = 1280, H = 720
        if let image, let cg = try? ImageOps.load(image) {
            let s = min(1.0, 1920.0 / Double(max(cg.width, cg.height)))
            W = even(Double(cg.width) * s); H = even(Double(cg.height) * s)
        }
        let bandH = even(Double(H) / 3)
        let viz: String
        switch style {
        case .wave: viz = "showwaves=s=\(W)x\(bandH):mode=cline:rate=30:colors=0x\(color)"
        case .line: viz = "showwaves=s=\(W)x\(bandH):mode=line:rate=30:colors=0x\(color)"
        // showfreqs can stall when overlaid, so bars come from showcqt.
        case .bars: viz = "showcqt=s=\(W)x\(bandH):r=30:sono_h=0:bar_g=2:axis=0:basefreq=40:endfreq=8000"
        case .spectrum: viz = "showspectrum=s=\(W)x\(bandH):slide=scroll:color=intensity:scale=cbrt,fps=30"
        }
        var inputs = ["-i", url.path]
        let bg: String
        if let image {
            inputs += ["-loop", "1", "-framerate", "30", "-i", image.path]
            bg = "[1:v]scale=\(W):\(H):force_original_aspect_ratio=increase,crop=\(W):\(H),setsar=1[bg]"
        } else {
            inputs += ["-f", "lavfi", "-i", "color=c=0x\(background):s=\(W)x\(H):r=30"]
            bg = "[1:v]null[bg]"
        }
        let graph = "\(bg);[0:a:0]\(viz),format=rgba,colorkey=0x000000:0.01:0.0[w];[bg][w]overlay=0:\(H - bandH - H / 12):shortest=1,format=yuv420p[v]"
        let out = outputURL(for: url, ext: "mp4", suffix: "visualizer")
        return try produce(out, verify: { try verifyMedia($0, video: true, audio: true) }) {
            try ffmpeg(inputs + ["-filter_complex", graph, "-map", "[v]", "-map", "0:a:0", "-c:v", "libx264", "-preset", "veryfast", "-crf", "22",
                                 "-c:a", "aac", "-b:a", "192k", "-shortest", "-t", ts(info.duration), "-movflags", "+faststart", $0.path],
                       duration: info.duration, progress: progress, cancel: cancel)
        }
    }

    /// Peak levels per bucket, 0...1, for waveform views. One array per channel.
    public static func waveform(_ url: URL, buckets: Int, perChannel: Bool = false) throws -> [[Float]] {
        let info = try probe(url)
        let ch = perChannel ? max(1, min(info.audioChannels, 2)) : 1
        let raw = tempURL(ext: "raw"); defer { try? FileManager.default.removeItem(at: raw) }
        try ffmpeg(["-i", url.path, "-map", "0:a:0", "-ac", "\(ch)", "-ar", "4000", "-f", "s16le", "-c:a", "pcm_s16le", raw.path])
        let data = try Data(contentsOf: raw)
        let samples = data.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
        let frames = samples.count / ch
        guard frames > 0 else { return Array(repeating: Array(repeating: 0, count: buckets), count: ch) }
        return (0..<ch).map { c in
            (0..<buckets).map { b in
                let lo = b * frames / buckets, hi = max(lo + 1, (b + 1) * frames / buckets)
                var peak: Int32 = 0
                for f in lo..<min(hi, frames) { peak = max(peak, abs(Int32(samples[f * ch + c]))) }
                return Float(peak) / 32768
            }
        }
    }

    /// Start and end of non-silent audio, for previewing "trim silent ends".
    public static func detectSilentEnds(_ url: URL, thresholdDB: Double) throws -> TimeRange {
        let info = try probe(url)
        let wf = try waveform(url, buckets: max(100, Int(info.duration * 50)))[0]
        let lin = Float(pow(10, thresholdDB / 20))
        let first = wf.firstIndex { $0 > lin } ?? 0, last = wf.lastIndex { $0 > lin } ?? (wf.count - 1)
        let step = info.duration / Double(wf.count)
        return TimeRange(Double(first) * step, Double(last + 1) * step)
    }
}
