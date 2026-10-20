import Foundation
import Network

/// A loopback HTTP server that serves torrent files as they download, with
/// Range support, so AVPlayer (or VLC, or IINA) can play them by URL. A read
/// of bytes not here yet waits for them and pulls the download window there.
public final class StreamServer: @unchecked Sendable {
    /// Makes the response to a path under a generated route; nil is a 404.
    public typealias Generator = @Sendable (_ path: String) async throws -> (contentType: String, body: Data)?

    struct Route {
        let session: TorrentSession
        let file: TorrentFile?
        let generator: Generator?
    }

    private let queue = DispatchQueue(label: "bobcorn.stream-server")
    private let lock = NSLock()
    private var listener: NWListener?
    private var routes: [String: Route] = [:]
    private var connections: [ObjectIdentifier: StreamConnection] = [:]
    private var startedPort: UInt16 = 0
    private var lanListener: NWListener?
    private var lanPort: UInt16 = 0
    /// What a request from another device must start its path with: the
    /// local network only gets the streams it was handed.
    let secret = (0..<16).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()

    public init() {}

    public var port: UInt16 {
        lock.lock()
        defer { lock.unlock() }
        return startedPort
    }

    @discardableResult
    public func start() async throws -> UInt16 {
        if port != 0 { return port }
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: params)
        listener.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
        let port: UInt16 = try await withCheckedThrowingContinuation { c in
            let once = OnceGuard()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if once.claim() { c.resume(returning: listener.port?.rawValue ?? 0) }
                case .failed(let error):
                    if once.claim() { c.resume(throwing: error) }
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
        adopt(listener, port: port)
        return port
    }

    private func adopt(_ listener: NWListener, port: UInt16) {
        lock.lock()
        self.listener = listener
        startedPort = port
        lock.unlock()
    }

    public func stop() {
        lock.lock()
        listener?.cancel()
        listener = nil
        startedPort = 0
        lanListener?.cancel()
        lanListener = nil
        lanPort = 0
        lock.unlock()
    }

    /// Also serves the local network, for a Chromecast to stream from.
    @discardableResult
    public func startLAN() async throws -> UInt16 {
        if currentLANPort != 0 { return currentLANPort }
        let listener = try NWListener(using: .tcp)
        listener.newConnectionHandler = { [weak self] conn in self?.accept(conn, lan: true) }
        let port: UInt16 = try await withCheckedThrowingContinuation { c in
            let once = OnceGuard()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if once.claim() { c.resume(returning: listener.port?.rawValue ?? 0) }
                case .failed(let error):
                    if once.claim() { c.resume(throwing: error) }
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
        adoptLAN(listener, port: port)
        return port
    }

    private var currentLANPort: UInt16 {
        lock.lock()
        defer { lock.unlock() }
        return lanPort
    }

    private func adoptLAN(_ listener: NWListener, port: UInt16) {
        lock.lock()
        lanListener = listener
        lanPort = port
        lock.unlock()
    }

    /// `url`, a stream on this Mac, as another device on the network reaches
    /// it at `host`. Nil until `startLAN`.
    public func lanURL(for url: URL, host: String) -> URL? {
        let port = currentLANPort
        guard port != 0, var c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        c.host = nil
        c.port = nil
        c.scheme = nil
        guard let rest = c.string else { return nil }
        return URL(string: "http://\(host):\(port)/\(secret)\(rest)")
    }

    /// A URL that serves `file` from `session`.
    public func url(for session: TorrentSession, file: TorrentFile) -> URL {
        let token = "\(session.infoHashHex)-\(file.index)"
        lock.lock()
        routes[token] = Route(session: session, file: file, generator: nil)
        let port = startedPort
        lock.unlock()
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#;")
        let name = file.name.addingPercentEncoding(withAllowedCharacters: allowed) ?? "video"
        return URL(string: "http://127.0.0.1:\(port)/\(token)/\(name)")!
    }

    /// A URL for content made on request, such as a remuxed stream's playlist
    /// and segments, served for as long as `session` runs. `name` is the
    /// first path requested; the generator answers it and its siblings.
    public func url(for session: TorrentSession, generated key: String, name: String, generator: @escaping Generator) -> URL {
        let token = "\(session.infoHashHex)-\(key)"
        lock.lock()
        routes[token] = Route(session: session, file: nil, generator: generator)
        let port = startedPort
        lock.unlock()
        return URL(string: "http://127.0.0.1:\(port)/\(token)/\(name)")!
    }

    public func removeRoutes(for session: TorrentSession) {
        lock.lock()
        routes = routes.filter { $0.value.session !== session }
        lock.unlock()
    }

    func route(for path: String) -> Route? {
        let parts = path.split(separator: "/")
        guard let token = parts.first else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return routes[String(token)]
    }

    private func accept(_ conn: NWConnection, lan: Bool = false) {
        let c = StreamConnection(connection: conn, server: self, lan: lan)
        lock.lock()
        connections[ObjectIdentifier(c)] = c
        lock.unlock()
        c.start(queue: queue)
    }

    func finished(_ c: StreamConnection) {
        lock.lock()
        connections[ObjectIdentifier(c)] = nil
        lock.unlock()
    }

    static func mimeType(for ext: String) -> String {
        switch ext.lowercased() {
        case "mp4", "m4v": return "video/mp4"
        case "mov": return "video/quicktime"
        case "mkv": return "video/x-matroska"
        case "webm": return "video/webm"
        case "avi": return "video/x-msvideo"
        case "ogv": return "video/ogg"
        case "mpg", "mpeg": return "video/mpeg"
        case "ts": return "video/mp2t"
        case "wmv": return "video/x-ms-wmv"
        case "flv": return "video/x-flv"
        case "srt": return "application/x-subrip"
        case "vtt": return "text/vtt"
        default: return "application/octet-stream"
        }
    }
}

final class StreamConnection: @unchecked Sendable {
    private let connection: NWConnection
    private weak var server: StreamServer?
    private var buffer = Data()
    private var task: Task<Void, Never>?
    private let once = OnceGuard()
    /// From another device: it must know the secret, and gets CORS headers
    /// (a Cast receiver fetches HLS from a web page).
    private let lan: Bool

