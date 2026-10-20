import Foundation
import TorrentKit

// A headless driver for TorrentKit: fetches a torrent's metadata, picks its
// largest video, and streams the first bytes of it through the loopback
// server, printing progress. Used to check the engine without the app.
//
//   swift run bobcorn-torrent <magnet | .torrent URL | .torrent path> [megabytes]

setvbuf(stdout, nil, _IOLBF, 0)

let args = CommandLine.arguments
guard args.count >= 2 else {
    print("usage: bobcorn-torrent <magnet | .torrent URL | .torrent path> [megabytes-to-read]")
    exit(2)
}
let input = args[1]
let megabytes = args.count >= 3 ? Int(args[2]) ?? 8 : 8

func loadSource() async throws -> TorrentSource {
    if input.hasPrefix("magnet:") { return .magnet(try MagnetLink(string: input)) }
    let data: Data
    if input.hasPrefix("http://") || input.hasPrefix("https://") {
        (data, _) = try await URLSession.shared.data(from: URL(string: input)!)
    } else {
        data = try Data(contentsOf: URL(fileURLWithPath: input))
    }
    return .metainfo(try Metainfo(data: data))
}

let cache = FileManager.default.temporaryDirectory.appendingPathComponent("bobcorn-cli-cache")
let engine = TorrentEngine(configuration: TorrentConfiguration(cacheDirectory: cache))

func report(_ s: TorrentSession) async -> TorrentStats {
    let st = await s.stats()
    let rate = ByteCountFormatter.string(fromByteCount: Int64(st.downloadRate), countStyle: .file)
    print(String(format: "  %@  %@/s  peers %d (active %d, known %d)  webseeds %d  pieces %d/%d  file %.1f%%  buffered %@  hashfail %d",
                 "\(st.phase)", rate, st.connectedPeers, st.activePeers, st.knownPeers, st.activeWebSeeds,
                 st.piecesHave, st.piecesTotal, st.selectedProgress * 100,
                 ByteCountFormatter.string(fromByteCount: st.bufferedAhead, countStyle: .file), st.hashFailures))
    return st
}

let started = Date()
do {
    let source = try await loadSource()
    print("info-hash \(source.infoHashHex)")
    let session = engine.session(for: source)

    let metadataTask = Task { try await session.waitForMetadata() }
    let progressTask = Task {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            _ = await report(session)
        }
    }
    let info = try await metadataTask.value
    print(String(format: "metadata after %.1fs: \"%@\", %d files, %d pieces of %@",
                 Date().timeIntervalSince(started), info.name, info.contentFiles.count, info.pieceCount,
                 ByteCountFormatter.string(fromByteCount: Int64(info.pieceLength), countStyle: .file)))
    guard let file = info.mainVideoFile ?? info.contentFiles.max(by: { $0.length < $1.length }) else {
        print("no files")
        exit(1)
    }
    print("streaming \(file.displayPath) (\(ByteCountFormatter.string(fromByteCount: file.length, countStyle: .file)))")
    session.select(fileIndex: file.index)

    let url = try await engine.streamURL(for: session, file: file)
    print("stream URL \(url)")

    // Read through the HTTP server, as a player would.
    var request = URLRequest(url: url)
    let want = min(Int64(megabytes) << 20, file.length)
    request.setValue("bytes=0-\(want - 1)", forHTTPHeaderField: "Range")
    request.timeoutInterval = 600
    let readStart = Date()
    let (data, response) = try await URLSession.shared.data(for: request)
    let http = response as! HTTPURLResponse
    let secs = Date().timeIntervalSince(readStart)
    print(String(format: "HTTP %d, %@ in %.1fs (%@/s); first bytes %@", http.statusCode,
                 ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file), secs,
                 ByteCountFormatter.string(fromByteCount: Int64(Double(data.count) / max(secs, 0.001)), countStyle: .file),
                 data.prefix(12).map { String(format: "%02x", $0) }.joined()))
    progressTask.cancel()
    _ = await report(session)
    engine.stopAll()
    try? await Task.sleep(nanoseconds: 300_000_000)
    exit(data.count == Int(want) ? 0 : 1)
} catch {
    print("error: \(error.localizedDescription)")
    exit(1)
}
