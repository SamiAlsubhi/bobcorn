import Foundation

/// A track as a Matroska file describes it.
public struct MKVTrack: Sendable, Hashable {
    public enum Kind: Sendable { case video, audio, other }

    /// Colour signalling for HDR and wide-gamut video.
    public struct Colour: Sendable, Hashable {
        var primaries: UInt64 = 2
        var transfer: UInt64 = 2
        var matrix: UInt64 = 2
        var range: UInt64 = 0
    }

    public var number: UInt64 = 0
    public var kind: Kind = .other
    public var codecID = ""
    public var codecPrivate: Data?
    /// Nanoseconds per frame, when constant.
    public var defaultDuration: Int64?
    public var isDefault = true
    public var isEnabled = true
    public var language: String?
    public var name: String?
    public var width = 0
    public var height = 0
    public var displayWidth: Int?
    public var displayHeight: Int?
    public var colour: Colour?
    public var sampleRate = 8000.0
    public var outputSampleRate: Double?
    public var channels = 1
    /// Bytes every frame starts with, stripped to save space (header
    /// stripping, the only compression muxers use for video and audio).
    public var strippedHeader: Data?
    /// zlib compression or encryption, which this doesn't undo.
    public var unsupportedEncoding = false
}

struct CuePoint: Sendable {
    /// Nanoseconds.
    let time: Int64
    let track: UInt64
    /// From the start of the file.
    let position: Int64
}

/// Everything before the first cluster, and the index at the end.
public struct MKVHeader: Sendable {
    public let timestampScale: Int64
    /// Seconds.
    public let duration: Double?
    public let tracks: [MKVTrack]
    let cues: [CuePoint]
    let firstCluster: Int64
    let segmentEnd: Int64
}

struct MKVBlock {
    let track: UInt64
    /// Presentation time in nanoseconds.
    let time: Int64
    let keyframe: Bool
    let frames: [Data]
}

struct MKVCluster {
    /// Where its element starts.
    let position: Int64
    let blocks: [MKVBlock]
}

enum Matroska {
    static let maxHeaderElement: Int64 = 64 << 20

    static func readHeader(_ source: ByteSource) async throws -> MKVHeader {
        let r = EBMLReader(source, at: 0, chunk: 64 << 10)
        defer { r.close() }
        guard let ebml = try await r.header(), ebml.id == ID.ebml, let ebmlSize = ebml.size, ebmlSize < 4096 else {
            throw RemuxError.notMatroska
        }
        let docType = EBML.children(try await r.bytes(Int(ebmlSize))).first { $0.id == ID.docType }.map { EBML.string($0.body) }
        guard docType == nil || docType == "matroska" || docType == "webm" else { throw RemuxError.notMatroska }
        guard let segment = try await r.header(), segment.id == ID.segment else { throw RemuxError.notMatroska }
        let segmentStart = r.position
        let segmentEnd = segment.size.map { min(source.length, segmentStart + $0) } ?? source.length

        var seen: [UInt32: Data] = [:]
        var seekPositions: [UInt32: Int64] = [:]
        var parsedSeekHeads = Set<Int64>()
        var firstCluster: Int64?

        func record(_ id: UInt32, _ body: Data, at position: Int64) {
            if id == ID.seekHead {
                parsedSeekHeads.insert(position)
                for (id, pos) in seekHead(body, segmentStart: segmentStart) where seekPositions[id] == nil || id == ID.seekHead {
                    seekPositions[id] = pos
                }
            } else if seen[id] == nil {
                seen[id] = body
            }
        }

        // The top-level elements up to the first cluster.
        while r.position < segmentEnd {
            let start = r.position
            guard let h = try await r.header() else { break }
            if h.id == ID.cluster {
                firstCluster = start
                break
            }
            guard let size = h.size else { throw RemuxError.malformed("an element of unknown size before the video") }
            if [ID.seekHead, ID.info, ID.tracks, ID.cues].contains(h.id) {
                guard size < maxHeaderElement else { throw RemuxError.malformed("an oversized header") }
                record(h.id, try await r.bytes(Int(size)), at: start)
            } else {
                r.skip(size)
            }
        }

        // What isn't up front is wherever the seek head says: often the cues,
        // at the end, sometimes behind a second seek head.
        func load(_ id: UInt32) async throws {
            guard let pos = seekPositions[id], pos < source.length, !parsedSeekHeads.contains(pos) else { return }
            r.seek(pos)
            guard let h = try await r.header(), h.id == id, let size = h.size, size < maxHeaderElement else { return }
            record(id, try await r.bytes(Int(size)), at: pos)
        }
        try await load(ID.seekHead)
        for id in [ID.info, ID.tracks, ID.cues] where seen[id] == nil { try await load(id) }

        guard let trackList = seen[ID.tracks] else { throw RemuxError.malformed("no track list") }
        guard let firstCluster else { throw RemuxError.malformed("no video data") }
        var scale: Int64 = 1_000_000
        var duration: Double?
        for c in EBML.children(seen[ID.info] ?? Data()) {
            if c.id == ID.timestampScale { scale = max(1, Int64(clamping: EBML.uint(c.body))) }
            if c.id == ID.duration, let d = EBML.float(c.body), d > 0 { duration = d }
        }
        return MKVHeader(
            timestampScale: scale,
            duration: duration.map { $0 * Double(scale) / 1e9 },
            tracks: tracks(trackList),
            cues: seen[ID.cues].map { cues($0, segmentStart: segmentStart, scale: scale) } ?? [],
            firstCluster: firstCluster,
            segmentEnd: segmentEnd
        )
    }

