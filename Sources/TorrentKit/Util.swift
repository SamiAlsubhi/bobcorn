import CryptoKit
import Foundation

enum SHA1Digest {
    static func hash(_ bytes: [UInt8]) -> [UInt8] { Array(Insecure.SHA1.hash(data: bytes)) }
    static func hash(_ data: Data) -> [UInt8] { Array(Insecure.SHA1.hash(data: data)) }
}

extension Array where Element == UInt8 {
    var hexString: String {
        let digits = Array("0123456789abcdef".utf8)
        var out = [UInt8]()
        out.reserveCapacity(count * 2)
        for b in self {
            out.append(digits[Int(b >> 4)])
            out.append(digits[Int(b & 0x0f)])
        }
        return String(decoding: out, as: UTF8.self)
    }

    init?(hex: String) {
        let chars = Array(hex.utf8)
        guard chars.count % 2 == 0 else { return nil }
        func nibble(_ c: UInt8) -> UInt8? {
            switch c {
            case 48...57: return c - 48
            case 65...70: return c - 55
            case 97...102: return c - 87
            default: return nil
            }
        }
        var out = [UInt8]()
        out.reserveCapacity(chars.count / 2)
        var i = 0
        while i < chars.count {
            guard let hi = nibble(chars[i]), let lo = nibble(chars[i + 1]) else { return nil }
            out.append(hi << 4 | lo)
            i += 2
        }
        self = out
    }

    func uint32BE(at i: Int) -> UInt32 {
        UInt32(self[i]) << 24 | UInt32(self[i + 1]) << 16 | UInt32(self[i + 2]) << 8 | UInt32(self[i + 3])
    }

    func uint16BE(at i: Int) -> UInt16 {
        UInt16(self[i]) << 8 | UInt16(self[i + 1])
    }

    func uint64BE(at i: Int) -> UInt64 {
        UInt64(uint32BE(at: i)) << 32 | UInt64(uint32BE(at: i + 4))
    }

    mutating func appendBE(_ v: UInt32) {
        append(UInt8(truncatingIfNeeded: v >> 24))
        append(UInt8(truncatingIfNeeded: v >> 16))
        append(UInt8(truncatingIfNeeded: v >> 8))
        append(UInt8(truncatingIfNeeded: v))
    }

    mutating func appendBE(_ v: UInt16) {
        append(UInt8(truncatingIfNeeded: v >> 8))
        append(UInt8(truncatingIfNeeded: v))
    }

    mutating func appendBE(_ v: UInt64) {
        appendBE(UInt32(truncatingIfNeeded: v >> 32))
        appendBE(UInt32(truncatingIfNeeded: v))
    }
}

enum Base32 {
    static func decode(_ string: String) -> [UInt8]? {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567".utf8)
        var lookup = [UInt8: UInt8]()
        for (i, c) in alphabet.enumerated() { lookup[c] = UInt8(i) }
        var buffer: UInt32 = 0
        var bits = 0
        var out = [UInt8]()
        for c in string.uppercased().utf8 where c != UInt8(ascii: "=") {
            guard let v = lookup[c] else { return nil }
            buffer = buffer << 5 | UInt32(v)
            bits += 5
            if bits >= 8 {
                bits -= 8
                out.append(UInt8(truncatingIfNeeded: buffer >> UInt32(bits)))
            }
        }
        return out
    }
}

func randomBytes(_ count: Int) -> [UInt8] {
    var g = SystemRandomNumberGenerator()
    return (0..<count).map { _ in UInt8.random(in: 0...255, using: &g) }
}

/// Bytes-per-second over a short sliding window.
struct RateMeter {
    private var buckets = [Int64](repeating: 0, count: 6)
    private var bucketSecond = Int(Date().timeIntervalSince1970)
    private(set) var total: Int64 = 0

    mutating func add(_ bytes: Int) {
        roll()
        buckets[bucketSecond % buckets.count] += Int64(bytes)
        total += Int64(bytes)
    }

    mutating func rate() -> Double {
        roll()
        let now = bucketSecond
        var sum: Int64 = 0
        // Skip the current, partial second.
        for s in (now - 5)..<now { sum += buckets[((s % buckets.count) + buckets.count) % buckets.count] }
        return Double(sum) / 5
    }

    private mutating func roll() {
        let now = Int(Date().timeIntervalSince1970)
        if now == bucketSecond { return }
        if now - bucketSecond >= buckets.count {
            for i in buckets.indices { buckets[i] = 0 }
        } else {
            var s = bucketSecond + 1
            while s <= now {
                buckets[s % buckets.count] = 0
                s += 1
            }
        }
        bucketSecond = now
    }
}

/// A fixed-size bit set with a maintained population count.
struct Bitfield: Equatable {
    private(set) var bytes: [UInt8]
    let count: Int
    private(set) var setCount: Int = 0

    init(count: Int) {
        self.count = count
        bytes = [UInt8](repeating: 0, count: (count + 7) / 8)
    }

    init(bytes raw: [UInt8], count: Int) {
        self.count = count
        var b = [UInt8](repeating: 0, count: (count + 7) / 8)
        for i in 0..<min(b.count, raw.count) { b[i] = raw[i] }
        // Spare bits past `count` must be clear.
        if count % 8 != 0, !b.isEmpty {
            b[b.count - 1] &= UInt8(truncatingIfNeeded: 0xff << (8 - count % 8))
        }
        bytes = b
        setCount = b.reduce(0) { $0 + $1.nonzeroBitCount }
    }

    subscript(i: Int) -> Bool {
        get { bytes[i >> 3] & (0x80 >> UInt8(i & 7)) != 0 }
        set {
            let mask: UInt8 = 0x80 >> UInt8(i & 7)
            let was = bytes[i >> 3] & mask != 0
            if newValue == was { return }
            if newValue {
                bytes[i >> 3] |= mask
                setCount += 1
            } else {
                bytes[i >> 3] &= ~mask
                setCount -= 1
            }
        }
    }

    var isComplete: Bool { setCount == count }
}

/// Resumes a continuation at most once, from whichever path gets there first.
final class OnceGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}

func formatBytes(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}
