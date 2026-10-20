import Foundation

/// Plays a Matroska file through AVPlayer by serving it as HLS: a fragmented
/// MP4 init segment and media segments cut at the file's keyframes, each
/// made when it's asked for. The video and audio are copied as they are; only
/// the container changes, so it costs almost nothing.
public final class HLSRemuxer: Sendable {
    public static let fileExtensions: Set<String> = ["mkv", "mk3d", "webm"]

    /// Where a segment starts: the first video keyframe in a cluster at or
    /// after `position`, presented at or after `time` when it's known.
    struct Boundary: Sendable {
        let position: Int64
        let time: Int64?

        func matches(cluster: Int64, time t: Int64) -> Bool {
            cluster >= position && t >= (time ?? .min)
        }
    }

    let source: ByteSource
    let header: MKVHeader
    let video: TrackPlan
    let audio: TrackPlan?
    /// The audio track's first timestamp, which its frames line up from.
    let audioOrigin: Int64
    /// For a Chromecast, which can't play AC-3 and its like: the audio as AAC,
    /// served under `cast/`. Nil when the audio plays there as it is.
    let castAudio: AACTranscoder?
    let castInitSegment: Data
    let boundaries: [Boundary]
    /// Seconds per segment.
    let durations: [Double]
    public let initSegment: Data
    /// Whether segments come from the file's index or from byte guesses.
    public let indexed: Bool
    private let cache = SegmentCache()

    static let targetSegment: Int64 = 6_000_000_000

    public static func open(_ source: ByteSource) async throws -> HLSRemuxer {
        let header = try await Matroska.readHeader(source)
        let videos = header.tracks.filter { $0.kind == .video && $0.isEnabled }
        guard let videoTrack = videos.first(where: \.isDefault) ?? videos.first else { throw RemuxError.noVideo }
        let video = try Codecs.video(videoTrack)

        // The default audio, or failing that one in its language that isn't
        // a commentary.
        let audios = header.tracks.filter { $0.kind == .audio && $0.isEnabled }
        let preferred = audios.first(where: \.isDefault) ?? audios.first
        let audioTrack = audios.filter(Codecs.audioSupported).max { score($0, preferred) < score($1, preferred) }
        if audioTrack == nil, let preferred { throw RemuxError.unsupportedAudio(Codecs.name(preferred.codecID)) }

        // The first audio frame, where some codecs keep their setup.
        var firstAudio: (time: Int64, data: Data)?
        if let audioTrack {
            let r = EBMLReader(source, at: header.firstCluster)
            defer { r.close() }
            var clusters = 0
            while clusters < 16, firstAudio == nil,
                  let c = try await r.nextCluster(scale: header.timestampScale, end: header.segmentEnd) {
                clusters += 1
                if let b = c.blocks.first(where: { $0.track == audioTrack.number }), let f = b.frames.first {
                    firstAudio = (b.time, (audioTrack.strippedHeader ?? Data()) + f)
                }
            }
        }
        let audio = try audioTrack.map { try Codecs.audio($0, firstFrame: firstAudio?.data) }
        var transcoder: AACTranscoder?
        if let audio, let firstAudio, AACTranscoder.needed(for: audio.source.codecID) {
            transcoder = AACTranscoder(audio, firstFrame: firstAudio.data, origin: firstAudio.time)
        }
        let (boundaries, durations, indexed) = try plan(header, video: videoTrack)
        return HLSRemuxer(source: source, header: header, video: video, audio: audio, castAudio: transcoder,
                          audioOrigin: firstAudio?.time ?? 0, boundaries: boundaries, durations: durations, indexed: indexed)
    }

    private init(source: ByteSource, header: MKVHeader, video: TrackPlan, audio: TrackPlan?, castAudio: AACTranscoder?,
                 audioOrigin: Int64, boundaries: [Boundary], durations: [Double], indexed: Bool) {
        self.source = source
        self.header = header
        self.video = video
        self.audio = audio
        self.audioOrigin = audioOrigin
        self.boundaries = boundaries
        self.durations = durations
        self.indexed = indexed
        initSegment = MP4.initSegment([video] + (audio.map { [$0] } ?? []))
        self.castAudio = castAudio
        if let castAudio, let audio {
            let aac = TrackPlan(source: audio.source, isVideo: false, timescale: UInt32(castAudio.rate), sampleEntry: castAudio.sampleEntry,
                                codecName: "AAC", frameDuration: .fixed(1024), displayWidth: 0, displayHeight: 0)
            castInitSegment = MP4.initSegment([video, aac])
        } else {
            castInitSegment = initSegment
        }
    }

