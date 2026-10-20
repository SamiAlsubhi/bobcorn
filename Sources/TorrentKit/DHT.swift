import Darwin
import Foundation

/// A get_peers lookup on the mainline DHT (BEP 5). It only asks: it never
/// joins the table as a node, which is all a streaming client needs to find
/// peers for a magnet that came without trackers.
final class DHTLookup {
    private struct NodeAddr: Hashable {
        let ip: [UInt8]
        let port: UInt16
    }

    private struct Node {
        var id: [UInt8]?
        var queried = false
        var responded = false
    }

    private let infoHash: [UInt8]
    private let nodeID = randomBytes(20)
    private let queue: DispatchQueue
    private let onPeers: ([PeerAddress]) -> Void

    private var fd: Int32 = -1
    private var readSource: DispatchSourceRead?
    private var timer: DispatchSourceTimer?
    private var nodes: [NodeAddr: Node] = [:]
    private var inFlight: [UInt16: (node: NodeAddr, sent: Date)] = [:]
    private var nextTx: UInt16 = UInt16.random(in: 0...UInt16.max)
    private var lookupStarted = Date()
    private var queriesThisRound = 0
    private var idleSince: Date?
    private var stopped = false
    private(set) var peersFound = Set<PeerAddress>()

    static let bootstrap: [(String, UInt16)] = [
        ("router.bittorrent.com", 6881),
        ("router.utorrent.com", 6881),
        ("dht.transmissionbt.com", 6881),
        ("dht.libtorrent.org", 25401),
        ("dht.aelitis.com", 6881),
    ]

    init(infoHash: [UInt8], queue: DispatchQueue, onPeers: @escaping ([PeerAddress]) -> Void) {
        self.infoHash = infoHash
        self.queue = queue
        self.onPeers = onPeers
    }