    init(connection: NWConnection, server: StreamServer, lan: Bool) {
        self.connection = connection
        self.server = server
        self.lan = lan
    }

    func start(queue: DispatchQueue) {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.finish()
            default:
                break
            }
        }
        connection.start(queue: queue)
        readHeaders()
    }

    private func finish() {
        task?.cancel()
        connection.cancel()
        if once.claim() { server?.finished(self) }
    }

    private func readHeaders() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, complete, error in
            guard let self else { return }
            if let data { self.buffer.append(data) }
            if let end = self.buffer.range(of: Data("\r\n\r\n".utf8)) {
                self.handle(head: String(decoding: self.buffer[..<end.lowerBound], as: UTF8.self))
            } else if error != nil || complete || self.buffer.count > 64 * 1024 {
                self.finish()
            } else {
                self.readHeaders()
            }
        }
    }

    /// Notices the player hanging up while we are waiting on a piece.
    private func watchForClose() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] _, _, complete, error in
            guard let self else { return }
            if complete || error != nil {
                self.finish()
            } else {
                self.watchForClose()
            }
        }
    }

    private func handle(head: String) {
        let lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.first?.split(separator: " ") ?? []
        guard requestLine.count >= 2 else { return respond(status: "400 Bad Request") }
        let method = String(requestLine[0])
        var path = String(requestLine[1])
        if lan {
            #if DEBUG
            print("[lan] \(method) \(path.split(separator: "/").suffix(2).joined(separator: "/")) from \(connection.endpoint)")
            fflush(stdout)
            #endif
            guard let secret = server?.secret, path.hasPrefix("/\(secret)/") else { return respond(status: "403 Forbidden") }
            path = String(path.dropFirst(secret.count + 1))
            if method == "OPTIONS" {
                return respond(status: "204 No Content", extra: [
                    "Access-Control-Allow-Methods": "GET, HEAD, OPTIONS",
                    "Access-Control-Allow-Headers": "Range, Content-Type",
                    "Access-Control-Max-Age": "600",
                ])
            }
        }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        guard method == "GET" || method == "HEAD" else { return respond(status: "405 Method Not Allowed") }
        guard let route = server?.route(for: path) else { return respond(status: "404 Not Found") }
        if let generator = route.generator {
            let rangeHeader = headers["range"]
            watchForClose()
            task = Task { [weak self] in await self?.serveGenerated(generator, path: path, range: rangeHeader, head: method == "HEAD") }
            return
        }
        guard let file = route.file else { return respond(status: "404 Not Found") }

        let total = file.length
        let (start, end, partial) = Self.byteRange(headers["range"], total: total)
        guard total > 0, start <= end, start < total else {
            return respond(status: "416 Range Not Satisfiable", extra: ["Content-Range": "bytes */\(total)"])
        }

        var h = [
            "Content-Type": StreamServer.mimeType(for: file.fileExtension),
            "Accept-Ranges": "bytes",
            "Content-Length": "\(end - start + 1)",
            "Connection": "close",
        ]
        if partial { h["Content-Range"] = "bytes \(start)-\(end)/\(total)" }
        sendHead(status: partial ? "206 Partial Content" : "200 OK", headers: h)
        if method == "HEAD" {
            close()
            return
        }
        watchForClose()
        task = Task { [weak self] in await self?.streamBody(route.session, file, start: start, end: end) }
    }

    /// The bytes a Range header asks for, inclusive, and whether it asked.
    static func byteRange(_ header: String?, total: Int64) -> (start: Int64, end: Int64, partial: Bool) {
        var start: Int64 = 0
        var end: Int64 = total - 1
        guard let header, header.hasPrefix("bytes=") else { return (start, end, false) }
        let spec = header.dropFirst("bytes=".count).split(separator: ",").first.map(String.init) ?? ""
        let bounds = spec.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        guard bounds.count == 2 else { return (start, end, false) }
        if bounds[0].isEmpty, let suffix = Int64(bounds[1]) {
            start = max(0, total - suffix)
        } else if let s = Int64(bounds[0]) {
            start = s
            if let e = Int64(bounds[1]) { end = min(e, total - 1) }
        }
        return (start, end, true)
    }

    /// Content made on request is complete before its headers go out, so a
    /// failure can still be an error status.
    private func serveGenerated(_ generator: StreamServer.Generator, path: String, range: String?, head: Bool) async {
        let subpath = String(path.split(separator: "?", maxSplits: 1).first ?? "")
        let result: (contentType: String, body: Data)?
        do {
            result = try await generator(subpath)
        } catch {
            if Task.isCancelled { return finish() }
            return respond(status: "503 Service Unavailable")
        }
        guard let result else { return respond(status: "404 Not Found") }
        let total = Int64(result.body.count)
        let (start, end, partial) = Self.byteRange(range, total: total)
        guard start <= end, start < total || total == 0 else {
            return respond(status: "416 Range Not Satisfiable", extra: ["Content-Range": "bytes */\(total)"])
        }
        var h = [
            "Content-Type": result.contentType,
            "Accept-Ranges": "bytes",
            "Content-Length": "\(total == 0 ? 0 : end - start + 1)",
            "Cache-Control": "no-cache",
            "Connection": "close",
        ]
        if partial && total > 0 { h["Content-Range"] = "bytes \(start)-\(end)/\(total)" }
        sendHead(status: partial && total > 0 ? "206 Partial Content" : "200 OK", headers: h)
        guard !head, total > 0 else { return close() }
        do {
            try await send(result.body.subdata(in: Int(start)..<Int(end + 1)))
            close()
        } catch {
            finish()
        }
    }

    private func streamBody(_ session: TorrentSession, _ file: TorrentFile, start: Int64, end: Int64) async {
        let streamID = UUID()
        defer { session.endStream(streamID) }
        var offset = start
        do {
            while offset <= end {
                try Task.checkCancellation()
                let want = Int(min(Int64(512 * 1024), end - offset + 1))
                let data = try await session.read(fileIndex: file.index, offset: offset, maxLength: want, streamID: streamID)
                try await send(data)
                offset += Int64(data.count)
            }
            close()
        } catch {
            finish()
        }
    }

    private func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { c.resume(throwing: error) } else { c.resume() }
            })
        }
    }

    private func sendHead(status: String, headers: [String: String]) {
        var headers = headers
        if lan {
            headers["Access-Control-Allow-Origin"] = "*"
            headers["Access-Control-Expose-Headers"] = "Content-Length, Content-Range, Accept-Ranges"
        }
        var s = "HTTP/1.1 \(status)\r\n"
        for (k, v) in headers { s += "\(k): \(v)\r\n" }
        s += "\r\n"
        connection.send(content: Data(s.utf8), completion: .contentProcessed { _ in })
    }

    private func respond(status: String, extra: [String: String] = [:]) {
        var h = extra
        h["Content-Length"] = "0"
        h["Connection"] = "close"
        sendHead(status: status, headers: h)
        close()
    }

    private func close() {
        connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { [weak self] _ in
            self?.finish()
        })
    }
}
