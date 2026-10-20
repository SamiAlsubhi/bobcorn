import Foundation
import CoreMedia
import VideoToolbox

/// How many samples, in the track's timescale, an audio frame holds.
enum FrameDuration: Sendable {
    case fixed(Int)
    case eac3
    case opus

    func samples(_ frame: Data) -> Int? {
        switch self {
        case .fixed(let n): return n
        case .eac3: return Codecs.eac3Samples(frame)
        case .opus: return Codecs.opusSamples(frame)
        }
    }
}

/// A Matroska track as an MP4 track.
struct TrackPlan: Sendable {
    let source: MKVTrack
    let isVideo: Bool
    let timescale: UInt32
    let sampleEntry: Data
    let codecName: String
    let frameDuration: FrameDuration
    let displayWidth: Int
    let displayHeight: Int
}

enum Codecs {
    // MARK: Names

    /// What a codec ID is called in a message.
    static func name(_ codecID: String) -> String {
        switch codecID {
        case "V_MPEG4/ISO/AVC": return "H.264"
        case "V_MPEGH/ISO/HEVC": return "HEVC"
        case "V_AV1": return "AV1"
        case "V_VP9": return "VP9"
        case "V_VP8": return "VP8"
        case "V_MPEG4/ISO/ASP", "V_MPEG4/ISO/SP", "V_MPEG4/ISO/AP", "V_MS/VFW/FOURCC": return "MPEG-4 Part 2 (XviD/DivX)"
        case "V_MPEG1", "V_MPEG2": return "MPEG-2"
        case "V_THEORA": return "Theora"
        case "V_REAL/RV10", "V_REAL/RV20", "V_REAL/RV30", "V_REAL/RV40": return "RealVideo"
        case "A_AC3": return "AC-3"
        case "A_EAC3": return "E-AC-3"
        case "A_MPEG/L3": return "MP3"
        case "A_MPEG/L2": return "MP2"
        case "A_OPUS": return "Opus"
        case "A_FLAC": return "FLAC"
        case "A_VORBIS": return "Vorbis"
        case "A_TRUEHD", "A_MLP": return "Dolby TrueHD"
        case "A_ALAC": return "ALAC"
        default:
            if codecID.hasPrefix("A_AAC") { return "AAC" }
            if codecID.hasPrefix("A_DTS") { return "DTS" }
            if codecID.hasPrefix("A_PCM") { return "PCM" }
            return codecID
        }
    }

    static func audioSupported(_ t: MKVTrack) -> Bool {
        guard !t.unsupportedEncoding else { return false }
        return t.codecID.hasPrefix("A_AAC") || ["A_AC3", "A_EAC3", "A_MPEG/L3", "A_MPEG/L2", "A_OPUS"].contains(t.codecID)
    }

    // MARK: Video

