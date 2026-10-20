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
                selectedFeedTitle = nil
                selectedAPITitle = nil
                reloadBrowse()
            }
        }
    }
    var searchText = "" {
        didSet { if searchText != oldValue { scheduleSearch() } }
    }
    var selectedFeedTitle: FeedTitle?
    var selectedAPITitle: APITitle?
    /// The source whose movies and shows the tabs show.
    var sourceID: UUID? {
        didSet {
            if sourceID != oldValue {
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
    var apiType: APIMediaType { section == .shows ? .shows : .movies }
    var apiGenre: Genre = .all {
        didSet { if apiGenre != oldValue { reloadBrowse() } }
    }
    var apiSort: APISort = .trending {
        didSet { if apiSort != oldValue { reloadBrowse() } }
    }
    var playback: PlaybackController?
    var torrentFlow: TorrentFlow?
    var magnetPromptVisible = false
    var addSourceVisible = false
    /// What the Add Source form starts with.
    var addSourceDraft = CustomSource(kind: .api, name: "", feedURL: "")
    var searchFocusRequest = 0
    var alertMessage: String?

    let library = Library()
    let sources = SourceStore()
    let feedBrowse = FeedBrowseModel()
    let apiBrowse = APIBrowseModel()
    let castDevices = CastDevices()
    let ratings = Ratings()
    let downloads = Downloads()
    let updater = Updater()
    var updatePromptVisible = false
    private(set) var engine: TorrentEngine
    private var engineConfig: TorrentConfiguration
    private var searchTask: Task<Void, Never>?

    /// A debug build keeps its downloads apart, like its library.
    nonisolated static let defaultCacheDirectory: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent(Bundle.main.bundleIdentifier?.hasSuffix(".debug") == true ? "Bobcorn Debug/Torrents" : "Bobcorn/Torrents", isDirectory: true)

    /// The folder picked in Settings, when there is one and it's there (a
    /// drive can be unplugged).
    nonisolated static var chosenCacheFolder: URL? {
        guard let path = UserDefaults.standard.string(forKey: Pref.cacheFolder), !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// Where torrents download. In a chosen folder, a subfolder of its own,
    /// so clearing the cache never touches anything else there.
    nonisolated static var cacheDirectory: URL {
        if let folder = chosenCacheFolder, FileManager.default.fileExists(atPath: folder.path) {
            return folder.appendingPathComponent("Bobcorn Torrents", isDirectory: true)
        }
        return defaultCacheDirectory
    }

    init() {
        Pref.register()
        let config = Self.currentConfig()
        engineConfig = config
        engine = TorrentEngine(configuration: config)
        downloads.app = self
        downloads.refresh()
    }

    /// Loads the current source's movies or shows. A feed is fetched once for
    /// both tabs unless `force`.
    func reloadBrowse(force: Bool = false) {
        guard section.browsesSource, let source = currentSource else { return }
        let search = searchText.trimmingCharacters(in: .whitespaces)
        if let base = source.apiBase {
            apiBrowse.load(source, APIQuery(sourceID: source.id, base: base, type: apiType, genre: apiGenre, sort: apiSort, search: search))
        } else {
            feedBrowse.load(source, search: search, sort: feedSort, force: force)
        }
    }

    // MARK: - Sources

    var currentSource: CustomSource? {
        sources.enabled.first { $0.id == sourceID } ?? sources.enabled.first
    }

    /// Called after Settings adds, edits, enables or removes a source.
    func sourcesChanged() {
        selectedFeedTitle = nil
        selectedAPITitle = nil
        reloadBrowse(force: true)
    }

    func addSource(_ source: CustomSource) {
        sources.upsert(source)
        sourceID = source.id
        sourcesChanged()
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
                    subtitles: []
                ))
            }
        } else if let link = option.entry.link {
            items = [PlayableItem(key: show.libraryKey, title: show.title, media: .link(link, season: nil, episode: nil), subtitles: [])]
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
            saved: show.saved,
            ownedSession: nil
        ))
    }

    // MARK: - Downloads

    /// Downloads a catalog API movie in this torrent, or these episodes of a
    /// show, each in the torrent picked or else its best seeded one. A season
    /// pack's episodes download together.
    func downloadAPI(_ details: APIDetails, episodes: [APIEpisode] = [], option: FeedOption? = nil) {
        let show = details.title
        func about(_ parts: [Downloads.Part]) -> Downloads.About {
            Downloads.About(title: show.title, poster: show.posterURL, saved: show.saved,
                            series: show.type == .shows ? show.title : nil, parts: parts)
        }
        if episodes.isEmpty {
            guard let link = (option ?? show.options.best())?.entry.link else { return }
            downloads.download(link: link, about: about([Downloads.Part(key: show.libraryKey, label: show.title)]))
            return
        }
        var byLink: [(link: String, parts: [Downloads.Part])] = []
        for e in episodes {
            guard let link = (episodes.count == 1 ? option : nil)?.entry.link ?? e.options.best()?.entry.link else { continue }
            let part = Downloads.Part(season: e.season, episode: e.episode, key: details.key(e), label: "\(e.tag) · \(e.title)")
            if let i = byLink.firstIndex(where: { $0.link == link }) { byLink[i].parts.append(part) } else { byLink.append((link, [part])) }
        }
        for group in byLink { downloads.download(link: group.link, about: about(group.parts)) }
    }

    /// Downloads one torrent a feed lists for a title.
    func downloadFeed(_ option: FeedOption, in title: FeedTitle) {
        guard let link = option.entry.link else {
            alertMessage = "This entry has no magnet link or .torrent file."
            return
        }
        // An episode goes with the rest of its show.
        let series = title.episodeTag == nil ? nil : title.title
        downloads.download(link: link, about: Downloads.About(title: series ?? title.displayTitle, poster: title.imageURL, series: series,
                                                               parts: [Downloads.Part(season: option.release.season, episode: option.release.episode,
                                                                                      label: title.episodeTag ?? title.displayTitle)]))
    }

    func showDownloads() {
        selectedAPITitle = nil
        selectedFeedTitle = nil
        section = .downloads
    }

    /// Plays from the cache: the film or episode picked, then the rest of
    /// what's downloaded of it, a show's next episodes in whichever torrents
    /// they're in.
    func playDownload(_ group: Downloads.Group, entry: Downloads.Group.Entry) {
        let entries = group.entries.filter { $0.part.file != nil }
        let items = entries.map { e in
            PlayableItem(key: e.part.key ?? "bt:\(e.item.id):\(e.part.file!)", title: e.part.label,
                         media: .cached(infoHash: e.item.id, link: e.item.about.link, file: e.part.file!,
                                        season: e.part.season, episode: e.part.episode),
                         subtitles: [])
        }
        guard !items.isEmpty else { return }
        startPlayback(PlaybackRequest(
            title: group.title,
            artwork: group.about.poster,
            items: items,
            startIndex: entries.firstIndex { $0.id == entry.id } ?? 0,
            saved: group.about.saved,
            ownedSession: nil
        ))
    }

    private func scheduleSearch() {
        searchTask?.cancel()
        searchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled, let self else { return }
            if !self.section.browsesSource { self.section = .movies } else { self.reloadBrowse() }
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
            || c.usePublicTrackers != engineConfig.usePublicTrackers || c.cacheDirectory != engineConfig.cacheDirectory,
            engine.activeSessionCount == 0 {
            engine.stopAll()
            engine.server.stop()
            engineConfig = c
            engine = TorrentEngine(configuration: c)
        }
        return engine
    }

    func clearCache() {
        guard playback == nil, torrentFlow == nil else {
            alertMessage = "Stop playback before clearing the cache."
            return
        }
        downloads.suspend()
        engine.stopAll()
        Downloads.clearStreamed(in: Self.cacheDirectory)
        downloads.refresh()
    }

    /// Downloads go to `folder` from now on (nil: back to the default), and
    /// what's downloaded already moves there. False if it can't now.
    func moveCache(to folder: URL?) async -> Bool {
        guard playback == nil, torrentFlow == nil else {
            alertMessage = "Stop playback before moving the cache."
            return false
        }
        let old = Self.cacheDirectory
        if let folder {
            UserDefaults.standard.set(folder.path, forKey: Pref.cacheFolder)
        } else {
            UserDefaults.standard.removeObject(forKey: Pref.cacheFolder)
        }
        let new = Self.cacheDirectory
        guard old.standardizedFileURL != new.standardizedFileURL else { return true }
        downloads.suspend()
        engine.stopAll()
        defer { downloads.refresh() }
        let failure: String? = await Task.detached {
            let fm = FileManager.default
            do {
                try fm.createDirectory(at: new, withIntermediateDirectories: true)
            } catch {
                return "Bobcorn can't write to that folder: \(error.localizedDescription)"
            }
            // Torrent by torrent, so a half-done move still leaves each whole.
            for item in (try? fm.contentsOfDirectory(at: old, includingPropertiesForKeys: nil)) ?? [] {
                let target = new.appendingPathComponent(item.lastPathComponent)
                if !fm.fileExists(atPath: target.path) { try? fm.moveItem(at: item, to: target) }
            }
            if (try? fm.contentsOfDirectory(atPath: old.path))?.isEmpty == true { try? fm.removeItem(at: old) }
            return nil
        }.value
        if let failure {
            if folder != nil { UserDefaults.standard.removeObject(forKey: Pref.cacheFolder) }
            alertMessage = failure
            return false
        }
        return true
    }

    // MARK: - Updates

    func installUpdate() {
        Task {
            do {
                try await updater.install()
            } catch {
                alertMessage = "Couldn't update Bobcorn: \(error.localizedDescription)"
            }
        }
    }

    /// From the menu: says so when there's nothing new.
    func checkForUpdates() {
        Task {
            do {
                if try await updater.check() != nil {
                    updatePromptVisible = true
                } else {
                    alertMessage = "Bobcorn \(Updater.currentVersion) is the latest version."
                }
            } catch {
                alertMessage = "Couldn't check for updates: \(error.localizedDescription)"
            }
        }
    }

    func shutdown() {
        playback?.stop()
        library.saveNow()
        engine.stopAll()
        if UserDefaults.standard.bool(forKey: Pref.clearCacheOnQuit) {
            Downloads.clearStreamed(in: Self.cacheDirectory)
        }
    }

    // MARK: - Playback

    func startPlayback(_ request: PlaybackRequest) {
        playback?.stop()
        let controller = PlaybackController(request: request, app: self)
        withAnimation(.easeInOut(duration: 0.25)) { playback = controller }
        controller.start()
    }

    func closePlayback() {
        playback?.stop()
        withAnimation(.easeInOut(duration: 0.25)) { playback = nil }
        downloads.refresh()
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
                subtitles: subtitles
            )
        }
        let request = PlaybackRequest(
            title: flow.presentation?.title ?? info.name,
            artwork: flow.presentation?.artwork,
            items: items,
            startIndex: playable.firstIndex { $0.index == file.index } ?? 0,
            saved: nil,
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
