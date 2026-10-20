import Foundation
import Network

enum AnnounceEvent: UInt32 {
    case none = 0, completed = 1, started = 2, stopped = 3

    var httpName: String? {
        switch self {
        case .none: return nil
        case .completed: return "completed"
        case .started: return "started"
        case .stopped: return "stopped"
        }
    }
}

struct AnnounceRequest {
    var infoHash: [UInt8]
    var peerID: [UInt8]
    var port: UInt16
    var uploaded: Int64
    var downloaded: Int64
    var left: Int64
    var event: AnnounceEvent
    var numWant: Int32 = 80
    var key: UInt32
}

struct AnnounceResponse {
    var interval: Int
    var peers: [PeerAddress]
    var seeders: Int?
    var leechers: Int?
}

struct ScrapeResponse {
    var seeders: Int
    var leechers: Int
}

protocol Tracker: Sendable {
    var url: String { get }
    func announce(_ request: AnnounceRequest) async throws -> AnnounceResponse
    func scrape(_ infoHash: [UInt8]) async throws -> ScrapeResponse
}

func makeTracker(_ url: String, timeout: TimeInterval = 15) -> Tracker? {
    let lower = url.lowercased()
    if lower.hasPrefix("http://") || lower.hasPrefix("https://") { return HTTPTracker(url: url, timeout: timeout) }
    if lower.hasPrefix("udp://") { return UDPTracker(url: url, timeout: timeout) }
    return nil // ws:// (WebTorrent) and anything else
}

/// Swarm sizes from trackers, without joining the swarm.
public enum TrackerScrape {
    public struct Result: Sendable, Equatable {
        public let seeders: Int
        public let leechers: Int
    }

    /// Asks up to eight of the trackers at once and keeps the largest answer:
    /// trackers each see only part of a swarm.
    public static func scrape(infoHash: [UInt8], trackers: [String], timeout: TimeInterval = 8) async -> Result? {
        let candidates = Array(Set(trackers)).compactMap { makeTracker($0, timeout: timeout) }.prefix(8)
        guard !candidates.isEmpty else { return nil }
        return await withTaskGroup(of: Result?.self) { group in
            for t in candidates {
                group.addTask {
                    guard let r = try? await t.scrape(infoHash) else { return nil }
                    return Result(seeders: r.seeders, leechers: r.leechers)
                }
            }
            var best: Result?
            for await r in group {
                if let r, r.seeders > (best?.seeders ?? -1) { best = r }
            }
            return best
        }
    }

    public static func scrape(_ magnet: MagnetLink, timeout: TimeInterval = 8) async -> Result? {
        await scrape(infoHash: magnet.infoHash, trackers: magnet.trackers, timeout: timeout)
    }

    public static func scrape(_ meta: Metainfo, timeout: TimeInterval = 8) async -> Result? {
        await scrape(infoHash: meta.info.infoHash, trackers: meta.trackers, timeout: timeout)
    }
}

