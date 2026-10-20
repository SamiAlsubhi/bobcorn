import Foundation

/// Big-endian bytes for MP4 boxes.
struct ByteWriter {
    var data = Data()

    mutating func u8(_ v: UInt8) { data.append(v) }
    mutating func u16(_ v: UInt16) { data.append(contentsOf: [UInt8(v >> 8), UInt8(v & 0xFF)]) }
    mutating func u24(_ v: UInt32) { data.append(contentsOf: [UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)]) }
    mutating func u32(_ v: UInt32) { data.append(contentsOf: (0..<4).map { UInt8(v >> (24 - 8 * $0) & 0xFF) }) }
    mutating func u64(_ v: UInt64) { data.append(contentsOf: (0..<8).map { UInt8(v >> (56 - 8 * $0) & 0xFF) }) }
    mutating func i32(_ v: Int32) { u32(UInt32(bitPattern: v)) }
    mutating func fourCC(_ s: String) { data.append(contentsOf: Array(s.utf8.prefix(4))) }
    mutating func bytes(_ d: Data) { data.append(d) }
    mutating func zeros(_ n: Int) { data.append(Data(count: n)) }
}

/// Bits in, most significant first.
struct BitReader {
    let data: Data
    private(set) var bit = 0

    init(_ data: Data, byte: Int = 0) {
        self.data = Data(data)
        bit = byte * 8
    }

    var remaining: Int { data.count * 8 - bit }

    mutating func read(_ n: Int) -> UInt32? {
        guard n <= remaining else { return nil }
        var v: UInt32 = 0
        for _ in 0..<n {
            let byte = data[bit >> 3]
            v = v << 1 | UInt32(byte >> (7 - UInt8(bit & 7)) & 1)
            bit += 1
        }
        return v
    }

    mutating func skip(_ n: Int) { bit += n }
}

/// Bits out, most significant first.
struct BitWriter {
    private(set) var data = Data()
    private var bits = 0

    mutating func write(_ v: UInt32, _ n: Int) {
        for i in stride(from: n - 1, through: 0, by: -1) {
            if bits % 8 == 0 { data.append(0) }
            if v >> UInt32(i) & 1 == 1 { data[data.count - 1] |= 1 << (7 - UInt8(bits % 8)) }
            bits += 1
        }
    }
}

/// One sample of a fragment.
struct FragmentSample {
    let data: Data
    let duration: UInt32
    let compositionOffset: Int32
    let sync: Bool
}

struct FragmentTrack {
    let id: UInt32
    let baseDecodeTime: UInt64
    let samples: [FragmentSample]
}

enum MP4 {
    static func box(_ type: String, _ build: (inout ByteWriter) -> Void) -> Data {
        var body = ByteWriter()
        build(&body)
        var w = ByteWriter()
        w.u32(UInt32(8 + body.data.count))
        w.fourCC(type)
        w.bytes(body.data)
        return w.data
    }

    static func box(_ type: String, _ body: Data) -> Data {
        box(type) { $0.bytes(body) }
    }

    static func fullBox(_ type: String, version: UInt8 = 0, flags: UInt32 = 0, _ build: (inout ByteWriter) -> Void) -> Data {
        box(type) { w in
            w.u8(version)
            w.u24(flags)
            build(&w)
        }
    }

    private static let identity: [UInt32] = [0x0001_0000, 0, 0, 0, 0x0001_0000, 0, 0, 0, 0x4000_0000]

    /// `ftyp` and `moov` describing the tracks, numbered from 1, with no
    /// samples: they all come in fragments.
    static func initSegment(_ tracks: [TrackPlan]) -> Data {
        var out = box("ftyp") { w in
            w.fourCC("iso6")
            w.u32(0)
            for brand in ["iso6", "isom", "mp41"] { w.fourCC(brand) }
        }
        out += box("moov") { moov in
            moov.bytes(fullBox("mvhd") { w in
                w.u32(0); w.u32(0)
                w.u32(1000)
                w.u32(0)
                w.u32(0x0001_0000)
                w.u16(0x0100)
                w.zeros(10)
                identity.forEach { w.u32($0) }
                w.zeros(24)
                w.u32(UInt32(tracks.count + 1))
            })
            for (i, t) in tracks.enumerated() {
                moov.bytes(trak(t, id: UInt32(i + 1)))
            }
            moov.bytes(box("mvex") { mvex in
                for i in tracks.indices {
                    mvex.bytes(fullBox("trex") { w in
                        w.u32(UInt32(i + 1))
                        w.u32(1)
                        w.u32(0); w.u32(0); w.u32(0)
                    })
                }
            })
        }
        return out
    }

