import Foundation

public enum TorrentError: Error, LocalizedError, Sendable {
    case invalidMetainfo(String)
    case invalidMagnet
    case stopped
    case noSuchFile
    case storage(String)
    case tracker(String)
    case timedOut

    public var errorDescription: String? {
        switch self {
        case .invalidMetainfo(let why): return "Not a valid torrent: \(why)"
        case .invalidMagnet: return "Not a valid magnet link"
        case .stopped: return "The torrent was stopped"
        case .noSuchFile: return "That file is not in the torrent"
        case .storage(let why): return "Cache error: \(why)"
        case .tracker(let why): return "Tracker error: \(why)"
        case .timedOut: return "Timed out"
        }
    }
}

public struct TorrentFile: Hashable, Sendable, Identifiable {
    public let index: Int
    /// Path inside the torrent, without the torrent's own name.
    public let path: [String]
    public let length: Int64
    /// Byte offset of this file in the torrent's concatenated data.
    public let offset: Int64
    /// BEP 47 padding: zeros that align the next file to a piece boundary.
    public let isPadding: Bool

    public var id: Int { index }
    public var name: String { path.last ?? "" }
    public var displayPath: String { path.joined(separator: "/") }
    public var fileExtension: String { (name as NSString).pathExtension.lowercased() }

    public var isVideo: Bool {
        ["mp4", "m4v", "mov", "mkv", "webm", "avi", "mpg", "mpeg", "ogv", "ts", "wmv", "flv"].contains(fileExtension)
    }

    /// Formats AVFoundation can play natively.
    public var isNativelyPlayable: Bool { ["mp4", "m4v", "mov"].contains(fileExtension) }

    public var isSubtitle: Bool { ["srt", "vtt"].contains(fileExtension) }
}

public struct TorrentInfo: Sendable {
    public let infoHash: [UInt8]
    public let name: String
    public let pieceLength: Int
    public let pieceHashes: [[UInt8]]
    public let files: [TorrentFile]
    public let totalLength: Int64
    public let isPrivate: Bool
    public let isMultiFile: Bool
    public let rawInfo: [UInt8]

    public var pieceCount: Int { pieceHashes.count }
    public var infoHashHex: String { infoHash.hexString }

    public init(rawInfo: [UInt8]) throws {
        let value: BValue
        do { value = try Bencode.decode(rawInfo) } catch { throw TorrentError.invalidMetainfo("\(error)") }
        guard let d = value.dictValue else { throw TorrentError.invalidMetainfo("info is not a dictionary") }
        guard let name = d["name.utf-8"]?.stringValue ?? d["name"]?.stringValue else {
            throw TorrentError.invalidMetainfo("missing name")
        }
        guard let pl = d["piece length"]?.intValue, pl > 0, pl <= 128 * 1024 * 1024 else {
            throw TorrentError.invalidMetainfo("bad piece length")
        }
        guard let pieces = d["pieces"]?.bytesValue, pieces.count % 20 == 0 else {
            throw TorrentError.invalidMetainfo("missing piece hashes (BitTorrent v2-only torrents are not supported)")
        }

        var files: [TorrentFile] = []
        var offset: Int64 = 0
        if let length = d["length"]?.intValue {
            guard length >= 0 else { throw TorrentError.invalidMetainfo("negative length") }
            files.append(TorrentFile(index: 0, path: [name], length: length, offset: 0, isPadding: false))
            offset = length
            isMultiFile = false
        } else if let list = d["files"]?.listValue {
            for (i, entry) in list.enumerated() {
                guard let length = entry["length"]?.intValue, length >= 0 else {
                    throw TorrentError.invalidMetainfo("file \(i) has no length")
                }
                let rawPath = entry["path.utf-8"]?.listValue ?? entry["path"]?.listValue ?? []
                let path = rawPath.compactMap { $0.stringValue }
                guard !path.isEmpty else { throw TorrentError.invalidMetainfo("file \(i) has no path") }
                let attr = entry["attr"]?.stringValue ?? ""
                let padding = attr.contains("p") || path.last?.hasPrefix(".____padding_file") == true
                files.append(TorrentFile(index: i, path: path, length: length, offset: offset, isPadding: padding))
                offset += length
            }
            isMultiFile = true
        } else {
            throw TorrentError.invalidMetainfo("no files")
        }

        let expected = Int((offset + pl - 1) / pl)
        guard pieces.count / 20 == expected else {
            throw TorrentError.invalidMetainfo("piece count \(pieces.count / 20) does not match length (expected \(expected))")
        }

        self.name = name
        self.pieceLength = Int(pl)
        self.pieceHashes = stride(from: 0, to: pieces.count, by: 20).map { Array(pieces[$0..<$0 + 20]) }
        self.files = files
        self.totalLength = offset
        self.isPrivate = d["private"]?.intValue == 1
        self.rawInfo = rawInfo
        self.infoHash = SHA1Digest.hash(rawInfo)
    }

