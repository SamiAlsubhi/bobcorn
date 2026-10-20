import AVFoundation
import Foundation

/// Re-encodes audio as stereo AAC, for players that can't decode a file's own
/// audio: a Chromecast hands AC-3 and E-AC-3 to the TV, and most TVs refuse.
///
/// Segments are encoded one at a time, in any order, so each must join its
/// neighbours without a click. AAC frames lie on one grid of 1024 samples from
/// the track's start; a segment encodes from a little before its first frame
/// (the encoder's delay plus warm-up) and keeps exactly its own frames. The
/// audio of a segment starts a few frames after its video does, so that
/// warm-up comes from audio the segment holds anyway.
final class AACTranscoder: Sendable {
    /// What each segment encodes before its own frames: five AAC frames, less
    /// the encoder's delay.
    static let warmUpFrames = 5
    let rate: Int
    let origin: Int64
    let sampleEntry: Data
    private let inputDescription: AudioStreamBasicDescription
    private let inputLayout: AudioChannelLayoutTag

    /// How far a segment's audio starts after its first keyframe, in
    /// nanoseconds: room for the warm-up.
    var lead: Int64 { Int64(Self.warmUpFrames * 1024 + 64) * 1_000_000_000 / Int64(rate) }

    init?(_ plan: TrackPlan, firstFrame: Data, origin: Int64) {
        let id = plan.source.codecID
        var asbd = AudioStreamBasicDescription()
        var channels = plan.source.channels
        var layout = kAudioChannelLayoutTag_Stereo
        switch id {
        case "A_AC3":
            guard let h = Codecs.ac3Header(firstFrame) else { return nil }
            asbd.mFormatID = kAudioFormatAC3
            asbd.mSampleRate = Double(h.rate)
            asbd.mFramesPerPacket = 1536
            channels = h.channels
            layout = Self.layout(acmod: h.acmod, lfe: h.lfeon == 1)
        case "A_EAC3":
            guard let h = Codecs.eac3Header(firstFrame, at: 0) else { return nil }
            asbd.mFormatID = kAudioFormatEnhancedAC3
            asbd.mSampleRate = Double(h.rate)
            asbd.mFramesPerPacket = UInt32(h.blocks * 256)
            channels = h.channels
            layout = Self.layout(acmod: h.acmod, lfe: h.lfeon == 1)
        case "A_MPEG/L3":
            guard let h = Codecs.mpegAudioHeader(firstFrame) else { return nil }
            asbd.mFormatID = kAudioFormatMPEGLayer3
            asbd.mSampleRate = Double(h.rate)
            asbd.mFramesPerPacket = UInt32(h.samples)
            channels = h.channels
            layout = channels == 1 ? kAudioChannelLayoutTag_Mono : kAudioChannelLayoutTag_Stereo
        default:
            return nil
        }
        asbd.mChannelsPerFrame = UInt32(channels)
        inputDescription = asbd
        inputLayout = layout
        rate = Int(asbd.mSampleRate)
        self.origin = origin
        guard let index = Codecs.aacRates.firstIndex(of: rate) else { return nil }
        var b = BitWriter()
        b.write(2, 5) // AAC-LC
        b.write(UInt32(index), 4)
        b.write(2, 4) // stereo
        b.write(0, 3)
        let config = b.data
        sampleEntry = MP4.box("mp4a") { w in
            w.zeros(6)
            w.u16(1)
            w.zeros(8)
            w.u16(2)
            w.u16(16)
            w.u16(0)
            w.u16(0)
            w.u32(UInt32(min(asbd.mSampleRate, 65535)) << 16)
            w.bytes(Codecs.esds(objectType: 0x40, config: config))
        }
    }

    /// The codecs a Chromecast's receiver can't be counted on to play.
    static func needed(for codecID: String) -> Bool {
        ["A_AC3", "A_EAC3", "A_MPEG/L3"].contains(codecID)
    }

