import AppKit
import Observation
import SwiftUI
import TorrentKit
import UniformTypeIdentifiers

@MainActor
@Observable
final class AppModel {
    static let shared: AppModel = {
        // Before anything reads settings or the library.
        Migration.fromMatinee()
        return AppModel()
    }()

    var section: CatalogSection = .movies {
        didSet {
            if section != oldValue {
                selectedItem = nil
                selectedFeedTitle = nil
                selectedAPITitle = nil
                reloadBrowse()
            }
        }
    }
    private var genreBySection: [CatalogSection: Genre] = [:]
    var sort: SortOption = .popular {
        didSet { if sort != oldValue { reloadBrowse() } }
    }
    var searchText = "" {
        didSet { if searchText != oldValue { scheduleSearch() } }
    }
    var selectedItem: CatalogItem?
    var selectedFeedTitle: FeedTitle?
    var selectedAPITitle: APITitle?
    /// The custom source shown under Sources.
    var sourceID: UUID? {
        didSet {
            if sourceID != oldValue, section == .sources {
                selectedFeedTitle = nil
                selectedAPITitle = nil
                reloadBrowse()
            }
        }
    }
    var feedSort: FeedSort = .seeds {
        didSet { feedBrowse.resort(feedSort) }
    }
    /// What a catalog API source lists, and how.
    var apiType: APIMediaType = .movies {
        didSet { if apiType != oldValue { selectedAPITitle = nil; reloadBrowse() } }
    }
    var apiGenre: Genre = .all {
        didSet { if apiGenre != oldValue { reloadBrowse() } }
    }
    var apiSort: APISort = .trending {
        didSet { if apiSort != oldValue { reloadBrowse() } }
    }
    var playback: PlaybackController?
    var torrentFlow: TorrentFlow?
    var magnetPromptVisible = false
    var searchFocusRequest = 0
    var alertMessage: String?

    let library = Library()
    let browse = BrowseModel()
    let sources = SourceStore()
    let feedBrowse = FeedBrowseModel()
    let apiBrowse = APIBrowseModel()
    private(set) var engine: TorrentEngine
    private var engineConfig: TorrentConfiguration
    private var searchTask: Task<Void, Never>?
    private var metainfoCache: [String: Metainfo] = [:]

    nonisolated static let cacheDirectory: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Bobcorn/Torrents", isDirectory: true)

    init() {
        Pref.register()
        let config = Self.currentConfig()
        engineConfig = config
        engine = TorrentEngine(configuration: config)
    }

    var genre: Genre {
        get { genreBySection[section] ?? .all }
        set {
            guard newValue != genre else { return }
            genreBySection[section] = newValue
            reloadBrowse()
        }
    }

    var query: CatalogQuery {
        CatalogQuery(section: section, genre: genre, sort: sort, search: searchText.trimmingCharacters(in: .whitespaces))
    }

    func reloadBrowse() {
        switch section {
        case .myList:
            return
        case .sources:
            if let source = currentSource, let base = source.apiBase {
                let search = searchText.trimmingCharacters(in: .whitespaces)
                apiBrowse.load(source, APIQuery(sourceID: source.id, base: base, type: apiType, genre: apiGenre, sort: apiSort, search: search))
            } else {
                feedBrowse.load(currentSource, search: searchText, sort: feedSort)
            }
        default:
            browse.load(query)
        }
    }

    // MARK: - Custom sources

    /// The top-bar tabs: Sources appears once a source is enabled.
    var visibleSections: [CatalogSection] {
        CatalogSection.allCases.filter { $0 != .sources || !sources.enabled.isEmpty }
    }

    var currentSource: CustomSource? {
        sources.enabled.first { $0.id == sourceID } ?? sources.enabled.first
    }

    /// Called after Settings adds, edits, enables or removes a source.
    func sourcesChanged() {
        guard section == .sources else { return }
        if sources.enabled.isEmpty {
            section = .movies
        } else {
            selectedFeedTitle = nil
            selectedAPITitle = nil
            reloadBrowse()
        }
    }