    private static func score(_ t: MKVTrack, _ preferred: MKVTrack?) -> Int {
        var s = 0
        if t.isDefault { s += 4 }
        if let preferred, t.language == preferred.language { s += 2 }
        if !(t.name ?? "").lowercased().contains("comment") { s += 1 }
        return s
    }

    /// Segments from the index: its video keyframes, about six seconds
    /// apart. Without one, even byte ranges of the file, timed by its length.
    static func plan(_ header: MKVHeader, video: MKVTrack) throws -> ([Boundary], [Double], Bool) {
        let videoCues = header.cues.filter { $0.track == video.number }
        let cues = (videoCues.isEmpty ? header.cues : videoCues).sorted { $0.time < $1.time }
        var boundaries: [Boundary] = []
        var times: [Int64] = []
        for c in cues where c.position >= header.firstCluster && c.position < header.segmentEnd {
            if let last = times.last, c.time - last < targetSegment || c.position <= boundaries[boundaries.count - 1].position {
                continue
            }
            boundaries.append(Boundary(position: c.position, time: c.time))
            times.append(c.time)
        }
        if boundaries.count >= 2 {
            // The first segment starts with the first keyframe, wherever the
            // index says it is.
            boundaries[0] = Boundary(position: header.firstCluster, time: nil)
            var durations = zip(times.dropFirst(), times).map { Double($0 - $1) / 1e9 }
            let total = header.duration ?? (Double(times[times.count - 1]) / 1e9 + 6)
            durations.append(max(0.5, total - Double(times[times.count - 1]) / 1e9))
            return (boundaries, durations.map { max(0.1, $0) }, true)
        }
        guard let duration = header.duration, duration > 0 else { throw RemuxError.noIndex }
        // Long guesses, so a keyframe interval rarely spans a whole segment.
        let count = max(1, Int((duration / 10).rounded()))
        let span = header.segmentEnd - header.firstCluster
        let guesses = (0..<count).map { Boundary(position: header.firstCluster + span * Int64($0) / Int64(count), time: nil) }
        return (guesses, Array(repeating: duration / Double(count), count: count), false)
    }

    // MARK: - Serving

    public var playlist: String {
        let target = Int((durations.max() ?? 6).rounded(.up))
        var s = """
        #EXTM3U
        #EXT-X-VERSION:7
        #EXT-X-TARGETDURATION:\(target)
        #EXT-X-MEDIA-SEQUENCE:0
        #EXT-X-PLAYLIST-TYPE:VOD
        #EXT-X-INDEPENDENT-SEGMENTS
        #EXT-X-MAP:URI="init.mp4"

        """
        for (i, d) in durations.enumerated() {
            s += String(format: "#EXTINF:%.3f,\n%d.m4s\n", d, i)
        }
        s += "#EXT-X-ENDLIST\n"
        return s
    }

    /// "H.264 1920×1080, AC-3 6 ch, 412 segments".
    public var summary: String {
        var parts = ["\(video.codecName) \(video.source.width)×\(video.source.height)"]
        if let audio { parts.append("\(audio.codecName) \(audio.source.channels) ch") }
        parts.append("\(boundaries.count) \(indexed ? "indexed" : "estimated") segments")
        return parts.joined(separator: ", ")
    }

    /// Answers a request for `index.m3u8`, `init.mp4` or `<n>.m4s`, or the
    /// same under `cast/`, for a Chromecast.
    public func respond(to path: String) async throws -> (contentType: String, body: Data)? {
        let parts = path.split(separator: "/")
        let name = parts.last.map(String.init) ?? ""
        let cast = parts.dropLast().last == "cast"
        switch name {
        case "index.m3u8":
            return ("application/vnd.apple.mpegurl", Data(playlist.utf8))
        case "init.mp4":
            return ("video/mp4", cast ? castInitSegment : initSegment)
        default:
            guard name.hasSuffix(".m4s"), let i = Int(name.dropLast(4)), boundaries.indices.contains(i) else { return nil }
            return ("video/iso.segment", try await segment(i, cast: cast))
        }
    }

