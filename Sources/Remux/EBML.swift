import Foundation

/// Random access to a file that may still be arriving, such as a torrent's.
/// Reads made under one stream ID belong to one reader, so a source can
/// prioritize what that reader will want next.
public protocol ByteSource: Sendable {
    var length: Int64 { get }
    /// Up to `count` bytes at `offset`. May return fewer; returns none only
    /// at the end of the file.
    func read(at offset: Int64, count: Int, stream: UUID) async throws -> Data
    /// The reader is done.
    func finish(stream: UUID)
}

/// A file on disk.
public struct FileByteSource: ByteSource {
    public let url: URL
    public let length: Int64

    public init(url: URL) throws {
        self.url = url
        length = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
    }

    public func read(at offset: Int64, count: Int, stream: UUID) async throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(offset))
        return try handle.read(upToCount: count) ?? Data()
    }

    public func finish(stream: UUID) {}
}

public enum RemuxError: LocalizedError, Equatable {
    case notMatroska
    case malformed(String)
    case noVideo
    case unsupportedVideo(String)
    case unsupportedAudio(String)
    case encrypted
    case noIndex

    public var errorDescription: String? {
        switch self {
        case .notMatroska: return "the file isn't a Matroska file"
        case .malformed(let why): return "the file is damaged (\(why))"
        case .noVideo: return "the file has no video track"
        case .unsupportedVideo(let codec): return "its \(codec) video can't be decoded by macOS"
        case .unsupportedAudio(let codec): return "its \(codec) audio can't be decoded by macOS"
        case .encrypted: return "the file is encrypted"
        case .noIndex: return "the file has no duration or index to seek with"
        }
    }
}

/// Element IDs, with their length markers, as Matroska writes them.
enum ID {
    static let ebml: UInt32 = 0x1A45DFA3
    static let docType: UInt32 = 0x4282
    static let segment: UInt32 = 0x18538067

    static let seekHead: UInt32 = 0x114D9B74
    static let seek: UInt32 = 0x4DBB
    static let seekID: UInt32 = 0x53AB
    static let seekPosition: UInt32 = 0x53AC

    static let info: UInt32 = 0x1549A966
    static let timestampScale: UInt32 = 0x2AD7B1
    static let duration: UInt32 = 0x4489

    static let tracks: UInt32 = 0x1654AE6B
    static let trackEntry: UInt32 = 0xAE
    static let trackNumber: UInt32 = 0xD7
    static let trackType: UInt32 = 0x83
    static let flagEnabled: UInt32 = 0xB9
    static let flagDefault: UInt32 = 0x88
    static let defaultDuration: UInt32 = 0x23E383
    static let name: UInt32 = 0x536E
    static let language: UInt32 = 0x22B59C
    static let codecID: UInt32 = 0x86
    static let codecPrivate: UInt32 = 0x63A2
    static let video: UInt32 = 0xE0
    static let pixelWidth: UInt32 = 0xB0
    static let pixelHeight: UInt32 = 0xBA
    static let displayWidth: UInt32 = 0x54B0
    static let displayHeight: UInt32 = 0x54BA
    static let displayUnit: UInt32 = 0x54B2
    static let colour: UInt32 = 0x55B0
    static let matrixCoefficients: UInt32 = 0x55B1
    static let range: UInt32 = 0x55B9
    static let transferCharacteristics: UInt32 = 0x55BA
    static let primaries: UInt32 = 0x55BB
    static let audio: UInt32 = 0xE1
    static let samplingFrequency: UInt32 = 0xB5
    static let outputSamplingFrequency: UInt32 = 0x78B5
    static let channels: UInt32 = 0x9F
    static let contentEncodings: UInt32 = 0x6D80
    static let contentEncoding: UInt32 = 0x6240
    static let contentCompression: UInt32 = 0x5034
    static let contentCompAlgo: UInt32 = 0x4254
    static let contentCompSettings: UInt32 = 0x4255
    static let contentEncryption: UInt32 = 0x5035

    static let cues: UInt32 = 0x1C53BB6B
    static let cuePoint: UInt32 = 0xBB
    static let cueTime: UInt32 = 0xB3
    static let cueTrackPositions: UInt32 = 0xB7
    static let cueTrack: UInt32 = 0xF7
    static let cueClusterPosition: UInt32 = 0xF1

    static let cluster: UInt32 = 0x1F43B675
    static let timestamp: UInt32 = 0xE7
    static let simpleBlock: UInt32 = 0xA3
    static let blockGroup: UInt32 = 0xA0
    static let block: UInt32 = 0xA1
    static let referenceBlock: UInt32 = 0xFB
    static let crc32: UInt32 = 0xBF

    /// Children of a Segment. One of these ends a cluster of unknown size.
    static let topLevel: Set<UInt32> = [seekHead, info, tracks, cues, cluster, 0x1043A770, 0x1254C367, 0x1941A469]
}

