import AVFoundation
import VideoToolbox
import XCTest
@testable import Remux

final class EBMLTests: XCTestCase {
    func testVariableLengthIntegers() {
        XCTAssertEqual(EBML.vint(Data([0x81]), 0)?.value, 1)
        XCTAssertEqual(EBML.vint(Data([0x40, 0x02]), 0)?.value, 2)
        XCTAssertEqual(EBML.vint(Data([0x10, 0x00, 0x01, 0x00]), 0)?.length, 4)
        XCTAssertNil(EBML.vint(Data([0xFF]), 0)?.value) // unknown size
        XCTAssertEqual(EBML.id(Data([0x1A, 0x45, 0xDF, 0xA3]), 0)?.id, ID.ebml)
    }

    private func block(lacing: UInt8, _ lace: [UInt8], frames: [[UInt8]]) -> MKVBlock? {
        let body = Data([0x81, 0x00, 0x10, 0x80 | lacing] + lace + frames.flatMap { $0 })
        return Matroska.block(body, simple: true, hasReference: false, clusterTime: 100, scale: 1_000_000)
    }

    func testLacing() throws {
        let frames: [[UInt8]] = [[1, 2, 3], [4, 5], [6, 7, 8, 9]]
        let xiph = try XCTUnwrap(block(lacing: 0x02, [2, 3, 2], frames: frames))
        XCTAssertEqual(xiph.frames.map { [UInt8]($0) }, frames)
        XCTAssertEqual(xiph.time, 116_000_000)
        XCTAssertTrue(xiph.keyframe)

        // Sizes 3, then 3 + (-1) = 2: a signed difference of -1 is 0xBE.
        let ebml = try XCTUnwrap(block(lacing: 0x06, [2, 0x83, 0xBE], frames: frames))
        XCTAssertEqual(ebml.frames.map { [UInt8]($0) }, frames)

        let fixed = try XCTUnwrap(block(lacing: 0x04, [1], frames: [[1, 2], [3, 4]]))
        XCTAssertEqual(fixed.frames.map { [UInt8]($0) }, [[1, 2], [3, 4]])
    }

    func testFragmentOffsetsPointIntoTheMediaData() {
        let samples = [FragmentSample(data: Data([1, 2, 3]), duration: 10, compositionOffset: 0, sync: true)]
        let audio = [FragmentSample(data: Data([9, 9]), duration: 5, compositionOffset: 0, sync: true)]
        let d = MP4.fragment(sequence: 7, tracks: [FragmentTrack(id: 1, baseDecodeTime: 0, samples: samples),
                                                   FragmentTrack(id: 2, baseDecodeTime: 0, samples: audio)])
        let moofSize = Int(d.prefix(4).reduce(0) { $0 << 8 | UInt32($1) })
        XCTAssertEqual(String(decoding: d[4..<8], as: UTF8.self), "moof")
        XCTAssertEqual(String(decoding: d[(moofSize + 4)..<(moofSize + 8)], as: UTF8.self), "mdat")
        XCTAssertEqual([UInt8](d.suffix(5)), [1, 2, 3, 9, 9])
        XCTAssertEqual(MP4.packedLanguage("eng"), 0x15C7)
        XCTAssertEqual(MP4.packedLanguage(nil), MP4.packedLanguage("und"))
    }

    func testCodecHeaders() {
        // A 48 kHz 5.1 AC-3 frame start: fscod 0, bsid 8, acmod 7, LFE on.
        let ac3 = Codecs.ac3Header(Data([0x0B, 0x77, 0, 0, 0x1E, 0x40, 0xE1, 0x00]))
        XCTAssertEqual(ac3?.rate, 48000)
        XCTAssertEqual(ac3?.channels, 6)
        XCTAssertEqual(Codecs.aacConfig(Data([0x11, 0x90]))?.rate, 48000)
        XCTAssertEqual(Codecs.aacConfig(Data([0x11, 0x90]))?.channels, 2)
        XCTAssertEqual(Codecs.opusSamples(Data([0xFC])), 960)
        XCTAssertEqual(HLSRemuxer.ticks(41_000_000, 90000), 3690)
    }
}