    public func pieceSize(_ index: Int) -> Int {
        if index == pieceCount - 1 {
            let rem = Int(totalLength - Int64(index) * Int64(pieceLength))
            return rem
        }
        return pieceLength
    }

    public func pieceOffset(_ index: Int) -> Int64 { Int64(index) * Int64(pieceLength) }

    /// Pieces that hold any byte of the file, or nil for an empty file.
    public func pieceRange(for file: TorrentFile) -> ClosedRange<Int>? {
        guard file.length > 0 else { return nil }
        let first = Int(file.offset / Int64(pieceLength))
        let last = Int((file.offset + file.length - 1) / Int64(pieceLength))
        return first...last
    }

    public func piece(containing torrentOffset: Int64) -> Int {
        Int(torrentOffset / Int64(pieceLength))
    }

    /// The real (non-padding) files, in torrent order.
    public var contentFiles: [TorrentFile] { files.filter { !$0.isPadding } }

    /// The largest video file, which is almost always the one to play.
    public var mainVideoFile: TorrentFile? {
        contentFiles.filter(\.isVideo).max { $0.length < $1.length }
    }

    struct Segment {
        let file: TorrentFile
        let fileOffset: Int64
        let length: Int
        let bufferOffset: Int
    }

    /// Splits a range of the torrent's data into the per-file pieces it covers.
    func segments(start: Int64, length: Int) -> [Segment] {
        var out: [Segment] = []
        let end = start + Int64(length)
        // Binary search for the first file whose end is past `start`.
        var lo = 0
        var hi = files.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if files[mid].offset + files[mid].length <= start { lo = mid + 1 } else { hi = mid }
        }
        var i = lo
        while i < files.count {
            let f = files[i]
            if f.offset >= end { break }
            if f.length > 0 {
                let s = max(start, f.offset)
                let e = min(end, f.offset + f.length)
                if e > s {
                    out.append(Segment(file: f, fileOffset: s - f.offset, length: Int(e - s), bufferOffset: Int(s - start)))
                }
            }
            i += 1
        }
        return out
    }
}

public struct Metainfo: Sendable {
    public let info: TorrentInfo
    public let trackers: [String]
    public let webSeeds: [String]

    public init(data: Data) throws {
        let bytes = [UInt8](data)
        var decoder = BencodeDecoder(bytes)
        let root: BValue
        do { root = try decoder.decodeValue() } catch { throw TorrentError.invalidMetainfo("\(error)") }
        guard let range = decoder.infoRange else { throw TorrentError.invalidMetainfo("no info dictionary") }
        info = try TorrentInfo(rawInfo: Array(bytes[range]))

        var trackers: [String] = []
        if let tiers = root["announce-list"]?.listValue {
            for tier in tiers {
                for t in tier.listValue ?? [] {
                    if let s = t.stringValue, !trackers.contains(s) { trackers.append(s) }
                }
            }
        }
        if let a = root["announce"]?.stringValue, !trackers.contains(a) { trackers.insert(a, at: 0) }
        self.trackers = trackers

        var seeds: [String] = []
        if let one = root["url-list"]?.stringValue, !one.isEmpty {
            seeds.append(one)
        } else if let list = root["url-list"]?.listValue {
            seeds = list.compactMap { $0.stringValue }.filter { !$0.isEmpty }
        }
        webSeeds = seeds
    }

    public init(info: TorrentInfo, trackers: [String], webSeeds: [String]) {
        self.info = info
        self.trackers = trackers
        self.webSeeds = webSeeds
    }
}

public struct MagnetLink: Sendable, Hashable {
    public let infoHash: [UInt8]
    public var displayName: String?
    public var trackers: [String]
    public var webSeeds: [String]
    public var peers: [PeerAddress]