    static func seekHead(_ body: Data, segmentStart: Int64) -> [(UInt32, Int64)] {
        EBML.children(body).filter { $0.id == ID.seek }.compactMap { seek in
            var id: UInt32?
            var pos: Int64?
            for c in EBML.children(seek.body) {
                if c.id == ID.seekID { id = UInt32(truncatingIfNeeded: EBML.uint(c.body)) }
                if c.id == ID.seekPosition { pos = segmentStart + Int64(clamping: EBML.uint(c.body)) }
            }
            guard let id, let pos else { return nil }
            return (id, pos)
        }
    }

    static func tracks(_ body: Data) -> [MKVTrack] {
        EBML.children(body).filter { $0.id == ID.trackEntry }.map { entry in
            var t = MKVTrack()
            for c in EBML.children(entry.body) {
                switch c.id {
                case ID.trackNumber: t.number = EBML.uint(c.body)
                case ID.trackType:
                    switch EBML.uint(c.body) {
                    case 1: t.kind = .video
                    case 2: t.kind = .audio
                    default: t.kind = .other
                    }
                case ID.flagEnabled: t.isEnabled = EBML.uint(c.body) != 0
                case ID.flagDefault: t.isDefault = EBML.uint(c.body) != 0
                case ID.defaultDuration: t.defaultDuration = Int64(clamping: EBML.uint(c.body))
                case ID.name: t.name = EBML.string(c.body)
                case ID.language: t.language = EBML.string(c.body)
                case ID.codecID: t.codecID = EBML.string(c.body)
                case ID.codecPrivate: t.codecPrivate = Data(c.body)
                case ID.video:
                    for v in EBML.children(c.body) {
                        switch v.id {
                        case ID.pixelWidth: t.width = Int(clamping: EBML.uint(v.body))
                        case ID.pixelHeight: t.height = Int(clamping: EBML.uint(v.body))
                        case ID.displayWidth: t.displayWidth = Int(clamping: EBML.uint(v.body))
                        case ID.displayHeight: t.displayHeight = Int(clamping: EBML.uint(v.body))
                        case ID.displayUnit:
                            // Only pixels give an aspect ratio worth keeping.
                            if EBML.uint(v.body) != 0 { t.displayWidth = nil; t.displayHeight = nil }
                        case ID.colour:
                            var colour = MKVTrack.Colour()
                            for k in EBML.children(v.body) {
                                switch k.id {
                                case ID.primaries: colour.primaries = EBML.uint(k.body)
                                case ID.transferCharacteristics: colour.transfer = EBML.uint(k.body)
                                case ID.matrixCoefficients: colour.matrix = EBML.uint(k.body)
                                case ID.range: colour.range = EBML.uint(k.body)
                                default: break
                                }
                            }
                            t.colour = colour
                        default: break
                        }
                    }
                case ID.audio:
                    for a in EBML.children(c.body) {
                        switch a.id {
                        case ID.samplingFrequency: t.sampleRate = EBML.float(a.body) ?? t.sampleRate
                        case ID.outputSamplingFrequency: t.outputSampleRate = EBML.float(a.body)
                        case ID.channels: t.channels = max(1, Int(clamping: EBML.uint(a.body)))
                        default: break
                        }
                    }
                case ID.contentEncodings:
                    for encoding in EBML.children(c.body) where encoding.id == ID.contentEncoding {
                        for e in EBML.children(encoding.body) {
                            if e.id == ID.contentEncryption { t.unsupportedEncoding = true }
                            guard e.id == ID.contentCompression else { continue }
                            var algorithm: UInt64 = 0 // zlib, when unstated
                            var settings = Data()
                            for k in EBML.children(e.body) {
                                if k.id == ID.contentCompAlgo { algorithm = EBML.uint(k.body) }
                                if k.id == ID.contentCompSettings { settings = Data(k.body) }
                            }
                            if algorithm == 3 { t.strippedHeader = settings } else { t.unsupportedEncoding = true }
                        }
                    }
                default: break
                }
            }
            return t
        }
    }

    static func cues(_ body: Data, segmentStart: Int64, scale: Int64) -> [CuePoint] {
        var out: [CuePoint] = []
        for point in EBML.children(body) where point.id == ID.cuePoint {
            var time: Int64?
            var positions: [(UInt64, Int64)] = []
            for c in EBML.children(point.body) {
                if c.id == ID.cueTime { time = Int64(clamping: EBML.uint(c.body)) * scale }
                guard c.id == ID.cueTrackPositions else { continue }
                var track: UInt64?
                var pos: Int64?
                for p in EBML.children(c.body) {
                    if p.id == ID.cueTrack { track = EBML.uint(p.body) }
                    if p.id == ID.cueClusterPosition { pos = segmentStart + Int64(clamping: EBML.uint(p.body)) }
                }
                if let track, let pos { positions.append((track, pos)) }
            }
            if let time {
                for (track, pos) in positions { out.append(CuePoint(time: time, track: track, position: pos)) }
            }
        }
        return out
    }