    private static func trak(_ t: TrackPlan, id: UInt32) -> Data {
        box("trak") { trak in
            trak.bytes(fullBox("tkhd", flags: 0x7) { w in
                w.u32(0); w.u32(0)
                w.u32(id)
                w.u32(0)
                w.u32(0)
                w.zeros(8)
                w.u16(0)
                w.u16(t.isVideo ? 0 : 1)
                w.u16(t.isVideo ? 0 : 0x0100)
                w.u16(0)
                identity.forEach { w.u32($0) }
                w.u32(UInt32(t.displayWidth) << 16)
                w.u32(UInt32(t.displayHeight) << 16)
            })
            trak.bytes(box("mdia") { mdia in
                mdia.bytes(fullBox("mdhd") { w in
                    w.u32(0); w.u32(0)
                    w.u32(t.timescale)
                    w.u32(0)
                    w.u16(packedLanguage(t.source.language))
                    w.u16(0)
                })
                mdia.bytes(fullBox("hdlr") { w in
                    w.u32(0)
                    w.fourCC(t.isVideo ? "vide" : "soun")
                    w.zeros(12)
                    w.bytes(Data((t.isVideo ? "VideoHandler" : "SoundHandler").utf8))
                    w.u8(0)
                })
                mdia.bytes(box("minf") { minf in
                    if t.isVideo {
                        minf.bytes(fullBox("vmhd", flags: 1) { $0.zeros(8) })
                    } else {
                        minf.bytes(fullBox("smhd") { $0.zeros(4) })
                    }
                    minf.bytes(box("dinf") { dinf in
                        dinf.bytes(fullBox("dref") { w in
                            w.u32(1)
                            w.bytes(fullBox("url ", flags: 1) { _ in })
                        })
                    })
                    minf.bytes(box("stbl") { stbl in
                        stbl.bytes(fullBox("stsd") { w in
                            w.u32(1)
                            w.bytes(t.sampleEntry)
                        })
                        stbl.bytes(fullBox("stts") { $0.u32(0) })
                        stbl.bytes(fullBox("stsc") { $0.u32(0) })
                        stbl.bytes(fullBox("stsz") { $0.u32(0); $0.u32(0) })
                        stbl.bytes(fullBox("stco") { $0.u32(0) })
                    })
                })
            })
        }
    }

    /// ISO 639-2/T in three 5-bit letters.
    static func packedLanguage(_ code: String?) -> UInt16 {
        var letters = Array((code ?? "und").lowercased().utf8.prefix(3))
        if letters.count != 3 || !letters.allSatisfy({ (0x61...0x7A).contains($0) }) { letters = Array("und".utf8) }
        return letters.reduce(0) { $0 << 5 | UInt16($1 - 0x60) }
    }

    /// `moof` and `mdat` for one segment: each track's samples, back to back.
    static func fragment(sequence: UInt32, tracks: [FragmentTrack]) -> Data {
        func moof(_ offsets: [Int32]) -> Data {
            box("moof") { moof in
                moof.bytes(fullBox("mfhd") { $0.u32(sequence) })
                for (t, offset) in zip(tracks, offsets) {
                    moof.bytes(box("traf") { traf in
                        // The default base is the moof itself.
                        traf.bytes(fullBox("tfhd", flags: 0x02_0000) { $0.u32(t.id) })
                        traf.bytes(fullBox("tfdt", version: 1) { $0.u64(t.baseDecodeTime) })
                        traf.bytes(fullBox("trun", version: 1, flags: 0x000F01) { w in
                            w.u32(UInt32(t.samples.count))
                            w.i32(offset)
                            for s in t.samples {
                                w.u32(s.duration)
                                w.u32(UInt32(s.data.count))
                                w.u32(s.sync ? 0x0200_0000 : 0x0101_0000)
                                w.i32(s.compositionOffset)
                            }
                        })
                    })
                }
            }
        }
        let header = moof(Array(repeating: 0, count: tracks.count))
        var offsets: [Int32] = []
        var at = header.count + 8
        for t in tracks {
            offsets.append(Int32(at))
            at += t.samples.reduce(0) { $0 + $1.data.count }
        }
        var w = ByteWriter()
        w.u32(UInt32(at - header.count))
        w.fourCC("mdat")
        for t in tracks { for s in t.samples { w.bytes(s.data) } }
        return moof(offsets) + w.data
    }
}
