import Foundation
import Network

struct BlockRequest: Hashable {
    let piece: Int
    let begin: Int
    let length: Int
}

enum PeerMessage {
    case keepAlive
    case choke
    case unchoke
    case interested
    case notInterested
    case have(Int)
    case bitfield([UInt8])
    case request(BlockRequest)
    case piece(index: Int, begin: Int, data: [UInt8])
    case cancel(BlockRequest)
    case port(UInt16)
    case haveAll
    case haveNone
    case reject(BlockRequest)
    case extended(id: UInt8, payload: [UInt8])
    case unknown(UInt8)

    func encoded() -> [UInt8] {
        var out = [UInt8]()
        func frame(_ id: UInt8, _ payload: [UInt8] = []) {
            out.appendBE(UInt32(1 + payload.count))
            out.append(id)
            out += payload
        }
        func request(_ r: BlockRequest) -> [UInt8] {
            var p = [UInt8]()
            p.appendBE(UInt32(r.piece))
            p.appendBE(UInt32(r.begin))
            p.appendBE(UInt32(r.length))
            return p
        }
        switch self {
        case .keepAlive: out.appendBE(UInt32(0))
        case .choke: frame(0)
        case .unchoke: frame(1)
        case .interested: frame(2)
        case .notInterested: frame(3)
        case .have(let i):
            var p = [UInt8]()
            p.appendBE(UInt32(i))
            frame(4, p)
        case .bitfield(let b): frame(5, b)
        case .request(let r): frame(6, request(r))
        case .piece(let index, let begin, let data):
            out.appendBE(UInt32(9 + data.count))
            out.append(7)
            out.appendBE(UInt32(index))
            out.appendBE(UInt32(begin))
            out += data
        case .cancel(let r): frame(8, request(r))
        case .port(let port):
            var p = [UInt8]()
            p.appendBE(port)
            frame(9, p)
        case .haveAll: frame(0x0e)
        case .haveNone: frame(0x0f)
        case .reject(let r): frame(0x10, request(r))
        case .extended(let id, let payload): frame(20, [id] + payload)
        case .unknown(let id): frame(id)
        }
        return out
    }
}

protocol PeerConnectionDelegate: AnyObject {
    func peerConnectionDidConnect(_ connection: PeerConnection)
    func peerConnection(_ connection: PeerConnection, didHandshake peerID: [UInt8], reserved: [UInt8])
    func peerConnection(_ connection: PeerConnection, didReceive message: PeerMessage)
    func peerConnectionDidClose(_ connection: PeerConnection, reason: String)
}

/// One TCP connection speaking the BitTorrent wire protocol. Every callback
/// runs on the owning session's queue.
final class PeerConnection {
    let address: PeerAddress
    weak var delegate: PeerConnectionDelegate?

    private let connection: NWConnection
    private let queue: DispatchQueue
    private let infoHash: [UInt8]
    private let localPeerID: [UInt8]
    private var buffer: [UInt8] = []
    private var handshakeReceived = false
    private(set) var isClosed = false
    private(set) var lastReceived = Date()
    private(set) var lastSent = Date()