    /// Plays one torrent a feed lists: once its file list arrives, a lone
    /// video starts by itself; otherwise the files are offered.
    func playFeed(_ option: FeedOption, in title: FeedTitle) {
        let presentation = TorrentPresentation(title: title.displayTitle, artwork: title.imageURL)
        if let link = option.entry.magnet, let magnet = try? MagnetLink(string: link) {
            beginTorrent(.magnet(magnet), name: title.displayTitle, presentation: presentation, autoPlay: true)
            return
        }
        guard let url = option.entry.torrentURL else {
            alertMessage = "This entry has no magnet link or .torrent file."
            return
        }
        Task {
            do {
                let meta = try await FeedClient.torrent(url)
                beginTorrent(.metainfo(meta), name: title.displayTitle, presentation: presentation, autoPlay: true)
            } catch {
                alertMessage = "Couldn't open the torrent: \(error.localizedDescription)"
            }
        }
    }

    /// Plays a catalog API movie, or a show from this episode on: the rest of
    /// the show follows in order, each episode in the quality picked here when
    /// it comes in it.
    func playAPI(_ details: APIDetails, episode: APIEpisode?, option: FeedOption) {
        let show = details.title
        var items: [PlayableItem] = []
        var start = 0
        if let episode {
            for e in details.episodes {
                let pick = e.id == episode.id ? option : e.options.best(preferring: option.release.quality)
                guard let link = pick?.entry.link else { continue }
                if e.id == episode.id { start = items.count }
                items.append(PlayableItem(
                    key: details.key(e),
                    title: "\(e.tag) · \(e.title)",
                    media: .link(link, season: e.season, episode: e.episode),
                    isNative: true,
                    subtitles: []
                ))
            }
        } else if let link = option.entry.link {
            items = [PlayableItem(key: show.libraryKey, title: show.title, media: .link(link, season: nil, episode: nil), isNative: true, subtitles: [])]
        }
        guard !items.isEmpty else {
            alertMessage = "This entry has no magnet link or .torrent file."
            return
        }
        startPlayback(PlaybackRequest(
            title: show.title,
            artwork: show.posterURL,
            items: items,
            startIndex: start,
            catalogItem: nil,
            ownedSession: nil
        ))
    }

