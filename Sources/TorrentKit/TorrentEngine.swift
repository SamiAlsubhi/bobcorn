import Foundation

/// Owns the running torrents and the loopback server that streams them.
public final class TorrentEngine: @unchecked Sendable {
    public let configuration: TorrentConfiguration
    public let peerID: [UInt8]
    public let server = StreamServer()

    private let lock = NSLock()
    private var sessions: [String: TorrentSession] = [:]
    private var users: [String: Int] = [:]

    public init(configuration: TorrentConfiguration) {
        self.configuration = configuration
        let alphabet = Array("0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ".utf8)
        peerID = Array("-MT0100-".utf8) + (0..<12).map { _ in alphabet.randomElement()! }
    }

    /// The running session for this torrent, started if it was not. Each call
    /// must be balanced by a `release`: the session runs while anyone holds it,
    /// so a page showing a swarm and the player streaming it share one.
    public func session(for source: TorrentSource) -> TorrentSession {
        lock.lock()
        defer { lock.unlock() }
        let key = source.infoHashHex
        users[key, default: 0] += 1
        if let existing = sessions[key] { return existing }
        let s = TorrentSession(source: source, configuration: configuration, peerID: peerID)
        sessions[key] = s
        s.start()
        return s
    }

    public func release(_ session: TorrentSession) {
        lock.lock()
        let key = session.infoHashHex
        guard sessions[key] === session else {
            lock.unlock()
            return
        }
        users[key, default: 1] -= 1
        let last = users[key]! <= 0
        if last {
            sessions[key] = nil
            users[key] = nil
        }
        lock.unlock()
        if last {
            server.removeRoutes(for: session)
            session.stop()
        }
    }

    public var activeSessionCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return sessions.count
    }

    public func stopAll() {
        lock.lock()
        let all = Array(sessions.values)
        sessions.removeAll()
        users.removeAll()
        lock.unlock()
        for s in all {
            server.removeRoutes(for: s)
            s.stop()
        }
    }

    public func streamURL(for session: TorrentSession, file: TorrentFile) async throws -> URL {
        try await server.start()
        return server.url(for: session, file: file)
    }

    /// Bytes the cache folder holds on disk (sparse files count what is written).
    public static func cacheSize(at url: URL) -> Int64 {
        guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let f as URL in e {
            total += Int64((try? f.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0)
        }
        return total
    }
}
