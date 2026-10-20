import XCTest
@testable import TorrentKit

final class BencodeTests: XCTestCase {
    func testRoundTrip() throws {
        let value = BValue.dict([
            "a": .int(-42),
            "list": .list([.string("spam"), .int(0)]),
            "nested": .dict(["k": .bytes([0, 255, 7])]),
        ])
        let encoded = Bencode.encode(value)
        XCTAssertEqual(String(decoding: encoded, as: UTF8.self).prefix(9), "d1:ai-42e")
        XCTAssertEqual(try Bencode.decode(encoded), value)
    }

    func testDictionaryKeysAreSorted() {
        let encoded = Bencode.encode(.dict(["b": .int(1), "a": .int(2)]))
        XCTAssertEqual(String(decoding: encoded, as: UTF8.self), "d1:ai2e1:bi1ee")
    }

    func testRejectsMalformedInput() {
        XCTAssertThrowsError(try Bencode.decode(Array("i12".utf8)))
        XCTAssertThrowsError(try Bencode.decode(Array("5:abc".utf8)))
        XCTAssertThrowsError(try Bencode.decode(Array("ie".utf8)))
        XCTAssertThrowsError(try Bencode.decode(Array("x".utf8)))
        XCTAssertThrowsError(try Bencode.decode(Array(String(repeating: "l", count: 200).utf8)))
    }

    func testDecodePrefixReportsConsumedBytes() throws {
        let bytes = Array("d8:msg_typei1e5:piecei0eeRAWDATA".utf8)
        let (value, used) = try Bencode.decodePrefix(bytes)
        XCTAssertEqual(value["msg_type"]?.intValue, 1)
        XCTAssertEqual(String(decoding: bytes[used...], as: UTF8.self), "RAWDATA")
    }
}

final class MetainfoTests: XCTestCase {
    /// A two-file torrent with 16-byte pieces and a BEP 47 padding file.
    private func makeTorrent() -> Data {
        let pieceLength = 16
        let files: [(path: [String], length: Int, padding: Bool)] = [
            (["a.mp4"], 20, false),
            ([".pad", "12"], 12, true),
            (["sub", "a.srt"], 10, false),
        ]
        let total = files.reduce(0) { $0 + $1.length }
        let pieces = (total + pieceLength - 1) / pieceLength
        let info = BValue.dict([
            "name": .string("film"),
            "piece length": .int(Int64(pieceLength)),
            "pieces": .bytes([UInt8](repeating: 0xab, count: pieces * 20)),
            "files": .list(files.map { f in
                var d: [String: BValue] = [
                    "length": .int(Int64(f.length)),
                    "path": .list(f.path.map { .string($0) }),
                ]
                if f.padding { d["attr"] = .string("p") }
                return .dict(d)
            }),
        ])
        let root = BValue.dict([
            "announce": .string("udp://tracker.example:80/announce"),
            "url-list": .list([.string("https://seed.example/files/")]),
            "info": info,
        ])
        return Data(Bencode.encode(root))
    }

    func testParsesFilesAndInfoHash() throws {
        let data = makeTorrent()
        let meta = try Metainfo(data: data)
        let info = meta.info
        XCTAssertEqual(info.name, "film")
        XCTAssertEqual(info.totalLength, 42)
        XCTAssertEqual(info.pieceCount, 3)
        XCTAssertEqual(info.pieceSize(2), 10)
        XCTAssertEqual(info.contentFiles.map(\.displayPath), ["a.mp4", "sub/a.srt"])
        XCTAssertTrue(info.files[1].isPadding)
        XCTAssertEqual(info.files[2].offset, 32)
        XCTAssertEqual(info.mainVideoFile?.name, "a.mp4")
        XCTAssertEqual(meta.trackers, ["udp://tracker.example:80/announce"])
        XCTAssertEqual(meta.webSeeds, ["https://seed.example/files/"])

        // The info-hash covers the info dictionary exactly as encoded.
        let rawInfo = Bencode.encode(try Bencode.decode(data)["info"]!)
        XCTAssertEqual(info.infoHash, SHA1Digest.hash(rawInfo))
    }

    func testSegmentsSplitAcrossFiles() throws {
        let info = try Metainfo(data: makeTorrent()).info
        let segs = info.segments(start: 16, length: 16)
        XCTAssertEqual(segs.map(\.file.index), [0, 1])
        XCTAssertEqual(segs.map(\.fileOffset), [16, 0])
        XCTAssertEqual(segs.map(\.length), [4, 12])
        XCTAssertEqual(segs.map(\.bufferOffset), [0, 4])
        XCTAssertEqual(info.pieceRange(for: info.files[2]), 2...2)
    }

