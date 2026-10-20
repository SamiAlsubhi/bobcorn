import Foundation
import Observation
import TorrentKit

/// What's in the cache folder, and the downloads that fill it. A download is
/// a torrent kept running with no one watching until the films or episodes
/// asked for are all here: two at a time, the rest waiting their turn, and
/// carrying on at the next launch. Beside each torrent's data, `about.json`
/// says what it is, for torrents only streamed too.
@MainActor
@Observable
final class Downloads {
    /// What a torrent in the cache is.
    struct About: Codable, Equatable {
        var title: String
        var poster: URL?
        /// The source's movie or show, to open its page and keep its place.
        var saved: SavedTitle?
        /// The magnet or .torrent URL, to find peers again.
        var link: String?
        /// The show it holds episodes of, which the Downloads tab groups by.
        var series: String?
        var parts: [Part] = []
        /// Asked to be downloaded, so clearing the cache leaves it.
        var kept = false
        var paused = false
        var added = Date()
    }

    /// A film or episode in a torrent.
    struct Part: Codable, Equatable {
        /// Its file, once the torrent's file list is known.
        var file: Int?
        var season: Int?
        var episode: Int?
        /// Where its resume position is kept; nil for a torrent's own files.
        var key: String?
        var label: String
    }

    enum State: Equatable {
        case gettingFiles, downloading, queued, paused, complete
        /// Partly here from being streamed.
        case streamed
    }

    struct Item: Identifiable {
        /// The info hash.
        let id: String
        var about: About
        var info: TorrentInfo?
        /// How much of each file is here, 0 to 1.
        var progress: [Int: Double] = [:]
        var bytesOnDisk: Int64 = 0
        var modified = Date.distantPast
        /// While it downloads.
        var rate: Double?
        var peers: Int?
        var error: String?

        /// The films and episodes it holds, in order: those named, or else
        /// the videos with anything downloaded.
        var parts: [Part] {
            if !about.parts.isEmpty {
                return about.parts.sorted { ($0.season ?? 0, $0.episode ?? 0, $0.label) < ($1.season ?? 0, $1.episode ?? 0, $1.label) }
            }
            guard let info else { return [] }
            return info.contentFiles
                .filter { $0.isVideo && (progress[$0.index] ?? 0) > 0 }
                .sorted { $0.displayPath.localizedStandardCompare($1.displayPath) == .orderedAscending }
                .map { Part(file: $0.index, label: ($0.name as NSString).deletingPathExtension) }
        }

        func file(_ part: Part) -> TorrentFile? {
            guard let index = part.file, let info, info.files.indices.contains(index) else { return nil }
            return info.files[index]
        }

        var size: Int64 { parts.compactMap(file).reduce(0) { $0 + $1.length } }
        var bytesDone: Int64 {
            parts.compactMap(file).reduce(0) { $0 + Int64(Double($1.length) * (progress[$1.index] ?? 0)) }
        }

        var fraction: Double { size > 0 ? Double(bytesDone) / Double(size) : 0 }

        func fraction(of part: Part) -> Double { file(part).map { progress[$0.index] ?? 0 } ?? 0 }

        var isComplete: Bool {
            let parts = parts
            return !parts.isEmpty && parts.allSatisfy { file($0) != nil && fraction(of: $0) >= 1 }
        }

        var state: State {
            if isComplete { return .complete }
            if !about.kept { return .streamed }
            if about.paused { return .paused }
            if rate != nil { return info == nil ? .gettingFiles : .downloading }
            return .queued
        }

        /// Asked for and not all here yet.
        var isWanted: Bool { about.kept && !about.paused && !isComplete }
    }

    /// What the Downloads tab shows as one: a show's episodes, however many
    /// torrents they came in, or else a torrent.
    struct Group: Identifiable {
        let id: String
        let items: [Item]

        struct Entry: Identifiable {
            let item: Item
            let part: Part
            var id: String { "\(item.id)/\(part.file.map(String.init) ?? part.label)" }
            var fraction: Double { item.fraction(of: part) }
            var status: Status { Status(fraction: fraction, state: fraction >= 1 ? .complete : item.state) }
        }

        /// Its films or episodes, in order.
        var entries: [Entry] {
            items.flatMap { item in item.parts.map { Entry(item: item, part: $0) } }
                .sorted { ($0.part.season ?? 0, $0.part.episode ?? 0, $0.part.label) < ($1.part.season ?? 0, $1.part.episode ?? 0, $1.part.label) }
        }