    private func scheduleSearch() {
        searchTask?.cancel()
        searchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled, let self else { return }
            if self.section == .myList { self.section = .movies } else { self.reloadBrowse() }
        }
    }

    // MARK: - Torrent engine

    nonisolated private static func currentConfig() -> TorrentConfiguration {
        let d = UserDefaults.standard
        var c = TorrentConfiguration(cacheDirectory: cacheDirectory)
        c.maxPeers = max(10, d.integer(forKey: Pref.maxPeers))
        c.enableDHT = d.bool(forKey: Pref.enableDHT)
        c.usePublicTrackers = d.bool(forKey: Pref.publicTrackers)
        return c
    }

    /// The engine to start a new torrent in, rebuilt if the settings changed
    /// and nothing is running on the old one.
    func engineForNewTorrent() -> TorrentEngine {
        let c = Self.currentConfig()
        if c.maxPeers != engineConfig.maxPeers || c.enableDHT != engineConfig.enableDHT
            || c.usePublicTrackers != engineConfig.usePublicTrackers,
            engine.activeSessionCount == 0 {
            engine.stopAll()
            engine.server.stop()
            engineConfig = c
            engine = TorrentEngine(configuration: c)
        }
        return engine
    }

    /// An Internet Archive item's torrent, with the item's current data nodes
    /// added as web seeds. Kept for the session: the detail page and the
    /// player use the same one.
    func archiveMetainfo(identifier: String, torrentURLs: [URL], webSeeds: [String]) async throws -> Metainfo {
        if let cached = metainfoCache[identifier] { return cached }
        let fetched = try Metainfo(data: try await ArchiveClient.fetchFirst(torrentURLs))
        let seeds = webSeeds + fetched.webSeeds.filter { !webSeeds.contains($0) }
        let meta = Metainfo(info: fetched.info, trackers: fetched.trackers, webSeeds: seeds)
        metainfoCache[identifier] = meta
        return meta
    }

    func clearCache() {
        guard playback == nil, torrentFlow == nil else {
            alertMessage = "Stop playback before clearing the cache."
            return
        }
        engine.stopAll()
        try? FileManager.default.removeItem(at: Self.cacheDirectory)
    }

    func shutdown() {
        playback?.stop()
        library.saveNow()
        engine.stopAll()
        if UserDefaults.standard.bool(forKey: Pref.clearCacheOnQuit) {
            try? FileManager.default.removeItem(at: Self.cacheDirectory)
        }
    }

    // MARK: - Playback

    func play(details: ItemDetails, group: VideoGroup, variant: VideoVariant?) {
        let dataSaver = Pref.dataSaverOn
        let subtitles = details.subtitles.map {
            SubtitleTrack(id: $0.name, label: $0.label, source: .remote(details.urls(for: $0.name)))
        }
        let items = details.videos.map { g -> PlayableItem in
            let v = (g.id == group.id ? variant : nil) ?? g.preferred(dataSaver: dataSaver) ?? g.variants[0]
            return PlayableItem(
                key: "ia:\(details.item.id):\(g.id)",
                title: details.videos.count > 1 ? g.title : details.item.title,
                media: .archive(
                    identifier: details.item.id,
                    file: v.name,
                    torrentURLs: details.torrentURLs,
                    directURLs: details.urls(for: v.name),
                    webSeeds: details.webSeeds
                ),
                isNative: v.isNative,
                subtitles: subtitles
            )
        }
        let start = details.videos.firstIndex { $0.id == group.id } ?? 0
        let request = PlaybackRequest(
            title: details.item.title,
            artwork: details.item.posterURL,
            items: items,
            startIndex: start,
            catalogItem: details.item,
            ownedSession: nil
        )
        startPlayback(request)
    }

    func startPlayback(_ request: PlaybackRequest) {
        playback?.stop()
        let controller = PlaybackController(request: request, app: self)
        withAnimation(.easeInOut(duration: 0.25)) { playback = controller }
        controller.start()
    }

    func closePlayback() {
        playback?.stop()
        withAnimation(.easeInOut(duration: 0.25)) { playback = nil }
    }

    // MARK: - Opening torrents

    func open(url: URL) {
        if url.scheme?.lowercased() == "magnet" {
            openMagnet(url.absoluteString)
        } else if url.isFileURL {
            do {
                openTorrent(data: try Data(contentsOf: url))
            } catch {
                alertMessage = "Could not read \(url.lastPathComponent): \(error.localizedDescription)"
            }
        }
    }

    func openMagnet(_ text: String) {
        do {
            let magnet = try MagnetLink(string: text)
            beginTorrent(.magnet(magnet), name: magnet.displayName ?? "Magnet link")
        } catch {
            alertMessage = "That doesn't look like a magnet link."
        }
    }

    func openTorrent(data: Data) {
        do {
            let meta = try Metainfo(data: data)
            beginTorrent(.metainfo(meta), name: meta.info.name)
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    func openTorrentFilePanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "torrent") ?? .data]
        panel.allowsMultipleSelection = false
        panel.message = "Choose a .torrent file to stream"
        if panel.runModal() == .OK, let url = panel.url { open(url: url) }
    }

    private func beginTorrent(_ source: TorrentSource, name: String, presentation: TorrentPresentation? = nil, autoPlay: Bool = false) {
        torrentFlow?.cancel()
        let session = engineForNewTorrent().session(for: source)
        torrentFlow = TorrentFlow(session: session, name: name, app: self, presentation: presentation, autoPlay: autoPlay)
    }

    func playTorrent(flow: TorrentFlow, file: TorrentFile) {
        guard let info = flow.info else { return }
        let subtitleFiles = info.contentFiles.filter(\.isSubtitle)
        let subtitles = subtitleFiles.map {
            SubtitleTrack(id: "bt:\($0.index)", label: $0.name, source: .torrent(fileIndex: $0.index))
        }
        // Every video in the torrent, in name order, so "next" walks a season.
        let videos = info.contentFiles.filter(\.isVideo)
            .sorted { $0.displayPath.localizedStandardCompare($1.displayPath) == .orderedAscending }
        let playable = videos.isEmpty ? [file] : videos
        let items = playable.map { f in
            PlayableItem(
                key: "bt:\(info.infoHashHex):\(f.index)",
                title: (f.name as NSString).deletingPathExtension,
                media: .torrent(session: flow.session, file: f),
                isNative: f.isNativelyPlayable,
                subtitles: subtitles
            )
        }
        let request = PlaybackRequest(
            title: flow.presentation?.title ?? info.name,
            artwork: flow.presentation?.artwork,
            items: items,
            startIndex: playable.firstIndex { $0.index == file.index } ?? 0,
            catalogItem: nil,
            ownedSession: flow.session
        )
        flow.handedOff = true
        flow.finish()
        torrentFlow = nil
        startPlayback(request)
    }
}

