import Foundation

/// One message of the Cast protocol (CASTV2): a protocol buffer naming who
/// it's from, who it's for and its namespace, around a JSON payload. On the
/// wire each one follows its length as a 32-bit big-endian integer.
struct CastMessage: Equatable {
    var source: String
    var destination: String
    var namespace: String
    var payload: String

    enum Namespace {
        static let connection = "urn:x-cast:com.google.cast.tp.connection"
        static let heartbeat = "urn:x-cast:com.google.cast.tp.heartbeat"
        static let receiver = "urn:x-cast:com.google.cast.receiver"
        static let media = "urn:x-cast:com.google.cast.media"
    }

    init(source: String, destination: String, namespace: String, payload: String) {
        self.source = source
        self.destination = destination
        self.namespace = namespace
        self.payload = payload
    }

    init(source: String, destination: String, namespace: String, json: [String: Any]) {
        let data = (try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])) ?? Data("{}".utf8)
        self.init(source: source, destination: destination, namespace: namespace, payload: String(decoding: data, as: UTF8.self))
    }

    var json: [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(payload.utf8))) as? [String: Any]
    }

    var type: String? { json?["type"] as? String }

    // MARK: Protocol buffer

    /// Fields 1 (protocol version 0), 2–4 (source, destination, namespace),
    /// 5 (payload type 0: a string) and 6 (the payload).
    var encoded: Data {
        var d = Data()
        func varint(_ v: UInt64) {
            var v = v
            repeat {
                var byte = UInt8(v & 0x7F)
                v >>= 7
                if v != 0 { byte |= 0x80 }
                d.append(byte)
            } while v != 0
        }
        func string(_ field: UInt64, _ s: String) {
            let bytes = Data(s.utf8)
            varint(field << 3 | 2)
            varint(UInt64(bytes.count))
            d.append(bytes)
        }
        varint(1 << 3)
        varint(0)
        string(2, source)
        string(3, destination)
        string(4, namespace)
        varint(5 << 3)
        varint(0)
        string(6, payload)
        return d
    }

    /// With its length in front, ready to send.
    var framed: Data {
        let body = encoded
        let n = UInt32(body.count)
        return Data([UInt8(n >> 24), UInt8(n >> 16 & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n & 0xFF)]) + body
    }

    init?(decoding body: Data) {
        let b = [UInt8](body)
        var i = 0
        func varint() -> UInt64? {
            var v: UInt64 = 0
            var shift: UInt64 = 0
            while i < b.count, shift < 64 {
                let byte = b[i]
                i += 1
                v |= UInt64(byte & 0x7F) << shift
                if byte & 0x80 == 0 { return v }
                shift += 7
            }
            return nil
        }
        var strings: [UInt64: String] = [:]
        while i < b.count {
            guard let tag = varint() else { return nil }
            switch tag & 7 {
            case 0:
                guard varint() != nil else { return nil }
            case 2:
                guard let n = varint(), i + Int(n) <= b.count else { return nil }
                strings[tag >> 3] = String(decoding: b[i..<i + Int(n)], as: UTF8.self)
                i += Int(n)
            case 1: i += 8
            case 5: i += 4
            default: return nil
            }
        }
        guard let source = strings[2], let destination = strings[3], let namespace = strings[4] else { return nil }
        self.init(source: source, destination: destination, namespace: namespace, payload: strings[6] ?? "")
    }

    /// Takes whole messages off the front of `buffer`.
    static func unframe(_ buffer: inout Data) -> [CastMessage] {
        var out: [CastMessage] = []
        while buffer.count >= 4 {
            let b = buffer.startIndex
            let n = Int(UInt32(buffer[b]) << 24 | UInt32(buffer[b + 1]) << 16 | UInt32(buffer[b + 2]) << 8 | UInt32(buffer[b + 3]))
            guard buffer.count >= 4 + n else { break }
            if let m = CastMessage(decoding: buffer.subdata(in: (b + 4)..<(b + 4 + n))) { out.append(m) }
            buffer = buffer.subdata(in: (b + 4 + n)..<buffer.endIndex)
        }
        return out
    }
}