    public var segmentCount: Int { boundaries.count }

    /// Whether a Chromecast gets different audio than the Mac plays.
    public var transcodesForCast: Bool { castAudio != nil }

    public func segment(_ i: Int, cast: Bool = false) async throws -> Data {
        let transcode = cast && castAudio != nil
        return try await cache.data(transcode ? -1 - i : i) { [self] in try await makeSegment(i, transcode: transcode) }
    }

    // MARK: - Segments

    private func makeSegment(_ index: Int, transcode: Bool = false) async throws -> Data {
        let start = boundaries[index]
        let next = boundaries.indices.contains(index + 1) ? boundaries[index + 1] : nil
        let r = EBMLReader(source, at: start.position, chunk: 1 << 20)
        defer { r.close() }
        if !indexed && index > 0 {
            guard try await r.syncToCluster(end: header.segmentEnd) else { return MP4.fragment(sequence: UInt32(index + 1), tracks: []) }
        }
        let videoNumber = video.source.number
        let audioNumber = audio?.source.number
        let videoPrefix = video.source.strippedHeader ?? Data()
        let audioPrefix = audio?.source.strippedHeader ?? Data()
        var frames: [(time: Int64, key: Bool, data: Data)] = []
        var sounds: [(time: Int64, data: Data)] = []
        var startTime: Int64?
        var stopTime: Int64?
        var audioPastStop = audioNumber == nil
        var clustersAfterStop = 0
        // AAC for a Chromecast starts a little after each keyframe and needs a
        // little past the end to finish its last frame.
        let transcoder = transcode ? castAudio : nil
        let tail = transcoder.map { $0.lead + 150_000_000 } ?? 0

        while let c = try await r.nextCluster(scale: header.timestampScale, end: header.segmentEnd) {
            for b in c.blocks {
                if b.track == videoNumber {
                    if startTime == nil {
                        guard b.keyframe, start.matches(cluster: c.position, time: b.time) else { continue }
                        startTime = b.time
                    }
                    // The next segment's first keyframe ends this one; it can
                    // be this one's own when a keyframe interval spans both.
                    if stopTime == nil, let next, b.keyframe, next.matches(cluster: c.position, time: b.time) {
                        stopTime = b.time
                    }
                    guard stopTime == nil else { continue }
                    for (k, f) in b.frames.enumerated() {
                        frames.append((b.time + Int64(k) * (video.source.defaultDuration ?? 0), b.keyframe && k == 0, videoPrefix + f))
                    }
                } else if b.track == audioNumber {
                    for f in b.frames { sounds.append((b.time, audioPrefix + f)) }
                    if let stopTime, b.time >= stopTime + tail { audioPastStop = true }
                }
            }
            if stopTime != nil {
                // Audio can trail the video it plays with by a little.
                clustersAfterStop += 1
                if audioPastStop || clustersAfterStop >= (tail > 0 ? 3 : 2) { break }
            }
        }

        var tracks: [FragmentTrack] = []
        if !frames.isEmpty { tracks.append(videoFragment(frames)) }
        if let transcoder {
            if index == 0 || startTime != nil {
                let from = index == 0 ? Int64.min : startTime! + transcoder.lead
                let to = stopTime.map { $0 + transcoder.lead }
                let window = from == .min ? sounds : sounds.filter { $0.time >= from - transcoder.lead - 100_000_000 }
                if let track = try transcoder.encode(window, from: from, to: to) { tracks.append(track) }
            }
        } else {
            // Audio by time: from this segment's first keyframe (or the start
            // of the file) to the next segment's.
            let audioFrom = index == 0 ? Int64.min : (startTime ?? .max)
            let audioTo = stopTime ?? .max
            sounds = sounds.filter { $0.time >= audioFrom && $0.time < audioTo }
            if let audio, !sounds.isEmpty { tracks.append(audioFragment(sounds, audio, id: 2)) }
        }
        return MP4.fragment(sequence: UInt32(index + 1), tracks: tracks)
    }

    /// Nanoseconds in a timescale, rounded. Safe for a day of 90 kHz video.
    static func ticks(_ ns: Int64, _ timescale: UInt32) -> Int64 {
        let scaled = ns * Int64(timescale)
        return (scaled >= 0 ? scaled + 500_000_000 : scaled - 500_000_000) / 1_000_000_000
    }