/// Reads EBML values out of an element's body.
enum EBML {
    /// A variable-length integer at `i`: its value without the length marker,
    /// and its length. An all-ones value (an unknown size) comes back nil.
    static func vint(_ d: Data, _ i: Int) -> (value: UInt64?, length: Int)? {
        guard i < d.endIndex else { return nil }
        let first = d[i]
        guard first != 0 else { return nil }
        let length = first.leadingZeroBitCount + 1
        guard i + length <= d.endIndex else { return nil }
        var value = UInt64(first & (0xFF >> length))
        var allOnes = value == UInt64(0xFF >> length)
        for k in 1..<length {
            value = value << 8 | UInt64(d[i + k])
            if d[i + k] != 0xFF { allOnes = false }
        }
        return (allOnes ? nil : value, length)
    }

    /// An element ID at `i`, length marker kept.
    static func id(_ d: Data, _ i: Int) -> (id: UInt32, length: Int)? {
        guard i < d.endIndex, d[i] != 0 else { return nil }
        let length = d[i].leadingZeroBitCount + 1
        guard length <= 4, i + length <= d.endIndex else { return nil }
        var id: UInt32 = 0
        for k in 0..<length { id = id << 8 | UInt32(d[i + k]) }
        return (id, length)
    }

    /// The children of a master element's body.
    static func children(_ d: Data) -> [(id: UInt32, body: Data)] {
        var out: [(UInt32, Data)] = []
        var i = d.startIndex
        while let (id, idLength) = id(d, i), let (size, sizeLength) = vint(d, i + idLength) {
            let start = i + idLength + sizeLength
            let end = size.map { min(d.endIndex, start + Int(clamping: $0)) } ?? d.endIndex
            out.append((id, d[start..<end]))
            i = end
            if i >= d.endIndex { break }
        }
        return out
    }

    static func uint(_ d: Data) -> UInt64 {
        d.prefix(8).reduce(0) { $0 << 8 | UInt64($1) }
    }

    static func float(_ d: Data) -> Double? {
        switch d.count {
        case 4: return Double(Float(bitPattern: UInt32(truncatingIfNeeded: uint(d))))
        case 8: return Double(bitPattern: uint(d))
        default: return nil
        }
    }

    static func string(_ d: Data) -> String {
        String(decoding: d.prefix { $0 != 0 }, as: UTF8.self)
    }
}

/// Sequential reads through a ByteSource, a chunk at a time, under one
/// stream ID.
final class EBMLReader {
    let source: ByteSource
    private(set) var position: Int64
    private var buffer = Data()
    private var bufferStart: Int64 = 0
    private let stream = UUID()
    private let chunk: Int

    init(_ source: ByteSource, at position: Int64, chunk: Int = 256 << 10) {
        self.source = source
        self.position = position
        self.chunk = chunk
    }

    func close() {
        source.finish(stream: stream)
    }

    var atEnd: Bool { position >= source.length }

    func seek(_ to: Int64) { position = to }
    func skip(_ n: Int64) { position += n }

    /// Makes `n` bytes from the position available; false if the file ends
    /// first.
    @discardableResult
    func fill(_ n: Int) async throws -> Bool {
        let bufferEnd = bufferStart + Int64(buffer.count)
        if position >= bufferStart && bufferEnd - position >= Int64(n) { return true }
        if position >= bufferStart && position <= bufferEnd {
            buffer = buffer.subdata(in: buffer.startIndex + Int(position - bufferStart)..<buffer.endIndex)
        } else {
            buffer = Data()
        }
        bufferStart = position
        while buffer.count < n {
            let at = bufferStart + Int64(buffer.count)
            guard at < source.length else { return false }
            try Task.checkCancellation()
            let want = Int(min(Int64(max(n - buffer.count, chunk)), source.length - at))
            let data = try await source.read(at: at, count: want, stream: stream)
            guard !data.isEmpty else { return false }
            buffer.append(data)
        }
        return true
    }

    /// The buffered bytes from the position on; call `fill` first.
    private var available: Data {
        buffer[(buffer.startIndex + Int(position - bufferStart))...]
    }

    func bytes(_ n: Int) async throws -> Data {
        guard try await fill(n) else { throw RemuxError.malformed("it ends early") }
        let start = buffer.startIndex + Int(position - bufferStart)
        position += Int64(n)
        return buffer.subdata(in: start..<start + n)
    }

    /// The element header at the position, which it moves past. Nil at the
    /// end of the file; a nil size is an unknown size.
    func header() async throws -> (id: UInt32, size: Int64?)? {
        guard try await fill(1) else { return nil }
        try await fill(12)
        let d = available
        guard let (id, idLength) = EBML.id(d, d.startIndex),
              let (size, sizeLength) = EBML.vint(d, d.startIndex + idLength)
        else { throw RemuxError.malformed("bad element header at \(position)") }
        position += Int64(idLength + sizeLength)
        return (id, size.map { Int64(clamping: $0) })
    }

    /// Looks ahead for the next byte offset where `pattern` starts.
    func find(_ pattern: [UInt8], limit: Int64) async throws -> Int64? {
        let end = min(source.length, position + limit)
        while position < end {
            guard try await fill(min(chunk, Int(end - position))) else { return nil }
            let d = available
            if let r = d.range(of: Data(pattern)) { return position + Int64(r.lowerBound - d.startIndex) }
            guard d.count >= pattern.count else { return nil }
            position += Int64(d.count - pattern.count + 1)
        }
        return nil
    }
}