    init(address: PeerAddress, infoHash: [UInt8], peerID: [UInt8], queue: DispatchQueue) {
        self.address = address
        self.queue = queue
        self.infoHash = infoHash
        self.localPeerID = peerID
        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = 10
        tcp.noDelay = true
        let params = NWParameters(tls: nil, tcp: tcp)
        connection = NWConnection(
            host: NWEndpoint.Host(address.host),
            port: NWEndpoint.Port(rawValue: address.port) ?? 6881,
            using: params
        )
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.delegate?.peerConnectionDidConnect(self)
                self.sendHandshake()
                self.receive()
            case .failed(let error):
                self.close(reason: "failed: \(error)")
            case .waiting(let error):
                self.close(reason: "unreachable: \(error)")
            case .cancelled:
                self.close(reason: "cancelled")
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func sendHandshake() {
        var h = [UInt8]()
        h.append(19)
        h += Array("BitTorrent protocol".utf8)
        var reserved = [UInt8](repeating: 0, count: 8)
        reserved[5] |= 0x10 // BEP 10 extension protocol
        h += reserved
        h += infoHash
        h += localPeerID
        write(h)
    }

    func send(_ message: PeerMessage) {
        write(message.encoded())
    }

    private func write(_ bytes: [UInt8]) {
        guard !isClosed else { return }
        lastSent = Date()
        connection.send(content: Data(bytes), completion: .contentProcessed { [weak self] error in
            if let error { self?.close(reason: "send: \(error)") }
        })
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, isComplete, error in
            guard let self, !self.isClosed else { return }
            if let data, !data.isEmpty {
                self.lastReceived = Date()
                self.buffer.append(contentsOf: data)
                self.process()
            }
            if self.isClosed { return }
            if let error {
                self.close(reason: "receive: \(error)")
            } else if isComplete {
                self.close(reason: "peer closed")
            } else {
                self.receive()
            }
        }
    }

    private func process() {
        var index = 0
        if !handshakeReceived {
            guard buffer.count >= 68 else { return }
            guard buffer[0] == 19, Array(buffer[1..<20]) == Array("BitTorrent protocol".utf8) else {
                close(reason: "bad handshake")
                return
            }
            guard Array(buffer[28..<48]) == infoHash else {
                close(reason: "wrong info-hash")
                return
            }
            handshakeReceived = true
            let reserved = Array(buffer[20..<28])
            let peerID = Array(buffer[48..<68])
            index = 68
            delegate?.peerConnection(self, didHandshake: peerID, reserved: reserved)
            if isClosed { return }
        }
        while buffer.count - index >= 4 {
            let length = Int(buffer.uint32BE(at: index))
            guard length <= 4 * 1024 * 1024 else {
                close(reason: "oversized message (\(length) bytes)")
                return
            }
            guard buffer.count - index - 4 >= length else { break }
            let body = index + 4
            index = body + length
            let message: PeerMessage
            if length == 0 {
                message = .keepAlive
            } else {
                guard let m = parse(id: buffer[body], payload: buffer[(body + 1)..<(body + length)]) else {
                    close(reason: "malformed message \(buffer[body])")
                    return
                }
                message = m
            }
            delegate?.peerConnection(self, didReceive: message)
            if isClosed { return }
        }
        if index > 0 { buffer.removeFirst(index) }
    }

    private func parse(id: UInt8, payload: ArraySlice<UInt8>) -> PeerMessage? {
        let p = Array(payload)
        func request() -> BlockRequest? {
            guard p.count == 12 else { return nil }
            return BlockRequest(piece: Int(p.uint32BE(at: 0)), begin: Int(p.uint32BE(at: 4)), length: Int(p.uint32BE(at: 8)))
        }
        switch id {
        case 0: return .choke
        case 1: return .unchoke
        case 2: return .interested
        case 3: return .notInterested
        case 4:
            guard p.count == 4 else { return nil }
            return .have(Int(p.uint32BE(at: 0)))
        case 5: return .bitfield(p)
        case 6: return request().map { .request($0) }
        case 7:
            guard p.count >= 8 else { return nil }
            return .piece(index: Int(p.uint32BE(at: 0)), begin: Int(p.uint32BE(at: 4)), data: Array(p[8...]))
        case 8: return request().map { .cancel($0) }
        case 9:
            guard p.count == 2 else { return nil }
            return .port(p.uint16BE(at: 0))
        case 0x0e: return .haveAll
        case 0x0f: return .haveNone
        case 0x10: return request().map { .reject($0) }
        case 20:
            guard !p.isEmpty else { return nil }
            return .extended(id: p[0], payload: Array(p[1...]))
        default: return .unknown(id)
        }
    }

    func close(reason: String) {
        guard !isClosed else { return }
        isClosed = true
        connection.stateUpdateHandler = nil
        connection.cancel()
        delegate?.peerConnectionDidClose(self, reason: reason)
    }
}