    /// Matroska stores presentation times in decode order. Decode times are
    /// those same times sorted, and each frame's offset is the difference,
    /// negative for a frame shown before it's decoded (as CMAF does it): the
    /// earliest frame shows at the fragment's decode time, so video and audio
    /// share one timeline however a player reads the first fragment.
    private func videoFragment(_ frames: [(time: Int64, key: Bool, data: Data)]) -> FragmentTrack {
        let scale = video.timescale
        let sortedTimes = frames.map(\.time).sorted()
        let decode = sortedTimes.map { Self.ticks(max(0, $0), scale) }
        let deltas = zip(decode.dropFirst(), decode).map { $0 - $1 }
        let typical = video.source.defaultDuration.map { Self.ticks($0, scale) }
            ?? deltas.sorted().dropFirst(deltas.count / 2).first
            ?? Int64(scale) / 24
        var samples: [FragmentSample] = []
        for (j, f) in frames.enumerated() {
            let duration = j + 1 < decode.count ? decode[j + 1] - decode[j] : typical
            let offset = Self.ticks(max(0, f.time), scale) - decode[j]
            samples.append(FragmentSample(data: f.data, duration: UInt32(clamping: max(1, duration)),
                                          compositionOffset: Int32(clamping: offset), sync: f.key))
        }
        return FragmentTrack(id: 1, baseDecodeTime: UInt64(max(0, decode[0])), samples: samples)
    }

    /// Audio frames back to back, each as long as it decodes to, starting on
    /// the track's grid of whole frames. A real gap in the audio stays a gap.
    private func audioFragment(_ sounds: [(time: Int64, data: Data)], _ audio: TrackPlan, id: UInt32) -> FragmentTrack {
        let scale = audio.timescale
        let at = { (ns: Int64) in Self.ticks(ns, scale) }
        let frame = Int64(audio.frameDuration.samples(sounds[0].data) ?? 1024)
        let frameNS = max(1, frame * 1_000_000_000 / Int64(scale))
        let k = Int64((Double(sounds[0].time - audioOrigin) / Double(frameNS)).rounded())
        let base = max(0, at(audioOrigin) + k * frame)
        var position = base
        var samples: [FragmentSample] = []
        for (j, s) in sounds.enumerated() {
            var duration = Int64(audio.frameDuration.samples(s.data) ?? Int(frame))
            if j + 1 < sounds.count {
                let next = at(sounds[j + 1].time)
                if next - (position + duration) > 2 * duration { duration = next - position }
            }
            samples.append(FragmentSample(data: s.data, duration: UInt32(clamping: max(1, duration)), compositionOffset: 0, sync: true))
            position += duration
        }
        return FragmentTrack(id: id, baseDecodeTime: UInt64(base), samples: samples)
    }
}

/// Segments made or being made, so a repeated request doesn't make one
/// twice. One nobody waits for any more is stopped.
private actor SegmentCache {
    private struct Entry {
        let task: Task<Data, Error>
        var waiters: Int
    }

    private var entries: [Int: Entry] = [:]
    private var order: [Int] = []

    func data(_ i: Int, make: @escaping @Sendable () async throws -> Data) async throws -> Data {
        let task: Task<Data, Error>
        if let e = entries[i] {
            task = e.task
            entries[i]?.waiters += 1
        } else {
            task = Task { try await make() }
            entries[i] = Entry(task: task, waiters: 1)
            order.removeAll { $0 == i }
            order.append(i)
            while order.count > 6, let idle = order.firstIndex(where: { (entries[$0]?.waiters ?? 0) == 0 }) {
                entries[order.remove(at: idle)] = nil
            }
        }
        do {
            let data = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                Task { await self.abandon(i, task) }
            }
            leave(i, task, failed: false)
            return data
        } catch {
            leave(i, task, failed: true)
            throw error
        }
    }

    /// A failed segment is made afresh next time.
    private func leave(_ i: Int, _ task: Task<Data, Error>, failed: Bool) {
        guard entries[i]?.task == task else { return }
        entries[i]?.waiters -= 1
        if failed { entries[i] = nil }
    }

    private func abandon(_ i: Int, _ task: Task<Data, Error>) {
        guard let e = entries[i], e.task == task, e.waiters <= 1 else { return }
        task.cancel()
        entries[i] = nil
    }
}