    func testReadsTheCacheFolder() throws {
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: cache) }
        let info = try Metainfo(data: makeTorrent()).info
        let dir = SessionDirectory(cache: cache, infoHash: info.infoHash)
        try dir.ensureExists()
        dir.saveInfo(info)
        FileManager.default.createFile(atPath: dir.dataURL.path, contents: Data(count: 42))
        var have = Bitfield(count: info.pieceCount)
        have[0] = true
        have[2] = true
        dir.saveHave(have)
        // Not torrents: a folder of the app's own, and one whose name isn't its hash.
        try FileManager.default.createDirectory(at: cache.appendingPathComponent("Subtitles"), withIntermediateDirectories: true)
        let stray = cache.appendingPathComponent(String(repeating: "0", count: 40))
        try FileManager.default.createDirectory(at: stray, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: dir.infoURL, to: stray.appendingPathComponent("info.bencode"))

        let found = CachedTorrent.all(in: cache)
        XCTAssertEqual(found.map(\.infoHashHex), [info.infoHashHex])
        // Piece 0 holds 16 of a.mp4's 20 bytes; piece 2 all of a.srt.
        XCTAssertEqual(found.first?.progress, [0: 0.8, 2: 1])
        XCTAssertEqual(CachedTorrent.folder(forInfoHash: info.infoHashHex.uppercased(), in: cache), dir.url)
    }

    func testRejectsPieceCountMismatch() {
        let info = BValue.dict([
            "name": .string("x"), "piece length": .int(16), "length": .int(40),
            "pieces": .bytes([UInt8](repeating: 0, count: 20)),
        ])
        XCTAssertThrowsError(try TorrentInfo(rawInfo: Bencode.encode(info)))
    }
}

final class MagnetTests: XCTestCase {
    func testHexMagnet() throws {
        let m = try MagnetLink(string: "magnet:?xt=urn:btih:d160b8d8ea35a5b4e52837468fc8f03d55cef1f7&dn=Some+Film&tr=udp%3A%2F%2Ft.example%3A80&ws=https%3A%2F%2Fw.example%2F&x.pe=10.0.0.1:6881")
        XCTAssertEqual(m.infoHash.hexString, "d160b8d8ea35a5b4e52837468fc8f03d55cef1f7")
        XCTAssertEqual(m.displayName, "Some Film")
        XCTAssertEqual(m.trackers, ["udp://t.example:80"])
        XCTAssertEqual(m.webSeeds, ["https://w.example/"])
        XCTAssertEqual(m.peers, [PeerAddress(host: "10.0.0.1", port: 6881)])
        XCTAssertEqual(try MagnetLink(string: m.uri).infoHash, m.infoHash)
    }

    func testBase32Magnet() throws {
        // Base32 of 20 zero bytes, then of 0xff * 20.
        let zero = try MagnetLink(string: "magnet:?xt=urn:btih:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA")
        XCTAssertEqual(zero.infoHash, [UInt8](repeating: 0, count: 20))
        let ones = try MagnetLink(string: "magnet:?xt=urn:btih:77777777777777777777777777777777")
        XCTAssertEqual(ones.infoHash, [UInt8](repeating: 0xff, count: 20))
    }

    func testRejectsNonMagnets() {
        XCTAssertThrowsError(try MagnetLink(string: "https://example.com"))
        XCTAssertThrowsError(try MagnetLink(string: "magnet:?dn=no-hash"))
        XCTAssertThrowsError(try MagnetLink(string: "magnet:?xt=urn:btih:1234"))
    }

    func testCompactPeers() {
        let v4 = PeerAddress.parseCompact([127, 0, 0, 1, 0x1a, 0xe1, 1, 2, 3, 4, 0, 0])
        XCTAssertEqual(v4, [PeerAddress(host: "127.0.0.1", port: 6881)]) // port 0 is dropped
        var six = [UInt8](repeating: 0, count: 16)
        six[15] = 1
        XCTAssertEqual(PeerAddress.parseCompact6(six + [0x1a, 0xe1]), [PeerAddress(host: "::1", port: 6881)])
        XCTAssertEqual(PeerAddress(hostPort: "[::1]:51413"), PeerAddress(host: "::1", port: 51413))
    }
}

final class BitfieldTests: XCTestCase {
    func testCountsAndSpareBits() {
        var b = Bitfield(count: 10)
        b[0] = true
        b[9] = true
        b[9] = true
        XCTAssertEqual(b.setCount, 2)
        XCTAssertEqual(b.bytes, [0x80, 0x40])
        // Spare bits a peer sets past the end are ignored.
        let peer = Bitfield(bytes: [0xff, 0xff], count: 10)
        XCTAssertEqual(peer.setCount, 10)
        XCTAssertTrue(peer.isComplete)
    }
}

final class PeerMessageTests: XCTestCase {
    func testEncodesRequest() {
        let bytes = PeerMessage.request(BlockRequest(piece: 1, begin: 16384, length: 16384)).encoded()
        XCTAssertEqual(bytes, [0, 0, 0, 13, 6, 0, 0, 0, 1, 0, 0, 0x40, 0, 0, 0, 0x40, 0])
        XCTAssertEqual(PeerMessage.keepAlive.encoded(), [0, 0, 0, 0])
    }
}