        /// What the show's own torrents say, before an episode's.
        var about: About { items.first { $0.about.saved != nil }?.about ?? items[0].about }
        var isShow: Bool { Downloads.groupKey(about) != nil }
        var title: String { about.series ?? about.title }
        var size: Int64 { items.reduce(0) { $0 + $1.size } }
        var bytesDone: Int64 { items.reduce(0) { $0 + $1.bytesDone } }
        var bytesOnDisk: Int64 { items.reduce(0) { $0 + max($1.bytesOnDisk, $1.bytesDone) } }
        var fraction: Double { size > 0 ? Double(bytesDone) / Double(size) : 0 }
        var rate: Double? { items.contains { $0.rate != nil } ? items.compactMap(\.rate).reduce(0, +) : nil }
        var peers: Int? { items.contains { $0.peers != nil } ? items.compactMap(\.peers).reduce(0, +) : nil }
        var error: String? { items.lazy.compactMap(\.error).first }
        var added: Date { items.map(\.about.added).min() ?? .distantPast }
        var modified: Date { items.map(\.modified).max() ?? .distantPast }

        /// Downloading while any of it is, all here once all of it is
        /// downloaded, and otherwise streamed.
        var state: State {
            let states = Set(items.map(\.state))
            for state in [State.downloading, .gettingFiles, .queued, .paused] where states.contains(state) { return state }
            if states.contains(.complete) || items.contains(where: \.about.kept) { return .complete }
            return .streamed
        }
    }

    /// The cache's torrents, a show's together.
    var groups: [Group] { Self.group(items) }

    nonisolated static func group(_ items: [Item]) -> [Group] {
        var order: [String] = []
        var byKey: [String: [Item]] = [:]
        for item in items {
            let key = Self.groupKey(item.about) ?? item.id
            if byKey[key] == nil { order.append(key) }
            byKey[key, default: []].append(item)
        }
        return order.map { Group(id: $0, items: byKey[$0]!) }
    }

    /// A catalog show by its IMDb ID; a feed's by its name.
    nonisolated static func groupKey(_ about: About) -> String? {
        if let saved = about.saved, saved.type == .shows { return "show:\(saved.id)" }
        return about.series.map { "series:" + $0.lowercased().filter { $0.isLetter || $0.isNumber } }
    }

    /// How far along a title, torrent or episode is, for its badge.
    struct Status: Equatable {
        var fraction: Double
        var state: State
    }

    static let maxActive = 2

    weak var app: AppModel?
    private(set) var items: [Item] = []
    private var running: [String: Running] = [:]
    /// Torrents resolved from their links, so starting one doesn't fetch its
    /// .torrent file again.
    private var sources: [String: TorrentSource] = [:]
    /// Downloads asked for whose .torrent file is still being fetched, by link.
    private var opening: [String: About] = [:]
    private var pollTask: Task<Void, Never>?
    private var scanTask: Task<Void, Never>?

    /// A download's session, nil while its link is being resolved.
    private struct Running {
        var engine: TorrentEngine?
        var session: TorrentSession?
    }

    // MARK: - Asking

    /// Downloads the films or episodes `about` names from one torrent, adding
    /// them to what's already asked of it.
    func download(link: String, about new: About) {
        opening[link] = new
        Task {
            let source = await Self.source(link: link)
            opening[link] = nil
            guard let source else {
                app?.alertMessage = "Couldn't open that torrent."
                return
            }
            let id = source.infoHashHex
            sources[id] = source
            var about = item(id)?.about ?? Self.readAbout(id) ?? new
            if !about.kept { about.added = Date() }
            about.kept = true
            about.paused = false
            if about.saved == nil, new.saved != nil { about.title = new.title }
            about.series = about.series ?? new.series
            about.poster = about.poster ?? new.poster
            about.saved = about.saved ?? new.saved
            about.link = about.link ?? link
            for part in new.parts where !about.parts.contains(where: { $0.key == part.key && $0.season == part.season && $0.episode == part.episode }) {
                about.parts.append(part)
            }
            update(id, about)
            if let session = running[id]?.session, let info = item(id)?.info {
                resolve(id, info)
                session.setDownloads(wantedFiles(id))
            }
            schedule()
        }
    }

