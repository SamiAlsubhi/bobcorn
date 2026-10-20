import Foundation
import Observation
import TorrentKit

/// Joins a title's swarm while its page is open, without downloading, to
/// count how many peers hold each file. Pressing play then starts on a warm
/// swarm, since the player shares the session.
@MainActor
@Observable
final class SwarmProbe {
    /// By file path inside the torrent (an archive.org file name).
    private(set) var byFile: [String: FileAvailability] = [:]
    private(set) var hasResults = false

    private let engine: TorrentEngine
    private let session: TorrentSession
    private let videoFiles: [TorrentFile]
    private var task: Task<Void, Never>?
    private var released = false

    #if DEBUG
    static weak var latest: SwarmProbe?
    #endif

    init(meta: Metainfo, engine: TorrentEngine) {
        self.engine = engine
        session = engine.session(for: .metainfo(meta))
        videoFiles = meta.info.contentFiles.filter(\.isVideo)
        task = Task { [weak self] in
            var polls = 0
            while !Task.isCancelled {
                guard let self else { return }
                let counts = await self.session.availability(of: self.videoFiles.map(\.index))
                var named: [String: FileAvailability] = [:]
                for f in self.videoFiles { named[f.displayPath] = counts[f.index] }
                self.byFile = named
                polls += 1
                // Peers take a few seconds to connect and send bitfields.
                if polls >= 3 || named.values.contains(where: { $0.seeds > 0 }) { self.hasResults = true }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
        #if DEBUG
        Self.latest = self
        #endif
    }

    func availability(_ file: String) -> FileAvailability? {
        hasResults ? byFile[file] : nil
    }

    func stop() {
        task?.cancel()
        guard !released else { return }
        released = true
        engine.release(session)
    }
}

extension FileAvailability {
    /// "12 seeds", "3 seeds + web seed", "web seed", "no seeds".
    var seedText: String {
        let s = seeds == 1 ? "1 seed" : "\(seeds) seeds"
        switch (seeds > 0, webSeeded) {
        case (true, true): return "\(s) + web seed"
        case (true, false): return s
        case (false, true): return "web seed"
        case (false, false): return "no seeds"
        }
    }

    /// Orders options best-first.
    var rank: (Int, Int, Int) { (seeds, webSeeded ? 1 : 0, peers) }
}