    public init(infoHash: [UInt8], displayName: String? = nil, trackers: [String] = [], webSeeds: [String] = [], peers: [PeerAddress] = []) {
        self.infoHash = infoHash
        self.displayName = displayName
        self.trackers = trackers
        self.webSeeds = webSeeds
        self.peers = peers
    }

    public init(string: String) throws {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix("magnet:?") else { throw TorrentError.invalidMagnet }
        var hash: [UInt8]?
        var name: String?
        var trackers: [String] = []
        var seeds: [String] = []
        var peers: [PeerAddress] = []
        for pair in trimmed.dropFirst("magnet:?".count).split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
            guard kv.count == 2 else { continue }
            let key = kv[0].lowercased()
            let raw = key == "dn" ? kv[1].replacingOccurrences(of: "+", with: " ") : kv[1]
            let value = raw.removingPercentEncoding ?? raw
            switch key {
            case "xt":
                let lower = value.lowercased()
                guard lower.hasPrefix("urn:btih:") else { continue }
                let h = String(value.dropFirst("urn:btih:".count))
                if h.count == 40 {
                    hash = [UInt8](hex: h)
                } else if h.count == 32 {
                    hash = Base32.decode(h)
                }
            case "dn":
                name = value
            case "ws":
                seeds.append(value)
            case "x.pe":
                if let p = PeerAddress(hostPort: value) { peers.append(p) }
            default:
                if key == "tr" || key.hasPrefix("tr.") { trackers.append(value) }
            }
        }
        guard let infoHash = hash, infoHash.count == 20 else { throw TorrentError.invalidMagnet }
        self.infoHash = infoHash
        self.displayName = name
        self.trackers = trackers
        self.webSeeds = seeds
        self.peers = peers
    }

    public var infoHashHex: String { infoHash.hexString }

    public var uri: String {
        var s = "magnet:?xt=urn:btih:\(infoHash.hexString)"
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        if let name = displayName { s += "&dn=" + (name.addingPercentEncoding(withAllowedCharacters: allowed) ?? "") }
        for t in trackers { s += "&tr=" + (t.addingPercentEncoding(withAllowedCharacters: allowed) ?? "") }
        for w in webSeeds { s += "&ws=" + (w.addingPercentEncoding(withAllowedCharacters: allowed) ?? "") }
        return s
    }
}

public struct PeerAddress: Hashable, Sendable, CustomStringConvertible {
    public let host: String
    public let port: UInt16

    public init(host: String, port: UInt16) {
        self.host = host
        self.port = port
    }

    /// "1.2.3.4:6881" or "[::1]:6881".
    public init?(hostPort: String) {
        if hostPort.hasPrefix("["), let close = hostPort.firstIndex(of: "]") {
            let host = String(hostPort[hostPort.index(after: hostPort.startIndex)..<close])
            let rest = hostPort[hostPort.index(after: close)...]
            guard rest.hasPrefix(":"), let port = UInt16(rest.dropFirst()) else { return nil }
            self.init(host: host, port: port)
        } else {
            let parts = hostPort.split(separator: ":")
            guard parts.count == 2, let port = UInt16(parts[1]) else { return nil }
            self.init(host: String(parts[0]), port: port)
        }
    }

    public var description: String { host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)" }

    static func parseCompact(_ bytes: [UInt8]) -> [PeerAddress] {
        var out: [PeerAddress] = []
        var i = 0
        while i + 6 <= bytes.count {
            let host = "\(bytes[i]).\(bytes[i + 1]).\(bytes[i + 2]).\(bytes[i + 3])"
            let port = bytes.uint16BE(at: i + 4)
            if port != 0 { out.append(PeerAddress(host: host, port: port)) }
            i += 6
        }
        return out
    }

    static func parseCompact6(_ bytes: [UInt8]) -> [PeerAddress] {
        var out: [PeerAddress] = []
        var i = 0
        while i + 18 <= bytes.count {
            var addr = in6_addr()
            withUnsafeMutableBytes(of: &addr) { raw in
                for k in 0..<16 { raw[k] = bytes[i + k] }
            }
            var buf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            if inet_ntop(AF_INET6, &addr, &buf, socklen_t(buf.count)) != nil {
                let host = String(cString: buf)
                let port = bytes.uint16BE(at: i + 16)
                if port != 0 { out.append(PeerAddress(host: host, port: port)) }
            }
            i += 18
        }
        return out
    }
}