    /// Downloads the rest of a torrent streamed part-way.
    func keep(_ id: String) {
        guard var about = item(id)?.about else { return }
        about.kept = true
        about.paused = false
        about.added = Date()
        if about.parts.isEmpty, let item = item(id) { about.parts = item.parts }
        update(id, about)
        schedule()
    }

    func pause(_ id: String) {
        guard var about = item(id)?.about else { return }
        about.paused = true
        update(id, about)
        stop(id)
        schedule()
    }

    func resume(_ id: String) {
        guard var about = item(id)?.about else { return }
        about.paused = false
        update(id, about)
        schedule()
    }

    /// Deletes a torrent's data. Not while it plays.
    func delete(_ id: String) {
        if app?.playback?.torrentID == id {
            app?.alertMessage = "Stop playback before deleting what's playing."
            return
        }
        stop(id)
        items.removeAll { $0.id == id }
        try? FileManager.default.removeItem(at: CachedTorrent.folder(forInfoHash: id, in: AppModel.cacheDirectory))
        schedule()
    }

    /// Notes what the player streams, so the Downloads tab can name it.
    func noteStreaming(_ id: String, link: String?, title: String, poster: URL?, saved: SavedTitle?, part: Part) {
        var about = item(id)?.about ?? Self.readAbout(id) ?? About(title: title, poster: poster, saved: saved, link: link)
        about.poster = about.poster ?? poster
        about.saved = about.saved ?? saved
        about.link = about.link ?? link
        if part.season != nil { about.series = about.series ?? title }
        if let i = about.parts.firstIndex(where: { ($0.key != nil && $0.key == part.key) || ($0.file != nil && $0.file == part.file) }) {
            if about.parts[i].file == nil { about.parts[i].file = part.file }
        } else {
            about.parts.append(part)
        }
        update(id, about)
    }

    // MARK: - Reading

    func item(_ id: String) -> Item? { items.first { $0.id == id } }

    /// A source's movie or show, over every torrent of it downloaded or
    /// downloading. Nil when there's none.
    func status(forTitle id: String) -> Status? {
        status(of: items.filter { $0.about.saved?.id == id })
            ?? (opening.values.contains { $0.saved?.id == id } ? Status(fraction: 0, state: .gettingFiles) : nil)
    }

    /// A film or episode, by where its resume position is kept.
    func status(forKey key: String) -> Status? {
        for item in items {
            guard let part = item.about.parts.first(where: { $0.key == key }) else { continue }
            let fraction = item.fraction(of: part)
            if fraction >= 1 { return Status(fraction: 1, state: .complete) }
            if item.about.kept { return Status(fraction: fraction, state: item.state) }
        }
        return opening.values.contains { $0.parts.contains { $0.key == key } } ? Status(fraction: 0, state: .gettingFiles) : nil
    }

    /// A torrent an option or feed title lists, by its hash or its link.
    func status(forTorrent infoHash: String?, link: String?) -> Status? {
        let hash = infoHash?.lowercased()
        return status(of: items.filter { $0.id == hash || ($0.about.link != nil && $0.about.link == link) })
            ?? (link.flatMap { opening[$0] } != nil ? Status(fraction: 0, state: .gettingFiles) : nil)
    }

    func status(forTorrents options: [FeedOption]) -> Status? {
        status(of: items(forTorrents: options))
            ?? (options.contains { $0.entry.link.flatMap { opening[$0] } != nil } ? Status(fraction: 0, state: .gettingFiles) : nil)
    }

    /// Downloads of a source's movie or show, to pause or resume together.
    func ids(forTitle id: String) -> [String] {
        items.filter { $0.about.kept && $0.about.saved?.id == id }.map(\.id)
    }

    func ids(forTorrents options: [FeedOption]) -> [String] {
        items(forTorrents: options).filter(\.about.kept).map(\.id)
    }

    private func items(forTorrents options: [FeedOption]) -> [Item] {
        let hashes = Set(options.compactMap { $0.entry.infoHash?.lowercased() })
        let links = Set(options.compactMap(\.entry.link))
        return items.filter { hashes.contains($0.id) || ($0.about.link.map(links.contains) ?? false) }
    }

