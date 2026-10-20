import Foundation

/// A decoded bencode value (BEP 3).
public indirect enum BValue: Equatable, Sendable {
    case int(Int64)
    case bytes([UInt8])
    case list([BValue])
    case dict([String: BValue])

    public static func string(_ s: String) -> BValue { .bytes(Array(s.utf8)) }

    public subscript(key: String) -> BValue? {
        if case .dict(let d) = self { return d[key] }
        return nil
    }

    public var intValue: Int64? {
        if case .int(let v) = self { return v }
        return nil
    }

    public var bytesValue: [UInt8]? {
        if case .bytes(let v) = self { return v }
        return nil
    }

    public var stringValue: String? {
        bytesValue.map { String(decoding: $0, as: UTF8.self) }
    }

    public var listValue: [BValue]? {
        if case .list(let v) = self { return v }
        return nil
    }

    public var dictValue: [String: BValue]? {
        if case .dict(let v) = self { return v }
        return nil
    }
}

public enum BencodeError: Error, CustomStringConvertible {
    case truncated
    case invalid(String)
    case tooDeep

    public var description: String {
        switch self {
        case .truncated: return "bencode data ends early"
        case .invalid(let why): return "invalid bencode: \(why)"
        case .tooDeep: return "bencode nesting too deep"
        }
    }
}

/// Streaming decoder. Records where the top-level `info` value sits so the
/// info-hash can be computed over the exact bytes it was sent as.
public struct BencodeDecoder {
    private let bytes: [UInt8]
    public private(set) var position: Int
    public private(set) var infoRange: Range<Int>?

    public init(_ bytes: [UInt8], position: Int = 0) {
        self.bytes = bytes
        self.position = position
    }

    public mutating func decodeValue() throws -> BValue {
        try decode(depth: 0)
    }

    private mutating func decode(depth: Int) throws -> BValue {
        guard depth < 64 else { throw BencodeError.tooDeep }
        guard position < bytes.count else { throw BencodeError.truncated }
        switch bytes[position] {
        case UInt8(ascii: "i"):
            position += 1
            return .int(try readInteger(until: UInt8(ascii: "e")))
        case UInt8(ascii: "l"):
            position += 1
            var items: [BValue] = []
            while true {
                guard position < bytes.count else { throw BencodeError.truncated }
                if bytes[position] == UInt8(ascii: "e") { position += 1; break }
                items.append(try decode(depth: depth + 1))
            }
            return .list(items)
        case UInt8(ascii: "d"):
            position += 1
            var dict: [String: BValue] = [:]
            while true {
                guard position < bytes.count else { throw BencodeError.truncated }
                if bytes[position] == UInt8(ascii: "e") { position += 1; break }
                let key = String(decoding: try readByteString(), as: UTF8.self)
                let start = position
                let value = try decode(depth: depth + 1)
                if depth == 0 && key == "info" { infoRange = start..<position }
                dict[key] = value
            }
            return .dict(dict)
        case UInt8(ascii: "0")...UInt8(ascii: "9"):
            return .bytes(try readByteString())
        default:
            throw BencodeError.invalid("unexpected byte \(bytes[position]) at offset \(position)")
        }
    }

    private mutating func readInteger(until terminator: UInt8) throws -> Int64 {
        var negative = false
        var value: Int64 = 0
        var digits = 0
        if position < bytes.count && bytes[position] == UInt8(ascii: "-") {
            negative = true
            position += 1
        }
        while true {
            guard position < bytes.count else { throw BencodeError.truncated }
            let c = bytes[position]
            position += 1
            if c == terminator { break }
            guard c >= 48 && c <= 57 else { throw BencodeError.invalid("bad digit at offset \(position - 1)") }
            let (m, o1) = value.multipliedReportingOverflow(by: 10)
            let (a, o2) = m.addingReportingOverflow(Int64(c - 48))
            guard !o1 && !o2 else { throw BencodeError.invalid("integer overflow") }
            value = a
            digits += 1
        }
        guard digits > 0 else { throw BencodeError.invalid("empty integer") }
        return negative ? -value : value
    }

    private mutating func readByteString() throws -> [UInt8] {
        guard position < bytes.count, bytes[position] >= 48, bytes[position] <= 57 else {
            throw BencodeError.invalid("expected a byte string at offset \(position)")
        }
        let length = try readInteger(until: UInt8(ascii: ":"))
        guard length >= 0, length <= Int64(bytes.count - position) else { throw BencodeError.truncated }
        let end = position + Int(length)
        let s = Array(bytes[position..<end])
        position = end
        return s
    }
}

public enum Bencode {
    public static func decode(_ data: Data) throws -> BValue {
        var decoder = BencodeDecoder([UInt8](data))
        return try decoder.decodeValue()
    }

    public static func decode(_ bytes: [UInt8]) throws -> BValue {
        var decoder = BencodeDecoder(bytes)
        return try decoder.decodeValue()
    }

    /// Decodes one value from the front of `bytes`, returning it and how many
    /// bytes it took. Used where a value is followed by raw data (ut_metadata).
    public static func decodePrefix(_ bytes: [UInt8]) throws -> (BValue, Int) {
        var decoder = BencodeDecoder(bytes)
        let value = try decoder.decodeValue()
        return (value, decoder.position)
    }

    public static func encode(_ value: BValue) -> [UInt8] {
        var out: [UInt8] = []
        encode(value, into: &out)
        return out
    }

    private static func encode(_ value: BValue, into out: inout [UInt8]) {
        switch value {
        case .int(let v):
            out.append(UInt8(ascii: "i"))
            out.append(contentsOf: Array(String(v).utf8))
            out.append(UInt8(ascii: "e"))
        case .bytes(let b):
            out.append(contentsOf: Array(String(b.count).utf8))
            out.append(UInt8(ascii: ":"))
            out.append(contentsOf: b)
        case .list(let items):
            out.append(UInt8(ascii: "l"))
            for item in items { encode(item, into: &out) }
            out.append(UInt8(ascii: "e"))
        case .dict(let d):
            out.append(UInt8(ascii: "d"))
            let keys = d.keys.sorted { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }
            for key in keys {
                encode(.string(key), into: &out)
                encode(d[key]!, into: &out)
            }
            out.append(UInt8(ascii: "e"))
        }
    }
}