struct HTTPTracker: Tracker {
    let url: String
    var timeout: TimeInterval = 15

    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 20
        c.httpAdditionalHeaders = ["User-Agent": "Bobcorn/1.0"]
        return URLSession(configuration: c)
    }()

    private static func escape(_ bytes: [UInt8]) -> String {
        var s = ""
        for b in bytes {
            switch b {
            case 0x30...0x39, 0x41...0x5a, 0x61...0x7a, UInt8(ascii: "-"), UInt8(ascii: "."), UInt8(ascii: "_"), UInt8(ascii: "~"):
                s.append(Character(UnicodeScalar(b)))
            default:
                s += String(format: "%%%02X", b)
            }
        }
        return s
    }

    func announce(_ r: AnnounceRequest) async throws -> AnnounceResponse {
        var q = "info_hash=\(Self.escape(r.infoHash))&peer_id=\(Self.escape(r.peerID))"
        q += "&port=\(r.port)&uploaded=\(r.uploaded)&downloaded=\(r.downloaded)&left=\(r.left)"
        q += "&compact=1&numwant=\(r.numWant)&key=\(String(r.key, radix: 16))"
        if let e = r.event.httpName { q += "&event=\(e)" }
        let sep = url.contains("?") ? "&" : "?"
        guard let full = URL(string: url + sep + q) else { throw TorrentError.tracker("bad URL \(url)") }
        var request = URLRequest(url: full)
        request.timeoutInterval = timeout
        let (data, response) = try await Self.session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw TorrentError.tracker("HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        let root = try Bencode.decode(data)
        if let failure = root["failure reason"]?.stringValue { throw TorrentError.tracker(failure) }
        var peers: [PeerAddress] = []
        if let compact = root["peers"]?.bytesValue {
            peers = PeerAddress.parseCompact(compact)
        } else if let list = root["peers"]?.listValue {
            for p in list {
                if let ip = p["ip"]?.stringValue, let port = p["port"]?.intValue, port > 0, port < 65536 {
                    peers.append(PeerAddress(host: ip, port: UInt16(port)))
                }
            }
        }
        if let six = root["peers6"]?.bytesValue { peers += PeerAddress.parseCompact6(six) }
        return AnnounceResponse(
            interval: Int(root["interval"]?.intValue ?? 1800),
            peers: peers,
            seeders: root["complete"]?.intValue.map { Int($0) },
            leechers: root["incomplete"]?.intValue.map { Int($0) }
        )
    }

    /// BEP 48: the scrape URL is the announce URL with "announce" in its last
    /// path segment replaced by "scrape"; trackers without one cannot scrape.
    func scrape(_ infoHash: [UInt8]) async throws -> ScrapeResponse {
        let query = url.firstIndex(of: "?").map { url[$0...] } ?? ""
        let base = url.firstIndex(of: "?").map { String(url[..<$0]) } ?? url
        guard let slash = base.lastIndex(of: "/"), base[base.index(after: slash)...].hasPrefix("announce") else {
            throw TorrentError.tracker("tracker does not support scrape")
        }
        let scrapeBase = base[...slash] + "scrape" + base[base.index(after: slash)...].dropFirst("announce".count)
        let sep = query.isEmpty ? "?" : "&"
        guard let full = URL(string: scrapeBase + query + sep + "info_hash=\(Self.escape(infoHash))") else {
            throw TorrentError.tracker("bad URL \(url)")
        }
        var request = URLRequest(url: full)
        request.timeoutInterval = timeout
        let (data, response) = try await Self.session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw TorrentError.tracker("HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        let root = try Bencode.decode(data)
        if let failure = root["failure reason"]?.stringValue { throw TorrentError.tracker(failure) }
        // Keys are raw 20-byte hashes, which do not survive as strings; one
        // hash was asked about, so one entry is the answer.
        guard let files = root["files"]?.dictValue, files.count == 1, let stats = files.values.first else {
            throw TorrentError.tracker("no scrape data")
        }
        return ScrapeResponse(
            seeders: Int(stats["complete"]?.intValue ?? 0),
            leechers: Int(stats["incomplete"]?.intValue ?? 0)
        )
    }
}

/// BEP 15.
struct UDPTracker: Tracker {
    let url: String
    var timeout: TimeInterval = 15

    /// Opens the connection and does the connect handshake, then runs `body`
    /// with the connection id. One deadline covers it all: cancelling the
    /// connection fails whatever is pending.
    private func session<T>(_ body: (NWConnection, UInt64) async throws -> T) async throws -> T {
        guard let comps = URLComponents(string: url), let host = comps.host, let port = comps.port,
              let nwPort = NWEndpoint.Port(rawValue: UInt16(port))
        else { throw TorrentError.tracker("bad URL \(url)") }

        let conn = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .udp)
        let queue = DispatchQueue(label: "udp-tracker")
        defer { conn.cancel() }
        let deadline = DispatchWorkItem { conn.cancel() }
        queue.asyncAfter(deadline: .now() + timeout, execute: deadline)
        defer { deadline.cancel() }

        try await Self.waitReady(conn, queue: queue)

        let connectTx = UInt32.random(in: 0...UInt32.max)
        var connect = [UInt8]()
        connect.appendBE(UInt64(0x41727101980))
        connect.appendBE(UInt32(0))
        connect.appendBE(connectTx)
        let connectReply = try await Self.exchange(conn, connect, minLength: 16)
        guard connectReply.uint32BE(at: 0) == 0, connectReply.uint32BE(at: 4) == connectTx else {
            throw TorrentError.tracker("bad connect reply")
        }
        return try await body(conn, connectReply.uint64BE(at: 8))
    }

    private static func checkReply(_ reply: [UInt8], action: UInt32, tx: UInt32) throws {
        guard reply.uint32BE(at: 4) == tx else { throw TorrentError.tracker("transaction mismatch") }
        let got = reply.uint32BE(at: 0)
        if got == 3 { throw TorrentError.tracker(String(decoding: reply[8...], as: UTF8.self)) }
        guard got == action else { throw TorrentError.tracker("unexpected reply") }
    }

    func announce(_ r: AnnounceRequest) async throws -> AnnounceResponse {
        try await session { conn, connectionID in
            let tx = UInt32.random(in: 0...UInt32.max)
            var a = [UInt8]()
            a.appendBE(connectionID)
            a.appendBE(UInt32(1))
            a.appendBE(tx)
            a += r.infoHash
            a += r.peerID
            a.appendBE(UInt64(max(0, r.downloaded)))
            a.appendBE(UInt64(max(0, r.left)))
            a.appendBE(UInt64(max(0, r.uploaded)))
            a.appendBE(r.event.rawValue)
            a.appendBE(UInt32(0)) // IP: let the tracker use the source address
            a.appendBE(r.key)
            a.appendBE(UInt32(bitPattern: r.numWant))
            a.appendBE(r.port)
            let reply = try await Self.exchange(conn, a, minLength: 8)
            try Self.checkReply(reply, action: 1, tx: tx)
            guard reply.count >= 20 else { throw TorrentError.tracker("bad announce reply") }
            return AnnounceResponse(
                interval: Int(reply.uint32BE(at: 8)),
                peers: PeerAddress.parseCompact(Array(reply[20...])),
                seeders: Int(reply.uint32BE(at: 16)),
                leechers: Int(reply.uint32BE(at: 12))
            )
        }
    }

    func scrape(_ infoHash: [UInt8]) async throws -> ScrapeResponse {
        try await session { conn, connectionID in
            let tx = UInt32.random(in: 0...UInt32.max)
            var p = [UInt8]()
            p.appendBE(connectionID)
            p.appendBE(UInt32(2))
            p.appendBE(tx)
            p += infoHash
            let reply = try await Self.exchange(conn, p, minLength: 8)
            try Self.checkReply(reply, action: 2, tx: tx)
            guard reply.count >= 20 else { throw TorrentError.tracker("bad scrape reply") }
            return ScrapeResponse(seeders: Int(reply.uint32BE(at: 8)), leechers: Int(reply.uint32BE(at: 16)))
        }
    }

    private static func waitReady(_ conn: NWConnection, queue: DispatchQueue) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            let once = OnceGuard()
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if once.claim() { c.resume() }
                case .failed(let e), .waiting(let e):
                    if once.claim() { c.resume(throwing: e) }
                case .cancelled:
                    if once.claim() { c.resume(throwing: TorrentError.timedOut) }
                default:
                    break
                }
            }
            conn.start(queue: queue)
        }
    }

    /// Sends a datagram and waits for the reply, retrying the send once.
    private static func exchange(_ conn: NWConnection, _ packet: [UInt8], minLength: Int) async throws -> [UInt8] {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<[UInt8], Error>) in
            let once = OnceGuard()
            conn.send(content: Data(packet), completion: .contentProcessed { error in
                if let error, once.claim() { c.resume(throwing: error) }
            })
            conn.receiveMessage { data, _, _, error in
                if let error {
                    if once.claim() { c.resume(throwing: error) }
                    return
                }
                guard let data, data.count >= minLength else {
                    if once.claim() { c.resume(throwing: TorrentError.tracker("short reply")) }
                    return
                }
                if once.claim() { c.resume(returning: [UInt8](data)) }
            }
        }
    }
}

/// Well-known open trackers added to magnets, which often carry few or none.
public let defaultPublicTrackers = [
    "udp://tracker.opentrackr.org:1337/announce",
    "udp://open.demonii.com:1337/announce",
    "udp://open.stealth.si:80/announce",
    "udp://tracker.torrent.eu.org:451/announce",
    "udp://exodus.desync.com:6969/announce",
    "udp://explodie.org:6969/announce",
    "udp://tracker.openbittorrent.com:6969/announce",
]