    /// A SimpleBlock or Block, split into its frames.
    static func block(_ d: Data, simple: Bool, hasReference: Bool, clusterTime: Int64, scale: Int64) -> MKVBlock? {
        guard let (number, numberLength) = EBML.vint(d, d.startIndex), let track = number else { return nil }
        var i = d.startIndex + numberLength
        guard i + 3 <= d.endIndex else { return nil }
        let relative = Int64(Int16(bitPattern: UInt16(d[i]) << 8 | UInt16(d[i + 1])))
        let flags = d[i + 2]
        i += 3
        let keyframe = simple ? flags & 0x80 != 0 : !hasReference
        let lacing = (flags >> 1) & 0x03
        var frames: [Data] = []
        if lacing == 0 {
            frames = [Data(d[i...])]
        } else {
            guard i < d.endIndex else { return nil }
            let count = Int(d[i]) + 1
            i += 1
            var sizes: [Int] = []
            switch lacing {
            case 1: // Xiph
                for _ in 0..<count - 1 {
                    var size = 0
                    while true {
                        guard i < d.endIndex else { return nil }
                        let b = d[i]
                        i += 1
                        size += Int(b)
                        if b != 255 { break }
                    }
                    sizes.append(size)
                }
            case 3: // EBML: a size, then signed differences
                guard count > 1 else { break }
                guard let (first, length) = EBML.vint(d, i), let firstSize = first else { return nil }
                i += length
                sizes.append(Int(clamping: firstSize))
                for _ in 0..<count - 2 {
                    guard let (raw, length) = EBML.vint(d, i), let value = raw else { return nil }
                    i += length
                    let bias = (Int64(1) << (7 * length - 1)) - 1
                    sizes.append(sizes[sizes.count - 1] + Int(Int64(value) - bias))
                }
            default: // fixed
                let each = (d.endIndex - i) / count
                sizes = Array(repeating: each, count: count - 1)
            }
            var start = i
            for size in sizes {
                guard size >= 0, start + size <= d.endIndex else { return nil }
                frames.append(Data(d[start..<start + size]))
                start += size
            }
            guard start <= d.endIndex else { return nil }
            frames.append(Data(d[start...]))
        }
        return MKVBlock(track: track, time: (clusterTime + relative) * scale, keyframe: keyframe, frames: frames)
    }
}

extension EBMLReader {
    /// The next cluster from the position, past anything else. Nil at the
    /// end of the segment.
    func nextCluster(scale: Int64, end: Int64) async throws -> MKVCluster? {
        while position < end {
            let start = position
            guard let h = try await header() else { return nil }
            guard h.id == ID.cluster else {
                guard let size = h.size else { return nil }
                skip(size)
                continue
            }
            var clusterTime: Int64 = 0
            var raw: [(body: Data, simple: Bool, reference: Bool)] = []
            func take(_ id: UInt32, _ body: Data) {
                switch id {
                case ID.timestamp:
                    clusterTime = Int64(clamping: EBML.uint(body))
                case ID.simpleBlock:
                    raw.append((body, true, false))
                case ID.blockGroup:
                    var block: Data?
                    var reference = false
                    for c in EBML.children(body) {
                        if c.id == ID.block { block = c.body }
                        if c.id == ID.referenceBlock { reference = true }
                    }
                    if let block { raw.append((block, false, reference)) }
                default:
                    break
                }
            }
            if let size = h.size {
                for c in EBML.children(try await bytes(Int(clamping: size))) { take(c.id, c.body) }
            } else {
                // A cluster of unknown size ends where the next top-level
                // element starts.
                while position < end {
                    let at = position
                    guard let child = try await header() else { break }
                    if ID.topLevel.contains(child.id) {
                        seek(at)
                        break
                    }
                    guard let size = child.size else { throw RemuxError.malformed("a block of unknown size") }
                    take(child.id, try await bytes(Int(clamping: size)))
                }
            }
            let blocks = raw.compactMap {
                Matroska.block($0.body, simple: $0.simple, hasReference: $0.reference, clusterTime: clusterTime, scale: scale)
            }
            return MKVCluster(position: start, blocks: blocks)
        }
        return nil
    }

    /// Moves to the first cluster that starts at or after the position, for
    /// a guess at a byte offset. False if there is none.
    func syncToCluster(end: Int64) async throws -> Bool {
        while let at = try await find([0x1F, 0x43, 0xB6, 0x75], limit: end - position) {
            seek(at)
            // A real cluster starts with its timestamp, or a checksum first.
            if let h = try? await header(), h.id == ID.cluster, try await fill(1) {
                let child = try await bytes(1)[0]
                if child == 0xE7 || child == 0xBF {
                    seek(at)
                    return true
                }
            }
            seek(at + 1)
        }
        return false
    }
}
