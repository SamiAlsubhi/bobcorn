import Foundation

struct SubtitleCue {
    let start: Double
    let end: Double
    let text: String
}

struct SubtitleTrack: Identifiable, Hashable {
    enum Source: Hashable {
        case torrent(fileIndex: Int)
        case local(URL)
    }

    let id: String
    let label: String
    let source: Source
    /// OpenSubtitles' code, when known.
    var language: String?
}

/// SubRip (.srt) and WebVTT (.vtt), which are close enough to share a parser.
enum SubtitleParser {
    static func parse(_ data: Data) -> [SubtitleCue] {
        let text = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .windowsCP1252)
            ?? String(decoding: data, as: UTF8.self)
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var cues: [SubtitleCue] = []
        for block in normalized.components(separatedBy: "\n\n") {
            let lines = block.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            guard let timingIndex = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let parts = lines[timingIndex].components(separatedBy: "-->")
            guard parts.count == 2,
                  let start = parseTime(parts[0]),
                  let end = parseTime(parts[1].trimmingCharacters(in: .whitespaces).components(separatedBy: " ").first ?? "")
            else { continue }
            let body = lines[(timingIndex + 1)...]
                .map { $0.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression) }
                .map { $0.replacingOccurrences(of: "\\{\\\\[^}]*\\}", with: "", options: .regularExpression) }
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !body.isEmpty { cues.append(SubtitleCue(start: start, end: end, text: body)) }
        }
        return cues.sorted { $0.start < $1.start }
    }

    /// "01:02:03,456", "01:02:03.456" or "02:03.456".
    static func parseTime(_ raw: String) -> Double? {
        let s = raw.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        let parts = s.split(separator: ":")
        guard parts.count == 2 || parts.count == 3 else { return nil }
        var total = 0.0
        for p in parts {
            guard let v = Double(p) else { return nil }
            total = total * 60 + v
        }
        return total
    }

    /// Cues as WebVTT, the format Chromecasts show.
    static func webVTT(_ cues: [SubtitleCue]) -> String {
        var out = "WEBVTT\n"
        for cue in cues {
            let text = cue.text
                .replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: "-->", with: "->")
            out += "\n\(vttTime(cue.start)) --> \(vttTime(cue.end))\n\(text)\n"
        }
        return out
    }

    /// "01:02:03.456".
    static func vttTime(_ seconds: Double) -> String {
        let ms = Int((max(0, seconds) * 1000).rounded())
        return String(format: "%02d:%02d:%02d.%03d", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, ms % 1000)
    }

    /// The cue showing at `time`, if any.
    static func cue(at time: Double, in cues: [SubtitleCue]) -> SubtitleCue? {
        var lo = 0
        var hi = cues.count - 1
        var candidate: Int?
        while lo <= hi {
            let mid = (lo + hi) / 2
            if cues[mid].start <= time {
                candidate = mid
                lo = mid + 1
            } else {
                hi = mid - 1
            }
        }
        guard let c = candidate else { return nil }
        // Overlapping cues: look back a little for one still on screen.
        var i = c
        while i >= 0 && i >= c - 3 {
            if cues[i].end >= time { return cues[i] }
            i -= 1
        }
        return nil
    }
}