    /// Only what was asked for, or is all here: a film streamed part-way
    /// isn't a download.
    private func status(of items: [Item]) -> Status? {
        let shown = items.filter { $0.about.kept || $0.isComplete }
        guard !shown.isEmpty else { return nil }
        let size = shown.reduce(Int64(0)) { $0 + $1.size }
        let done = shown.reduce(Int64(0)) { $0 + $1.bytesDone }
        let states = shown.map(\.state)
        let state: State
        if states.allSatisfy({ $0 == .complete }) {
            state = .complete
        } else if states.contains(.downloading) || states.contains(.gettingFiles) {
            state = .downloading
        } else if states.contains(.queued) {
            state = .queued
        } else {
            state = .paused
        }
        return Status(fraction: size > 0 ? Double(done) / Double(size) : 0, state: state)
    }

    // MARK: - The cache folder

    /// Reads the cache folder again, then starts what's waiting: at launch,
    /// after something plays, and after the cache moves.
    func refresh() {
        let cache = AppModel.cacheDirectory
        scanTask?.cancel()
        scanTask = Task {
            let found = await Task.detached(priority: .utility) { Self.scan(cache) }.value
            guard !Task.isCancelled else { return }
            // Asked for since the scan began.
            let added = items.filter { item in item.about.kept && !found.contains { $0.id == item.id } }
            items = added + found.map { item in
                // A running download knows better than what it last saved.
                guard running[item.id] != nil, let live = self.item(item.id) else { return item }
                var merged = item
                merged.progress.merge(live.progress) { max($0, $1) }
                merged.rate = live.rate
                merged.peers = live.peers
                if merged.info == nil { merged.info = live.info }
                return merged
            }
            schedule()
        }
    }

    /// Lets go of every download, as the engine stops: before the cache moves.
    func suspend() {
        running.removeAll()
        pollTask?.cancel()
        pollTask = nil
    }

    nonisolated private static func scan(_ cache: URL) -> [Item] {
        var out = CachedTorrent.all(in: cache).map { c in
            Item(id: c.infoHashHex, about: readAbout(at: c.folder) ?? About(title: c.info.name, added: modified(c.folder)),
                 info: c.info, progress: c.progress, bytesOnDisk: c.bytesOnDisk, modified: modified(c.folder))
        }
        // Downloads still waiting for their file list.
        let folders = (try? FileManager.default.contentsOfDirectory(at: cache, includingPropertiesForKeys: nil)) ?? []
        for folder in folders where !out.contains(where: { $0.id == folder.lastPathComponent }) {
            if let about = readAbout(at: folder), about.kept {
                out.append(Item(id: folder.lastPathComponent, about: about, modified: modified(folder)))
            }
        }
        return out
    }

