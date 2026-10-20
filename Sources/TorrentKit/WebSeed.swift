import Foundation

/// BEP 19 (GetRight-style) web seed: plain HTTP range requests against a
/// server that hosts the torrent's files. The Internet Archive serves every
/// torrent it makes this way, which is what makes its swarms fast.
final class WebSeed: @unchecked Sendable {
    let base: String
    var active = 0
    var successes = 0
    var consecutiveFailures = 0
    var hashFailures = 0
    var disabled = false

    private let lock = NSLock()
    private var resolved: [Int: URL] = [:]

    static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 30
        c.httpMaximumConnectionsPerHost = 8
        c.httpAdditionalHeaders = ["User-Agent": "Bobcorn/1.0"]
        return URLSession(configuration: c)
    }()

    init(base: String) {
        var b = base
        // archive.org lists http:// seeds; every archive.org host serves https.
        if let url = URL(string: b), let host = url.host, host == "archive.org" || host.hasSuffix(".archive.org"),
           b.hasPrefix("http://") {
            b = "https://" + b.dropFirst("http://".count)
        }
        self.base = b
    }

    var maxConcurrent: Int { successes > 0 ? 4 : 1 }

    private static let pathAllowed: CharacterSet = {
        var s = CharacterSet.urlPathAllowed
        s.remove(charactersIn: "/?#[]@!$&'()*+,;=")
        return s
    }()

    func url(for file: TorrentFile, in info: TorrentInfo) -> URL? {
        lock.lock()
        if let u = resolved[file.index] {
            lock.unlock()
            return u
        }
        lock.unlock()
        let encode = { (s: String) in s.addingPercentEncoding(withAllowedCharacters: Self.pathAllowed) ?? s }
        var s = base
        if info.isMultiFile {
            if !s.hasSuffix("/") { s += "/" }
            s += ([info.name] + file.path).map(encode).joined(separator: "/")
        } else if s.hasSuffix("/") {
            s += encode(info.name)
        }
        return URL(string: s)
    }

    private func remember(_ url: URL, for file: Int) {
        lock.lock()
        resolved[file] = url
        lock.unlock()
    }

    /// Downloads one whole piece.
    func fetch(piece index: Int, info: TorrentInfo) async throws -> [UInt8] {
        let start = info.pieceOffset(index)
        let size = info.pieceSize(index)
        var out = [UInt8](repeating: 0, count: size)
        for seg in info.segments(start: start, length: size) where !seg.file.isPadding {
            guard let url = url(for: seg.file, in: info) else { throw TorrentError.tracker("bad web seed URL") }
            var req = URLRequest(url: url)
            req.setValue("bytes=\(seg.fileOffset)-\(seg.fileOffset + Int64(seg.length) - 1)", forHTTPHeaderField: "Range")
            let (data, response) = try await Self.session.data(for: req)
            guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            let body: Data
            if http.statusCode == 206, data.count == seg.length {
                body = data
            } else if http.statusCode == 200, seg.fileOffset == 0, Int64(data.count) == seg.file.length, data.count == seg.length {
                body = data
            } else {
                throw URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: "web seed answered HTTP \(http.statusCode) with \(data.count) bytes"])
            }
            if let final = http.url, final != url { remember(final, for: seg.file.index) }
            out.withUnsafeMutableBytes { dst in
                body.copyBytes(to: UnsafeMutableRawBufferPointer(rebasing: dst[seg.bufferOffset..<(seg.bufferOffset + seg.length)]))
            }
        }
        return out
    }
}