    func start() {
        fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = INADDR_ANY
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0 else {
            close(fd)
            fd = -1
            return
        }

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.readAvailable() }
        source.resume()
        readSource = source

        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 0.5, repeating: 0.5)
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t

        DispatchQueue.global(qos: .utility).async { [weak self] in
            let resolved = Self.bootstrap.flatMap { Self.resolve(host: $0.0, port: $0.1) }
            self?.queue.async {
                guard let self, !self.stopped else { return }
                for a in resolved where self.nodes[a] == nil { self.nodes[a] = Node() }
                self.sendMore()
            }
        }
    }

    func stop() {
        stopped = true
        timer?.cancel()
        timer = nil
        readSource?.cancel()
        readSource = nil
        if fd >= 0 {
            close(fd)
            fd = -1
        }
    }

    /// Starts a fresh round against the nodes already known.
    func restart() {
        guard !stopped else { return }
        for k in nodes.keys { nodes[k]?.queried = false }
        lookupStarted = Date()
        queriesThisRound = 0
        idleSince = nil
        sendMore()
    }

    var isIdle: Bool { idleSince != nil }

    private func tick() {
        let now = Date()
        for (tx, entry) in inFlight where now.timeIntervalSince(entry.sent) > 3 {
            inFlight[tx] = nil
        }
        sendMore()
    }

    private func distance(_ id: [UInt8]?) -> [UInt8] {
        guard let id else { return [UInt8](repeating: 0xff, count: 20) }
        return zip(id, infoHash).map { $0 ^ $1 }
    }

    private func sendMore() {
        guard fd >= 0, !stopped, idleSince == nil else { return }
        let roundOver = queriesThisRound > 500 || Date().timeIntervalSince(lookupStarted) > 60
        // The closest nodes not asked yet. Bootstrap nodes (no id) sort last
        // but are the only ones there are at first.
        let candidates = nodes.filter { !$0.value.queried }
            .map { (addr: $0.key, distance: distance($0.value.id)) }
            .sorted { $0.distance.lexicographicallyPrecedes($1.distance) }
        let closestResponded = nodes.filter { $0.value.responded }
            .map { distance($0.value.id) }
            .sorted { $0.lexicographicallyPrecedes($1) }
            .prefix(8)
        // Converged once nothing left to ask is closer than the 8 best that answered.
        let worst = closestResponded.count == 8 ? closestResponded.last : nil
        var converged = false
        if !roundOver {
            for c in candidates {
                guard inFlight.count < 12 else { break }
                if let worst, !c.distance.lexicographicallyPrecedes(worst) {
                    converged = true
                    break
                }
                query(c.addr)
            }
        }
        if inFlight.isEmpty && (roundOver || converged || candidates.isEmpty) {
            idleSince = Date()
        }
    }

    private func query(_ addr: NodeAddr) {
        nodes[addr]?.queried = true
        nextTx &+= 1
        let tx = nextTx
        var t = [UInt8]()
        t.appendBE(tx)
        let message = BValue.dict([
            "t": .bytes(t),
            "y": .string("q"),
            "q": .string("get_peers"),
            "a": .dict(["id": .bytes(nodeID), "info_hash": .bytes(infoHash)]),
        ])
        let packet = Bencode.encode(message)
        var sa = sockaddr_in()
        sa.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        sa.sin_family = sa_family_t(AF_INET)
        sa.sin_port = addr.port.bigEndian
        withUnsafeMutableBytes(of: &sa.sin_addr) { raw in
            for i in 0..<4 { raw[i] = addr.ip[i] }
        }
        let sent = packet.withUnsafeBytes { buf in
            withUnsafePointer(to: &sa) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, buf.baseAddress, buf.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        if sent > 0 {
            inFlight[tx] = (addr, Date())
            queriesThisRound += 1
        }
    }

    private func readAvailable() {
        var buf = [UInt8](repeating: 0, count: 4096)
        while fd >= 0 {
            var from = sockaddr_in()
            var fromLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = buf.withUnsafeMutableBytes { raw in
                withUnsafeMutablePointer(to: &from) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        recvfrom(fd, raw.baseAddress, raw.count, 0, $0, &fromLen)
                    }
                }
            }
            guard n > 0 else { break }
            var ip = [UInt8](repeating: 0, count: 4)
            withUnsafeBytes(of: &from.sin_addr) { raw in for i in 0..<4 { ip[i] = raw[i] } }
            handle(Array(buf[0..<n]), from: NodeAddr(ip: ip, port: UInt16(bigEndian: from.sin_port)))
        }
        sendMore()
    }

    private func handle(_ packet: [UInt8], from addr: NodeAddr) {
        guard let msg = try? Bencode.decode(packet),
              let t = msg["t"]?.bytesValue, t.count == 2
        else { return }
        let tx = t.uint16BE(at: 0)
        guard inFlight.removeValue(forKey: tx) != nil else { return }
        guard msg["y"]?.stringValue == "r", let r = msg["r"] else { return }

        if let id = r["id"]?.bytesValue, id.count == 20 {
            nodes[addr, default: Node()].id = id
            nodes[addr]?.responded = true
            nodes[addr]?.queried = true
        }
        if let compact = r["nodes"]?.bytesValue {
            var i = 0
            while i + 26 <= compact.count {
                let id = Array(compact[i..<(i + 20)])
                let ip = Array(compact[(i + 20)..<(i + 24)])
                let port = compact.uint16BE(at: i + 24)
                let a = NodeAddr(ip: ip, port: port)
                if port != 0, ip[0] != 0, nodes[a] == nil, nodes.count < 3000 {
                    nodes[a] = Node(id: id)
                }
                i += 26
            }
        }
        if let values = r["values"]?.listValue {
            var fresh: [PeerAddress] = []
            for v in values {
                guard let b = v.bytesValue, b.count == 6 else { continue }
                for p in PeerAddress.parseCompact(b) where peersFound.insert(p).inserted {
                    fresh.append(p)
                }
            }
            if !fresh.isEmpty { onPeers(fresh) }
        }
    }

    private static func resolve(host: String, port: UInt16) -> [NodeAddr] {
        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_DGRAM
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &result) == 0 else { return [] }
        defer { freeaddrinfo(result) }
        var out: [NodeAddr] = []
        var p = result
        while let ai = p {
            if ai.pointee.ai_family == AF_INET, let sa = ai.pointee.ai_addr {
                sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { sin in
                    var ip = [UInt8](repeating: 0, count: 4)
                    var a = sin.pointee.sin_addr
                    withUnsafeBytes(of: &a) { raw in for i in 0..<4 { ip[i] = raw[i] } }
                    out.append(NodeAddr(ip: ip, port: port))
                }
            }
            p = ai.pointee.ai_next
        }
        return out
    }
}
