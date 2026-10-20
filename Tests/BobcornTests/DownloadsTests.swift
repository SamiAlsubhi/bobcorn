import XCTest
@testable import Bobcorn
@testable import TorrentKit

@MainActor
final class DownloadsTests: XCTestCase {
    /// Two 20-byte episodes and a subtitle, in 16-byte pieces.
    private func season() throws -> TorrentInfo {
        let files: [(String, Int64)] = [("Show.S01E01.mp4", 20), ("Show.S01E02.mp4", 20), ("Show.S01E01.srt", 4)]
        let info = BValue.dict([
            "name": .string("Show S01"),
            "piece length": .int(16),
            "pieces": .bytes([UInt8](repeating: 1, count: 3 * 20)),
            "files": .list(files.map { .dict(["length": .int($0.1), "path": .list([.string($0.0)])]) }),
        ])
        return try TorrentInfo(rawInfo: Bencode.encode(info))
    }

    func testAPartPerEpisodeAskedFor() throws {
        let info = try season()
        var item = Downloads.Item(id: info.infoHashHex, about: Downloads.About(title: "Show", parts: [
            Downloads.Part(file: 1, season: 1, episode: 2, key: "api:tt1:s1e2", label: "S01E02"),
            Downloads.Part(file: 0, season: 1, episode: 1, key: "api:tt1:s1e1", label: "S01E01"),
        ], kept: true), info: info, progress: [0: 1, 1: 0.5])
        XCTAssertEqual(item.parts.map(\.label), ["S01E01", "S01E02"], "in episode order")
        XCTAssertEqual(item.size, 40)
        XCTAssertEqual(item.bytesDone, 30)
        XCTAssertEqual(item.fraction, 0.75)
        XCTAssertFalse(item.isComplete)
        XCTAssertEqual(item.state, .queued)
        item.rate = 1000
        XCTAssertEqual(item.state, .downloading)
        item.about.paused = true
        XCTAssertEqual(item.state, .paused)
        XCTAssertFalse(item.isWanted)
        item.progress[1] = 1
        XCTAssertTrue(item.isComplete)
        XCTAssertEqual(item.state, .complete)
    }

    func testStreamedTorrentShowsTheVideosWithAnythingHere() throws {
        let info = try season()
        let item = Downloads.Item(id: info.infoHashHex, about: Downloads.About(title: "Show S01"), info: info, progress: [1: 0.25, 2: 1])
        XCTAssertEqual(item.parts.map(\.file), [1], "the subtitle and the untouched episode aren't parts")
        XCTAssertEqual(item.parts.first?.label, "Show.S01E02")
        XCTAssertEqual(item.state, .streamed)
        XCTAssertNil(item.parts.first?.key)
    }

    func testWaitingForTheFileList() {
        let item = Downloads.Item(id: "ab", about: Downloads.About(title: "Film", parts: [Downloads.Part(label: "Film")], kept: true))
        XCTAssertEqual(item.fraction, 0)
        XCTAssertFalse(item.isComplete, "a part without its file isn't here")
        XCTAssertTrue(item.isWanted)
    }

    func testAShowsEpisodesAreOneEntryWhateverTorrentsTheyCameIn() throws {
        let info = try season()
        let show = SavedTitle(id: "tt1", type: .shows, title: "Show", year: nil, poster: nil, base: URL(string: "https://api.example")!)
        let film = SavedTitle(id: "tt2", type: .movies, title: "Film", year: nil, poster: nil, base: URL(string: "https://api.example")!)
        func episode(_ id: String, _ n: Int, file: Int, done: Double) -> Downloads.Item {
            Downloads.Item(id: id, about: Downloads.About(title: "Show", saved: show, series: "Show", parts: [
                Downloads.Part(file: file, season: 1, episode: n, key: "api:tt1:s1e\(n)", label: "S01E0\(n)"),
            ], kept: true), info: info, progress: [file: done])
        }
        let items = [
            episode("e2", 2, file: 1, done: 0.5),
            Downloads.Item(id: "f", about: Downloads.About(title: "Film", saved: film, parts: [Downloads.Part(file: 0, label: "Film")], kept: true),
                           info: info, progress: [0: 1]),
            episode("e1", 1, file: 0, done: 1),
            // A feed's episode of another show, grouped by name.
            Downloads.Item(id: "x", about: Downloads.About(title: "Other Show", series: "Other Show",
                                                           parts: [Downloads.Part(file: 0, season: 1, episode: 1, label: "S01E01")], kept: true),
                           info: info, progress: [0: 1]),
        ]
        let groups = Downloads.group(items)
        XCTAssertEqual(groups.map(\.id), ["show:tt1", "f", "series:othershow"])
        let shown = groups[0]
        XCTAssertEqual(shown.items.count, 2)
        XCTAssertEqual(shown.entries.map(\.part.label), ["S01E01", "S01E02"], "in episode order across torrents")
        XCTAssertEqual(shown.entries.map(\.status.state), [.complete, .queued])
        XCTAssertEqual(shown.state, .queued, "downloading while any of it is")
        XCTAssertEqual(shown.fraction, 30.0 / 40.0)
        XCTAssertTrue(shown.isShow)
        XCTAssertFalse(groups[1].isShow)
        XCTAssertEqual(groups[1].state, .complete)
    }

    func testClearingTheCacheKeepsDownloads() throws {
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: cache) }
        let fm = FileManager.default
        func folder(_ name: String, kept: Bool?) throws {
            let url = cache.appendingPathComponent(name)
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
            if let kept {
                try JSONEncoder().encode(Downloads.About(title: name, kept: kept)).write(to: url.appendingPathComponent("about.json"))
            }
        }
        try folder("kept", kept: true)
        try folder("streamed", kept: false)
        try folder("unnamed", kept: nil)
        try folder("Subtitles", kept: nil)
        Downloads.clearStreamed(in: cache)
        XCTAssertEqual(Set(try fm.contentsOfDirectory(atPath: cache.path)), ["kept", "Subtitles"])
    }
}