    static func video(_ t: MKVTrack) throws -> TrackPlan {
        guard !t.unsupportedEncoding else { throw RemuxError.encrypted }
        let fourCC: String
        let config: String
        switch t.codecID {
        case "V_MPEG4/ISO/AVC": (fourCC, config) = ("avc1", "avcC")
        case "V_MPEGH/ISO/HEVC": (fourCC, config) = ("hvc1", "hvcC")
        case "V_AV1":
            guard VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1) else {
                throw RemuxError.unsupportedVideo("AV1 (it needs a Mac with an M3 chip or later)")
            }
            (fourCC, config) = ("av01", "av1C")
        default:
            throw RemuxError.unsupportedVideo(name(t.codecID))
        }
        guard let codecPrivate = t.codecPrivate, !codecPrivate.isEmpty, t.width > 0, t.height > 0 else {
            throw RemuxError.malformed("the video track has no decoder setup")
        }
        // A display size that isn't the coded one: anamorphic video.
        var aspect: (h: Int, v: Int)?
        if let dw = t.displayWidth, let dh = t.displayHeight, dw > 0, dh > 0, dw * t.height != dh * t.width {
            let h = dw * t.height
            let v = dh * t.width
            let g = gcd(h, v)
            aspect = (h / g, v / g)
        }
        let entry = MP4.box(fourCC) { w in
            w.zeros(6)
            w.u16(1)
            w.zeros(16)
            w.u16(UInt16(clamping: t.width))
            w.u16(UInt16(clamping: t.height))
            w.u32(0x0048_0000)
            w.u32(0x0048_0000)
            w.u32(0)
            w.u16(1)
            w.zeros(32)
            w.u16(0x0018)
            w.u16(0xFFFF)
            w.bytes(MP4.box(config, codecPrivate))
            if let c = t.colour, c.primaries != 2 || c.transfer != 2 || c.matrix != 2 {
                w.bytes(MP4.box("colr") { b in
                    b.fourCC("nclx")
                    b.u16(UInt16(clamping: c.primaries))
                    b.u16(UInt16(clamping: c.transfer))
                    b.u16(UInt16(clamping: c.matrix))
                    b.u8(c.range == 2 ? 0x80 : 0)
                })
            }
            if let aspect {
                w.bytes(MP4.box("pasp") { b in
                    b.u32(UInt32(clamping: aspect.h))
                    b.u32(UInt32(clamping: aspect.v))
                })
            }
        }
        let displayWidth = aspect.map { t.width * $0.h / $0.v } ?? t.width
        return TrackPlan(source: t, isVideo: true, timescale: 90000, sampleEntry: entry, codecName: name(t.codecID),
                         frameDuration: .fixed(0), displayWidth: displayWidth, displayHeight: t.height)
    }

    private static func gcd(_ a: Int, _ b: Int) -> Int { b == 0 ? max(1, a) : gcd(b, a % b) }

    // MARK: Audio

    /// `firstFrame` is the track's first frame, for codecs whose setup is
    /// only in their frames.
    static func audio(_ t: MKVTrack, firstFrame: Data?) throws -> TrackPlan {
        guard audioSupported(t) else { throw RemuxError.unsupportedAudio(name(t.codecID)) }
        var rate = Int(t.sampleRate.rounded())
        var channels = t.channels
        let child: Data
        let duration: FrameDuration
        switch t.codecID {
        case "A_AC3":
            guard let f = firstFrame, let h = ac3Header(f) else { throw RemuxError.malformed("no AC-3 frame header") }
            rate = h.rate
            channels = h.channels
            var b = BitWriter()
            b.write(h.fscod, 2); b.write(h.bsid, 5); b.write(h.bsmod, 3); b.write(h.acmod, 3); b.write(h.lfeon, 1)
            b.write(h.bitRateCode, 5); b.write(0, 5)
            child = MP4.box("dac3", b.data)
            duration = .fixed(1536)
        case "A_EAC3":
            guard let f = firstFrame, let h = eac3Header(f, at: 0) else { throw RemuxError.malformed("no E-AC-3 frame header") }
            rate = h.rate
            channels = h.channels
            let dependents = eac3Dependents(f)
            var b = BitWriter()
            let kbps = h.frameBytes * 8 * h.rate / (h.blocks * 256) / 1000
            b.write(UInt32(clamping: kbps), 13); b.write(0, 3)
            b.write(h.fscod, 2); b.write(h.bsid, 5); b.write(0, 1); b.write(0, 1); b.write(0, 3)
            b.write(h.acmod, 3); b.write(h.lfeon, 1); b.write(0, 3)
            if dependents > 0 {
                // Usually a 7.1 mix: the extra pair is the rear surrounds.
                b.write(UInt32(dependents), 4); b.write(0x002, 9)
                channels = max(channels, 8)
            } else {
                b.write(0, 4); b.write(0, 1)
            }
            child = MP4.box("dec3", b.data)
            duration = .eac3
        case "A_MPEG/L3", "A_MPEG/L2":
            guard let f = firstFrame, let h = mpegAudioHeader(f) else { throw RemuxError.malformed("no MPEG audio frame header") }
            rate = h.rate
            channels = h.channels
            child = esds(objectType: h.mpeg1 ? 0x6B : 0x69, config: nil)
            duration = .fixed(h.samples)
        case "A_OPUS":
            guard let head = t.codecPrivate, head.count >= 19, head.prefix(8) == Data("OpusHead".utf8) else {
                throw RemuxError.malformed("no Opus header")
            }
            let h = [UInt8](head)
            channels = Int(h[9])
            rate = 48000
            child = MP4.box("dOps") { w in
                w.u8(0)
                w.u8(h[9])
                w.u16(UInt16(h[10]) | UInt16(h[11]) << 8)
                w.u32(UInt32(h[12]) | UInt32(h[13]) << 8 | UInt32(h[14]) << 16 | UInt32(h[15]) << 24)
                w.u16(UInt16(h[16]) | UInt16(h[17]) << 8)
                w.u8(h[18])
                if h[18] != 0, h.count >= 21 + Int(h[9]) { w.bytes(Data(h[19..<(21 + Int(h[9]))])) }
            }
            duration = .opus
        default: // AAC
            let config = t.codecPrivate.flatMap { $0.isEmpty ? nil : $0 } ?? legacyAACConfig(t)
            guard let config, let asc = aacConfig(config) else { throw RemuxError.malformed("no AAC setup") }
            rate = asc.rate
            if asc.channels > 0 { channels = asc.channels }
            child = esds(objectType: 0x40, config: config)
            duration = .fixed(asc.frameLength)
        }
        // AVFoundation takes MPEG audio in the QuickTime form, with no esds.
        let entryType = ["A_AC3": "ac-3", "A_EAC3": "ec-3", "A_OPUS": "Opus", "A_MPEG/L3": ".mp3"][t.codecID] ?? "mp4a"
        let entry = MP4.box(entryType) { w in
            w.zeros(6)
            w.u16(1)
            w.zeros(8)
            w.u16(UInt16(clamping: channels))
            w.u16(16)
            w.u16(0)
            w.u16(0)
            w.u32(UInt32(clamping: min(rate, 65535)) << 16)
            if entryType != ".mp3" { w.bytes(child) }
        }
        return TrackPlan(source: t, isVideo: false, timescale: UInt32(max(1, rate)), sampleEntry: entry,
                         codecName: name(t.codecID), frameDuration: duration, displayWidth: 0, displayHeight: 0)
    }

    /// An MPEG-4 elementary stream descriptor.
    static func esds(objectType: UInt8, config: Data?) -> Data {
        func descriptor(_ tag: UInt8, _ body: Data) -> Data {
            var d = Data([tag])
            var length = body.count
            var bytes: [UInt8] = [UInt8(length & 0x7F)]
            length >>= 7
            while length > 0 {
                bytes.insert(UInt8(length & 0x7F) | 0x80, at: 0)
                length >>= 7
            }
            d.append(contentsOf: bytes)
            return d + body
        }
        var decoderConfig = ByteWriter()
        decoderConfig.u8(objectType)
        decoderConfig.u8(0x15) // audio stream
        decoderConfig.u24(0)
        decoderConfig.u32(0)
        decoderConfig.u32(0)
        if let config { decoderConfig.bytes(descriptor(0x05, config)) }
        var es = ByteWriter()
        es.u16(0)
        es.u8(0)
        es.bytes(descriptor(0x04, decoderConfig.data))
        es.bytes(descriptor(0x06, Data([0x02])))
        return MP4.fullBox("esds") { $0.bytes(descriptor(0x03, es.data)) }
    }

    // MARK: AAC

    static let aacRates = [96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350]

    /// An AudioSpecificConfig: the core rate, channels and frame length.
    static func aacConfig(_ d: Data) -> (rate: Int, channels: Int, frameLength: Int)? {
        var r = BitReader(d)
        func objectType() -> UInt32? {
            guard let t = r.read(5) else { return nil }
            return t == 31 ? r.read(6).map { 32 + $0 } : t
        }
        func rate() -> Int? {
            guard let i = r.read(4) else { return nil }
            if i == 15 { return r.read(24).map(Int.init) }
            return Int(i) < aacRates.count ? aacRates[Int(i)] : nil
        }
        guard var type = objectType(), let core = rate(), let channels = r.read(4) else { return nil }
        if type == 5 || type == 29 {
            // Explicit SBR: the extension rate, then the core object type.
            guard rate() != nil, let t = objectType() else { return nil }
            type = t
        }
        var frameLength = 1024
        if [1, 2, 3, 4, 6, 7, 17, 19, 20, 21, 22, 23].contains(type), r.read(1) == 1 { frameLength = 960 }
        return (core, Int(channels), frameLength)
    }

    /// Old Matroska files name the AAC profile instead of storing a config.
    static func legacyAACConfig(_ t: MKVTrack) -> Data? {
        let id = t.codecID
        guard id.hasPrefix("A_AAC/") else { return nil }
        let type: UInt32 = id.contains("/MAIN") ? 1 : id.contains("/SSR") ? 3 : id.contains("/LTP") ? 4 : 2
        func index(_ rate: Double) -> UInt32 { UInt32(aacRates.firstIndex(of: Int(rate.rounded())) ?? 3) }
        var b = BitWriter()
        if id.hasSuffix("/SBR") {
            b.write(5, 5)
            b.write(index(t.sampleRate), 4)
            b.write(UInt32(min(t.channels, 7)), 4)
            b.write(index(t.outputSampleRate ?? t.sampleRate * 2), 4)
            b.write(2, 5)
        } else {
            b.write(type, 5)
            b.write(index(t.sampleRate), 4)
            b.write(UInt32(min(t.channels, 7)), 4)
        }
        b.write(0, 3)
        return b.data
    }

    // MARK: AC-3 and E-AC-3

    private static let ac3Rates = [48000, 44100, 32000]
    private static let acmodChannels = [2, 1, 2, 3, 3, 4, 4, 5]

    struct AC3Header {
        let fscod, bsid, bsmod, acmod, lfeon, bitRateCode: UInt32
        let rate: Int
        var channels: Int { acmodChannels[Int(acmod)] + Int(lfeon) }
    }

    static func ac3Header(_ f: Data) -> AC3Header? {
        let b = [UInt8](f.prefix(8))
        guard b.count >= 7, b[0] == 0x0B, b[1] == 0x77 else { return nil }
        let fscod = UInt32(b[4] >> 6)
        guard fscod < 3 else { return nil }
        var r = BitReader(f, byte: 6)
        guard let acmod = r.read(3) else { return nil }
        if acmod & 1 != 0 && acmod != 1 { r.skip(2) }
        if acmod & 4 != 0 { r.skip(2) }
        if acmod == 2 { r.skip(2) }
        guard let lfeon = r.read(1) else { return nil }
        return AC3Header(fscod: fscod, bsid: UInt32(b[5] >> 3), bsmod: UInt32(b[5] & 7), acmod: acmod, lfeon: lfeon,
                         bitRateCode: UInt32(b[4] & 0x3F) >> 1, rate: ac3Rates[Int(fscod)])
    }

    struct EAC3Header {
        let streamType: UInt32
        let frameBytes: Int
        let fscod, acmod, lfeon, bsid: UInt32
        let rate: Int
        let blocks: Int
        var channels: Int { acmodChannels[Int(acmod)] + Int(lfeon) }
    }

    static func eac3Header(_ f: Data, at offset: Int) -> EAC3Header? {
        guard offset + 6 <= f.count else { return nil }
        var r = BitReader(f, byte: offset)
        guard r.read(16) == 0x0B77, let streamType = r.read(2), r.read(3) != nil, let frmsiz = r.read(11),
              let fscod = r.read(2) else { return nil }
        var rate: Int
        var blocks: Int
        if fscod == 3 {
            guard let fscod2 = r.read(2), fscod2 < 3 else { return nil }
            rate = ac3Rates[Int(fscod2)] / 2
            blocks = 6
        } else {
            guard let code = r.read(2) else { return nil }
            rate = ac3Rates[Int(fscod)]
            blocks = [1, 2, 3, 6][Int(code)]
        }
        guard let acmod = r.read(3), let lfeon = r.read(1), let bsid = r.read(5) else { return nil }
        if rate == 0 { rate = 48000 }
        return EAC3Header(streamType: streamType, frameBytes: Int(frmsiz + 1) * 2, fscod: fscod == 3 ? 3 : fscod,
                          acmod: acmod, lfeon: lfeon, bsid: bsid, rate: rate, blocks: blocks)
    }

    /// The samples in a block of E-AC-3, which may hold several syncframes:
    /// those of independent substreams count, dependent ones overlay them.
    static func eac3Samples(_ f: Data) -> Int? {
        var offset = 0
        var total = 0
        var seen = false
        while let h = eac3Header(f, at: offset) {
            if h.streamType != 1 { total += h.blocks * 256 }
            seen = true
            offset += h.frameBytes
        }
        return seen && total > 0 ? total : nil
    }

    static func eac3Dependents(_ f: Data) -> Int {
        var offset = 0
        var count = 0
        while let h = eac3Header(f, at: offset) {
            if h.streamType == 1 { count += 1 }
            offset += h.frameBytes
        }
        return count
    }

    // MARK: MPEG audio

    static func mpegAudioHeader(_ f: Data) -> (mpeg1: Bool, rate: Int, channels: Int, samples: Int)? {
        let b = [UInt8](f.prefix(4))
        guard b.count == 4, b[0] == 0xFF, b[1] & 0xE0 == 0xE0 else { return nil }
        let version = (b[1] >> 3) & 3 // 3: MPEG-1, 2: MPEG-2, 0: MPEG-2.5
        let layer = (b[1] >> 1) & 3   // 1: III, 2: II, 3: I
        let rateIndex = Int((b[2] >> 2) & 3)
        guard version != 1, layer != 0, rateIndex < 3 else { return nil }
        let rates = version == 3 ? [44100, 48000, 32000] : version == 2 ? [22050, 24000, 16000] : [11025, 12000, 8000]
        let samples = layer == 3 ? 384 : layer == 2 ? 1152 : (version == 3 ? 1152 : 576)
        return (version == 3, rates[rateIndex], b[3] >> 6 == 3 ? 1 : 2, samples)
    }

    // MARK: Opus

    /// From the packet's table-of-contents byte, at 48 kHz.
    static func opusSamples(_ f: Data) -> Int? {
        guard let toc = f.first else { return nil }
        let config = Int(toc >> 3)
        let frame: Int
        switch config {
        case 0...11: frame = [480, 960, 1920, 2880][config % 4]
        case 12...15: frame = [480, 960][config % 2]
        default: frame = [120, 240, 480, 960][config % 4]
        }
        switch toc & 3 {
        case 0: return frame
        case 1, 2: return frame * 2
        default:
            guard f.count > 1 else { return nil }
            return frame * Int(f[f.startIndex + 1] & 0x3F)
        }
    }
}