    private static func layout(acmod: UInt32, lfe: Bool) -> AudioChannelLayoutTag {
        switch (acmod, lfe) {
        case (1, false): return kAudioChannelLayoutTag_Mono
        case (2, false), (0, false): return kAudioChannelLayoutTag_Stereo
        case (3, false): return kAudioChannelLayoutTag_AC3_3_0
        case (4, false): return kAudioChannelLayoutTag_ITU_2_1
        case (5, false): return kAudioChannelLayoutTag_AC3_3_1
        case (6, false): return kAudioChannelLayoutTag_ITU_2_2
        case (7, false): return kAudioChannelLayoutTag_MPEG_5_0_C
        case (1, true): return kAudioChannelLayoutTag_AC3_1_0_1
        case (2, true), (0, true): return kAudioChannelLayoutTag_DVD_4
        case (3, true): return kAudioChannelLayoutTag_AC3_3_0_1
        case (4, true): return kAudioChannelLayoutTag_AC3_2_1_1
        case (5, true): return kAudioChannelLayoutTag_AC3_3_1_1
        case (6, true): return kAudioChannelLayoutTag_DVD_18
        default: return kAudioChannelLayoutTag_MPEG_5_1_C
        }
    }

    private func ticks(_ ns: Int64) -> Int64 { HLSRemuxer.ticks(ns, UInt32(rate)) }

    /// The AAC frames of the audio from `from` to `to` (nanoseconds; `.min` and
    /// nil for the ends of the file), made from `frames`, which must reach a
    /// little past both.
    func encode(_ frames: [(time: Int64, data: Data)], from: Int64, to: Int64?) throws -> FragmentTrack? {
        guard let first = frames.first else { return nil }
        let grid = ticks(origin)
        func frameIndex(atOrAfter ns: Int64) -> Int64 {
            let offset = ticks(ns) - grid
            return offset <= 0 ? 0 : (offset + 1023) / 1024
        }
        let pcm = try decode(frames)
        let pcmStart = ticks(first.time)
        let firstFrame = from == .min ? 0 : frameIndex(atOrAfter: from)
        let endFrame = to.map(frameIndex(atOrAfter:)) ?? max(firstFrame, (pcmStart + Int64(pcm.count) - grid) / 1024)
        guard endFrame > firstFrame else { return nil }

        let encoder = try makeEncoder()
        let delay = Int64(encoder.primeInfo.leadingFrames > 0 ? encoder.primeInfo.leadingFrames : 2112)
        let warmUp = Int64(Self.warmUpFrames) * 1024 - delay
        let start = grid + firstFrame * 1024 - warmUp
        let count = Int((endFrame - firstFrame) * 1024 + warmUp + delay + 1024)
        // The segment's stretch of the decoded audio, silent where it runs out.
        var left = [Float](repeating: 0, count: count)
        var right = [Float](repeating: 0, count: count)
        let offset = Int(start - pcmStart)
        for i in 0..<count {
            let j = offset + i
            if j >= 0 && j < pcm.count {
                left[i] = pcm.left[j]
                right[i] = pcm.right[j]
            }
        }
        let packets = try encode(left, right, with: encoder)
        let keep = Self.warmUpFrames..<(Self.warmUpFrames + Int(endFrame - firstFrame))
        guard keep.upperBound <= packets.count else { throw RemuxError.malformed("the AAC encoder came up short") }
        let samples = packets[keep].map { FragmentSample(data: $0, duration: 1024, compositionOffset: 0, sync: true) }
        return FragmentTrack(id: 2, baseDecodeTime: UInt64(max(0, grid + firstFrame * 1024)), samples: samples)
    }

    private struct PCM {
        var left: [Float] = []
        var right: [Float] = []
        var count: Int { left.count }
    }