    nonisolated private static func modified(_ folder: URL) -> Date {
        let data = folder.appendingPathComponent("data.blob")
        return (try? data.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            ?? (try? folder.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            ?? .distantPast
    }

    /// Empties the cache of everything but downloads (and subtitles, which
    /// downloads use).
    nonisolated static func clearStreamed(in cache: URL) {
        let folders = (try? FileManager.default.contentsOfDirectory(at: cache, includingPropertiesForKeys: nil)) ?? []
        for folder in folders where folder.lastPathComponent != "Subtitles" {
            if readAbout(at: folder)?.kept == true { continue }
            try? FileManager.default.removeItem(at: folder)
        }
    }

    nonisolated private static func aboutURL(_ folder: URL) -> URL { folder.appendingPathComponent("about.json") }

    nonisolated private static func readAbout(at folder: URL) -> About? {
        guard let data = try? Data(contentsOf: aboutURL(folder)) else { return nil }
        return try? JSONDecoder().decode(About.self, from: data)
    }

    private static func readAbout(_ id: String) -> About? {
        readAbout(at: CachedTorrent.folder(forInfoHash: id, in: AppModel.cacheDirectory))
    }

    /// Keeps `about` beside the torrent's data, and in the list.
    private func update(_ id: String, _ about: About) {
        let folder = CachedTorrent.folder(forInfoHash: id, in: AppModel.cacheDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(about) { try? data.write(to: Self.aboutURL(folder), options: .atomic) }
        if let i = items.firstIndex(where: { $0.id == id }) {
            items[i].about = about
        } else {
            items.append(Item(id: id, about: about, modified: Date()))
        }
    }

    // MARK: - Running

    /// Starts what's waiting while there's room, oldest first.
    private func schedule() {
        for (id, _) in running where !(item(id)?.isWanted ?? false) { stop(id) }
        let waiting = items.filter { $0.isWanted && running[$0.id] == nil }.sorted { $0.about.added < $1.about.added }
        for item in waiting.prefix(max(0, Self.maxActive - running.count)) { start(item.id) }
    }

    private func start(_ id: String) {
        guard let app, let item = item(id) else { return }
        running[id] = Running()
        let known = sources[id]
        Task {
            let resolved: TorrentSource?
            if let known { resolved = known } else { resolved = await Self.source(link: item.about.link, id: id) }
            guard running[id] != nil, running[id]?.session == nil else { return }
            guard let source = resolved, self.item(id)?.isWanted == true else {
                running[id] = nil
                if resolved == nil { setError(id, "Couldn't find this torrent again.") }
                return schedule()
            }
            let engine = app.engineForNewTorrent()
            let session = engine.session(for: source)
            running[id] = Running(engine: engine, session: session)
            poll()
            do {
                let info = try await session.waitForMetadata()
                guard running[id]?.session === session else { return }
                resolve(id, info)
                session.setDownloads(wantedFiles(id))
            } catch {
                guard running[id]?.session === session else { return }
                setError(id, error.localizedDescription)
                stop(id)
            }
        }
    }

    private func stop(_ id: String) {
        guard let run = running.removeValue(forKey: id) else { return }
        if let i = items.firstIndex(where: { $0.id == id }) {
            items[i].rate = nil
            items[i].peers = nil
        }
        guard let session = run.session else { return }
        // The player may hold it too: stop downloading, and let go.
        session.setDownloads([])
        run.engine?.release(session)
    }

    /// Finds each film or episode's file in the torrent's file list.
    private func resolve(_ id: String, _ info: TorrentInfo) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].info = info
        var about = items[i].about
        if about.parts.isEmpty {
            about.parts = info.mainVideoFile.map { [Part(file: $0.index, label: about.title)] } ?? []
        }
        for k in about.parts.indices where about.parts[k].file == nil {
            about.parts[k].file = PlaybackController.fileToPlay(in: info, season: about.parts[k].season, episode: about.parts[k].episode)?.index
        }
        // Two episodes a season pack doesn't name apart would be one file.
        var seen = Set<Int>()
        about.parts.removeAll { part in part.file.map { !seen.insert($0).inserted } ?? false }
        if about != items[i].about { update(id, about) }
    }

    /// The films and episodes, and every subtitle file beside them.
    private func wantedFiles(_ id: String) -> Set<Int> {
        guard let item = item(id), let info = item.info else { return [] }
        return Set(item.about.parts.compactMap(\.file)).union(info.contentFiles.filter(\.isSubtitle).map(\.index))
    }

    private func setError(_ id: String, _ message: String) {
        if let i = items.firstIndex(where: { $0.id == id }) { items[i].error = message }
    }

    /// Each second while anything downloads: progress, speed, and what's done.
    private func poll() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, !self.running.isEmpty else { break }
                await self.updateRunning()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            self?.pollTask = nil
        }
    }

    private func updateRunning() async {
        for (id, run) in running {
            guard let session = run.session else { continue }
            let stats = await session.stats()
            let files = item(id)?.info?.contentFiles.map(\.index) ?? []
            let progress = files.isEmpty ? [:] : await session.fileProgress(files)
            guard running[id]?.session === session, let i = items.firstIndex(where: { $0.id == id }) else { continue }
            if !progress.isEmpty { items[i].progress = progress }
            items[i].rate = stats.downloadRate
            items[i].peers = stats.connectedPeers
            items[i].error = nil
            if case .failed(let why) = stats.phase { items[i].error = why }
            if items[i].isComplete {
                stop(id)
                schedule()
            }
        }
    }

    // MARK: - Links

    /// The torrent a link names: a magnet as it is, a .torrent file fetched.
    /// With `id`, a link that's gone falls back to a bare magnet, which finds
    /// the file list in the cache and peers through the DHT.
    nonisolated static func source(link: String?, id: String? = nil) async -> TorrentSource? {
        if let link {
            if link.lowercased().hasPrefix("magnet:"), let magnet = try? MagnetLink(string: link), id == nil || magnet.infoHashHex == id {
                return .magnet(magnet)
            }
            if let url = URL(string: link), url.scheme?.hasPrefix("http") == true,
               let meta = try? await FeedClient.torrent(url), id == nil || meta.info.infoHashHex == id {
                return .metainfo(meta)
            }
        }
        guard let id, let magnet = try? MagnetLink(string: "magnet:?xt=urn:btih:\(id)") else { return nil }
        return .magnet(magnet)
    }
}