/// Matroska files made with ffmpeg, remuxed, and decoded by AVFoundation.
final class RemuxIntegrationTests: XCTestCase {
    private static let dir: URL = {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("remux-tests-\(ProcessInfo.processInfo.processIdentifier)")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    private func ffmpeg() throws -> String {
        for p in ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"] where FileManager.default.isExecutableFile(atPath: p) {
            return p
        }
        throw XCTSkip("ffmpeg isn't installed")
    }

    private let video = ["-f", "lavfi", "-i", "testsrc2=size=320x240:rate=24"]
    private func tone(_ hz: Int, channels: Int = 2) -> [String] {
        ["-f", "lavfi", "-i", "sine=frequency=\(hz):sample_rate=48000", "-ac", "\(channels)"]
    }

    /// An MKV made by ffmpeg from `args`, 30 seconds long.
    private func make(_ name: String, _ args: [String]) throws -> URL {
        let out = Self.dir.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: out.path) { return out }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: try ffmpeg())
        p.arguments = ["-v", "error", "-y"] + args + ["-t", "30", out.path]
        let err = Pipe()
        p.standardError = err
        try p.run()
        p.waitUntilExit()
        let message = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard p.terminationStatus == 0 else { throw XCTSkip("ffmpeg couldn't make \(name): \(message)") }
        return out
    }

    private struct Decoded {
        var videoFrames = 0
        var videoTimes: [Double] = []
        var audioSeconds = 0.0
        var audioStart: Double?
    }

    /// Init segment and every media segment back to back: a fragmented MP4.
    private func remux(_ mkv: URL) async throws -> (HLSRemuxer, URL) {
        let remuxer = try await HLSRemuxer.open(try FileByteSource(url: mkv))
        var data = remuxer.initSegment
        for i in 0..<remuxer.segmentCount { data += try await remuxer.segment(i) }
        let out = mkv.deletingPathExtension().appendingPathExtension("mp4")
        try data.write(to: out)
        return (remuxer, out)
    }

    private func decode(_ url: URL) async throws -> Decoded {
        let asset = AVURLAsset(url: url)
        let reader = try AVAssetReader(asset: asset)
        let videoTrack = try await asset.loadTracks(withMediaType: .video).first
        let audioTrack = try await asset.loadTracks(withMediaType: .audio).first
        let videoOut = videoTrack.map {
            AVAssetReaderTrackOutput(track: $0, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange])
        }
        let audioOut = audioTrack.map {
            AVAssetReaderTrackOutput(track: $0, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM])
        }
        try XCTUnwrap(videoOut).alwaysCopiesSampleData = false
        videoOut.map { reader.add($0) }
        audioOut.map { reader.add($0) }
        XCTAssertTrue(reader.startReading(), "\(reader.error.map { "\($0)" } ?? "")")
        var d = Decoded()
        while let s = videoOut?.copyNextSampleBuffer() {
            guard CMSampleBufferGetImageBuffer(s) != nil else { continue }
            d.videoFrames += 1
            d.videoTimes.append(CMSampleBufferGetPresentationTimeStamp(s).seconds)
        }
        while let s = audioOut?.copyNextSampleBuffer() {
            if d.audioStart == nil { d.audioStart = CMSampleBufferGetPresentationTimeStamp(s).seconds }
            d.audioSeconds += CMSampleBufferGetDuration(s).seconds
        }
        XCTAssertNotEqual(reader.status, .failed, "\(reader.error.map { "\($0)" } ?? "")")
        return d
    }

    /// 30 seconds at 24 fps: every frame once, in order, with the audio
    /// starting with the picture.
    private func check(_ name: String, _ args: [String], audio: Bool = true) async throws {
        let (remuxer, mp4) = try await remux(try make(name, args))
        XCTAssertTrue(remuxer.indexed)
        XCTAssertGreaterThanOrEqual(remuxer.segmentCount, 4)
        let d = try await decode(mp4)
        XCTAssertEqual(d.videoFrames, 720, name)
        let steps = zip(d.videoTimes.dropFirst(), d.videoTimes).map { $0 - $1 }
        XCTAssertTrue(steps.allSatisfy { $0 > 0.03 && $0 < 0.06 }, "\(name): uneven frame times \(steps.filter { $0 <= 0.03 || $0 >= 0.06 }.prefix(5))")
        if audio {
            XCTAssertEqual(d.audioSeconds, 30, accuracy: 0.15, name)
            XCTAssertEqual(d.audioStart ?? -1, d.videoTimes.first ?? 0, accuracy: 0.03, "\(name): audio out of sync")
        }
    }

    func testH264WithAAC() async throws {
        try await check("h264-aac.mkv", video + tone(440) + ["-c:v", "libx264", "-preset", "veryfast", "-g", "48", "-bf", "3", "-pix_fmt", "yuv420p", "-c:a", "aac"])
    }

    func testHEVCOpenGOPWithSurroundAC3() async throws {
        try await check("hevc-ac3.mkv", video + tone(330, channels: 6) + [
            "-c:v", "libx265", "-preset", "ultrafast", "-x265-params", "log-level=error:keyint=48:bframes=4:open-gop=1", "-pix_fmt", "yuv420p",
            "-c:a", "ac3",
        ])
    }

    /// A Chromecast gets AC-3 as AAC: the tone carries on across every
    /// segment boundary with no gap and no click.
    func testCastVariantTurnsAC3IntoSeamlessAAC() async throws {
        let mkv = try make("h264-ac3-cast.mkv", video + tone(440, channels: 6) + ["-c:v", "libx264", "-preset", "veryfast", "-g", "48", "-c:a", "ac3"])
        let remuxer = try await HLSRemuxer.open(try FileByteSource(url: mkv))
        XCTAssertTrue(remuxer.transcodesForCast)
        let castInit = try await remuxer.respond(to: "/t/cast/init.mp4")
        var data = try XCTUnwrap(castInit).body
        for i in 0..<remuxer.segmentCount { data += try await remuxer.segment(i, cast: true) }
        let out = Self.dir.appendingPathComponent("cast.mp4")
        try data.write(to: out)

        let asset = AVURLAsset(url: out)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        let track = try XCTUnwrap(tracks.first)
        let formats = try await track.load(.formatDescriptions)
        let format = try XCTUnwrap(formats.first)
        XCTAssertEqual(CMFormatDescriptionGetMediaSubType(format), kAudioFormatMPEG4AAC)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false, AVNumberOfChannelsKey: 1,
        ])
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        var samples: [Float] = []
        while let buffer = output.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(buffer) {
            var length = 0
            var pointer: UnsafeMutablePointer<CChar>?
            CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &pointer)
            pointer?.withMemoryRebound(to: Float.self, capacity: length / 4) { samples += UnsafeBufferPointer(start: $0, count: length / 4) }
        }
        XCTAssertEqual(Double(samples.count) / 48000, 30, accuracy: 0.2)

        // After the first fade-in: no stretch of 5 ms goes quiet, and no
        // sample jumps much further than a 440 Hz sine ever does.
        let body = samples.dropFirst(4800).dropLast(4800)
        let peak = body.map(abs).max() ?? 0
        XCTAssertGreaterThan(peak, 0.01)
        let windows = stride(from: body.startIndex, to: body.endIndex - 240, by: 240).map { start in
            (body[start..<start + 240].map { $0 * $0 }.reduce(0, +) / 240).squareRoot()
        }
        let quietest = windows.min() ?? 0
        let steps = zip(body.dropFirst(), body).map { abs($0 - $1) }
        let jump = (steps.max() ?? 0) / (peak * Float(2 * Double.pi * 440 / 48000))
        print("cast audio: peak \(peak), quietest 5 ms RMS \(quietest), largest jump \(jump)× a sine's")
        XCTAssertGreaterThan(quietest, peak * 0.5, "a gap in the audio")
        XCTAssertLessThan(jump, 2, "a click in the audio")
    }

    func testH264WithEAC3() async throws {
        try await check("h264-eac3.mkv", video + tone(550, channels: 6) + ["-c:v", "libx264", "-preset", "veryfast", "-g", "48", "-c:a", "eac3"])
    }

    func testH264WithMP3() async throws {
        try await check("h264-mp3.mkv", video + tone(660) + ["-c:v", "libx264", "-preset", "veryfast", "-g", "48", "-c:a", "libmp3lame"])
    }

    func testH264WithOpus() async throws {
        try await check("h264-opus.mkv", video + tone(770) + ["-c:v", "libx264", "-preset", "veryfast", "-g", "48", "-c:a", "libopus"])
    }

    func testPicksAPlayableAudioTrackOverAnUnplayableDefault() async throws {
        let mkv = try make("dts-and-aac.mkv", video + tone(440) + tone(880) + [
            "-map", "0:v", "-map", "1:a", "-map", "2:a", "-c:v", "libx264", "-preset", "veryfast", "-g", "48",
            "-c:a:0", "dca", "-strict", "-2", "-c:a:1", "aac", "-disposition:a:0", "default", "-disposition:a:1", "0",
        ])
        let remuxer = try await HLSRemuxer.open(try FileByteSource(url: mkv))
        XCTAssertEqual(remuxer.audio?.codecName, "AAC")
    }

    func testRefusesWhatMacOSCantDecode() async throws {
        let dts = try make("dts.mkv", video + tone(440) + ["-c:v", "libx264", "-preset", "veryfast", "-c:a", "dca", "-strict", "-2"])
        do {
            _ = try await HLSRemuxer.open(try FileByteSource(url: dts))
            XCTFail("DTS audio should be refused")
        } catch {
            XCTAssertEqual(error as? RemuxError, .unsupportedAudio("DTS"))
        }
        let vp9 = try make("vp9.webm", video + tone(440) + ["-c:v", "libvpx-vp9", "-deadline", "realtime", "-c:a", "libopus"])
        do {
            _ = try await HLSRemuxer.open(try FileByteSource(url: vp9))
            XCTFail("VP9 should be refused")
        } catch {
            XCTAssertEqual(error as? RemuxError, .unsupportedVideo("VP9"))
        }
    }

    func testAV1WhereTheMacDecodesIt() async throws {
        let args = video + tone(440) + ["-c:v", "libsvtav1", "-preset", "12", "-g", "48", "-c:a", "aac"]
        guard VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1) else {
            let mkv = try make("av1.mkv", args)
            do {
                _ = try await HLSRemuxer.open(try FileByteSource(url: mkv))
                XCTFail("AV1 should be refused without a hardware decoder")
            } catch {
                XCTAssertEqual((error as? RemuxError).map { if case .unsupportedVideo = $0 { true } else { false } }, true)
            }
            return
        }
        try await check("av1.mkv", args)
    }

    /// Without the index, segments are byte guesses; still every frame once.
    func testFileWithoutAnIndex() async throws {
        let source = try make("h264-aac-long-gop.mkv", video + tone(440) + ["-c:v", "libx264", "-preset", "veryfast", "-g", "120", "-c:a", "aac"])
        var bytes = try Data(contentsOf: source)
        // Hide the cues from the seek head.
        let cuesID = Data([0x53, 0xAB, 0x84, 0x1C, 0x53, 0xBB, 0x6B])
        let range = try XCTUnwrap(bytes.prefix(4096).range(of: cuesID))
        bytes[range.upperBound - 1] = 0x6A
        let hidden = Self.dir.appendingPathComponent("no-index.mkv")
        try bytes.write(to: hidden)

        let (remuxer, mp4) = try await remux(hidden)
        XCTAssertFalse(remuxer.indexed)
        let d = try await decode(mp4)
        XCTAssertEqual(d.videoFrames, 720)
        XCTAssertEqual(d.audioSeconds, 30, accuracy: 0.15)
    }

    func testPlaylist() async throws {
        let (remuxer, _) = try await remux(try make("h264-aac.mkv", video + tone(440) + [
            "-c:v", "libx264", "-preset", "veryfast", "-g", "48", "-bf", "3", "-pix_fmt", "yuv420p", "-c:a", "aac",
        ]))
        let playlist = remuxer.playlist
        XCTAssertTrue(playlist.contains("#EXT-X-MAP:URI=\"init.mp4\""))
        XCTAssertTrue(playlist.hasSuffix("#EXT-X-ENDLIST\n"))
        let total = playlist.split(separator: "\n").filter { $0.hasPrefix("#EXTINF:") }
            .compactMap { Double($0.dropFirst(8).dropLast()) }.reduce(0, +)
        XCTAssertEqual(total, 30, accuracy: 0.1)
        let body = try await remuxer.respond(to: "/token/3.m4s")
        XCTAssertEqual(body?.contentType, "video/iso.segment")
        let none = try await remuxer.respond(to: "/token/999.m4s")
        XCTAssertNil(none)
    }
}