/// How a torrent opened from a source is shown in the player.
struct TorrentPresentation {
    let title: String
    let artwork: URL?
}

/// The listing behind the poster grid, loaded a page at a time.
@MainActor
@Observable
final class BrowseModel {
    private(set) var items: [CatalogItem] = []
    private(set) var isLoading = false
    private(set) var error: String?
    private(set) var exhausted = false
    private(set) var total = 0
    private var query: CatalogQuery?
    private var page = 0
    private var task: Task<Void, Never>?
    private var seen = Set<String>()

    func load(_ q: CatalogQuery) {
        task?.cancel()
        query = q
        items = []
        seen = []
        page = 0
        exhausted = false
        error = nil
        isLoading = false
        loadMore()
    }

    func loadMore() {
        guard let query, !isLoading, !exhausted else { return }
        isLoading = true
        error = nil
        let next = page + 1
        task = Task { [weak self] in
            do {
                let result = try await ArchiveClient.search(query, page: next)
                guard let self, !Task.isCancelled, self.query == query else { return }
                let fresh = result.items.filter { self.seen.insert($0.id).inserted }
                self.items.append(contentsOf: fresh)
                self.page = next
                self.total = result.total
                self.exhausted = result.items.count < ArchiveClient.pageSize || self.items.count >= result.total
                self.isLoading = false
            } catch {
                guard let self, !Task.isCancelled, self.query == query else { return }
                self.error = error.localizedDescription
                self.isLoading = false
            }
        }
    }

    func retry() {
        if let query, items.isEmpty { load(query) } else { loadMore() }
    }
}

/// A magnet or .torrent being opened: waits for the file list, then lets the
/// user pick what to play.
@MainActor
@Observable
final class TorrentFlow: Identifiable {
    let id = UUID()
    let session: TorrentSession
    let name: String
    private(set) var info: TorrentInfo?
    private(set) var stats = TorrentStats()
    private(set) var availability: [Int: FileAvailability] = [:]
    private(set) var error: String?
    var handedOff = false
    let presentation: TorrentPresentation?
    private let autoPlay: Bool
    private weak var app: AppModel?
    private var tasks: [Task<Void, Never>] = []

    init(session: TorrentSession, name: String, app: AppModel, presentation: TorrentPresentation? = nil, autoPlay: Bool = false) {
        self.session = session
        self.name = name
        self.app = app
        self.presentation = presentation
        self.autoPlay = autoPlay
        tasks.append(Task { [weak self] in
            do {
                let info = try await session.waitForMetadata()
                guard let self else { return }
                self.info = info
                if self.autoPlay, let only = self.loneVideo, !self.handedOff {
                    self.app?.playTorrent(flow: self, file: only)
                }
            } catch {
                self?.error = error.localizedDescription
            }
        })
        tasks.append(Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.stats = await session.stats()
                if let info = self.info {
                    self.availability = await session.availability(of: info.contentFiles.filter(\.isVideo).map(\.index))
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        })
    }

    /// Best-seeded first; among equals, what plays in Bobcorn, then largest.
    var videoFiles: [TorrentFile] {
        (info?.contentFiles ?? []).filter(\.isVideo).sorted { a, b in
            let ra = availability[a.index]?.rank ?? (0, 0, 0)
            let rb = availability[b.index]?.rank ?? (0, 0, 0)
            if ra != rb { return ra > rb }
            if a.playsInApp != b.playsInApp { return a.playsInApp }
            return a.length > b.length
        }
    }

    /// The one video worth playing: the only one, or one that dwarfs the rest
    /// (a film beside its sample clip). Files that play in Bobcorn are weighed
    /// alone when there are any, so a big MPEG never hides an MP4.
    var loneVideo: TorrentFile? {
        let videos = (info?.contentFiles ?? []).filter(\.isVideo)
        let native = videos.filter(\.playsInApp)
        let pool = (native.isEmpty ? videos : native).sorted { $0.length > $1.length }
        guard let first = pool.first else { return nil }
        if pool.count == 1 || first.length > 4 * pool[1].length { return first }
        return nil
    }

    var otherFiles: [TorrentFile] {
        (info?.contentFiles ?? []).filter { !$0.isVideo }
    }

    /// Closing the sheet without playing stops the torrent.
    func cancel() {
        tasks.forEach { $0.cancel() }
        if !handedOff { app?.engine.release(session) }
    }

    func finish() {
        tasks.forEach { $0.cancel() }
    }
}