    /// Decodes the frames back to back, mixed down to stereo.
    private func decode(_ frames: [(time: Int64, data: Data)]) throws -> PCM {
        var asbd = inputDescription
        let layout = AVAudioChannelLayout(layoutTag: inputLayout)
        guard let inFormat = layout.map({ AVAudioFormat(streamDescription: &asbd, channelLayout: $0) }) ?? AVAudioFormat(streamDescription: &asbd),
              let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: asbd.mSampleRate, channels: 2, interleaved: false),
              let decoder = AVAudioConverter(from: inFormat, to: outFormat)
        else { throw RemuxError.unsupportedAudio("its audio for the Chromecast") }
        decoder.downmix = true
        let maxSize = frames.map(\.data.count).max() ?? 0
        let input = AVAudioCompressedBuffer(format: inFormat, packetCapacity: AVAudioPacketCount(frames.count), maximumPacketSize: maxSize)
        var offset: Int64 = 0
        for (i, f) in frames.enumerated() {
            f.data.withUnsafeBytes { raw in
                input.data.advanced(by: Int(offset)).copyMemory(from: raw.baseAddress!, byteCount: f.data.count)
            }
            input.packetDescriptions![i] = AudioStreamPacketDescription(mStartOffset: offset, mVariableFramesInPacket: 0, mDataByteSize: UInt32(f.data.count))
            offset += Int64(f.data.count)
        }
        input.packetCount = AVAudioPacketCount(frames.count)
        input.byteLength = UInt32(offset)

        var pcm = PCM()
        // Room for all of it at once: a converter needn't keep half-used input.
        let chunk = AVAudioFrameCount(frames.count) * asbd.mFramesPerPacket + 8192
        var given = false
        while true {
            guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: chunk) else { break }
            var error: NSError?
            let status = decoder.convert(to: out, error: &error) { _, inputStatus in
                if given {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                given = true
                inputStatus.pointee = .haveData
                return input
            }
            if let error { throw error }
            let n = Int(out.frameLength)
            if n > 0, let channels = out.floatChannelData {
                pcm.left += UnsafeBufferPointer(start: channels[0], count: n)
                pcm.right += UnsafeBufferPointer(start: channels[1], count: n)
            }
            if status == .endOfStream || status == .error || (status == .inputRanDry && n == 0) { break }
        }
        return pcm
    }

    private var aacFormat: AVAudioFormat? {
        var asbd = AudioStreamBasicDescription(mSampleRate: Double(rate), mFormatID: kAudioFormatMPEG4AAC, mFormatFlags: 0,
                                               mBytesPerPacket: 0, mFramesPerPacket: 1024, mBytesPerFrame: 0,
                                               mChannelsPerFrame: 2, mBitsPerChannel: 0, mReserved: 0)
        return AVAudioFormat(streamDescription: &asbd)
    }

    private func makeEncoder() throws -> AVAudioConverter {
        guard let pcm = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(rate), channels: 2, interleaved: false),
              let aac = aacFormat, let encoder = AVAudioConverter(from: pcm, to: aac)
        else { throw RemuxError.unsupportedAudio("AAC for the Chromecast") }
        encoder.bitRate = 192_000
        return encoder
    }

    /// Every AAC frame the encoder makes of the samples, flushed at the end.
    private func encode(_ left: [Float], _ right: [Float], with encoder: AVAudioConverter) throws -> [Data] {
        let format = encoder.inputFormat
        guard let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(left.count)),
              let channels = input.floatChannelData, let aac = aacFormat
        else { return [] }
        input.frameLength = AVAudioFrameCount(left.count)
        left.withUnsafeBufferPointer { channels[0].update(from: $0.baseAddress!, count: left.count) }
        right.withUnsafeBufferPointer { channels[1].update(from: $0.baseAddress!, count: right.count) }

        var packets: [Data] = []
        var given = false
        let capacity = AVAudioPacketCount(left.count / 1024 + 16)
        while true {
            let out = AVAudioCompressedBuffer(format: aac, packetCapacity: capacity, maximumPacketSize: max(encoder.maximumOutputPacketSize, 1536))
            var error: NSError?
            let status = encoder.convert(to: out, error: &error) { _, inputStatus in
                if given {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                given = true
                inputStatus.pointee = .haveData
                return input
            }
            if let error { throw error }
            if let descriptions = out.packetDescriptions {
                for i in 0..<Int(out.packetCount) {
                    let d = descriptions[i]
                    packets.append(Data(bytes: out.data.advanced(by: Int(d.mStartOffset)), count: Int(d.mDataByteSize)))
                }
            }
            if status == .endOfStream || status == .error || (status == .inputRanDry && out.packetCount == 0) { break }
        }
        return packets
    }
}
