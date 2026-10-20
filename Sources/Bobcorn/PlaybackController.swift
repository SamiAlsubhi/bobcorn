import AVFoundation
import AppKit
import Observation
import Remux
import TorrentKit

struct PlayableItem: Identifiable {
    enum Media {
        /// An Internet Archive file: streamed through its torrent when there is
        /// one, straight over HTTPS otherwise. Each URL list is in the order to
        /// try, since a data node can be down while others hold the same file.
        case archive(identifier: String, file: String, torrentURLs: [URL], directURLs: [URL], webSeeds: [String])
        /// A file of a torrent the user opened.
        case torrent(session: TorrentSession, file: TorrentFile)
        /// A catalog API's magnet or .torrent URL, opened when it plays. An
        /// episode picks its own file out of a season pack.
        case link(String, season: Int?, episode: Int?)
    }

    /// Also the key its resume position is stored under.
    let key: String
    let title: String
    let media: Media
    let isNative: Bool
    let subtitles: [SubtitleTrack]

    var id: String { key }
}

struct PlaybackRequest {
    var title: String
    var artwork: URL?
    var items: [PlayableItem]
    var startIndex: Int
    var catalogItem: CatalogItem?
    /// A torrent the user opened, stopped when the player closes.
    var ownedSession: TorrentSession?
}

@MainActor
@Observable
final class PlaybackController {
    enum Phase: Equatable {
        case preparing
        case playing
        /// The format needs VLC or IINA; the stream is served for them.
        case needsExternalPlayer
        case external(String)
        case failed(String)
    }

    let request: PlaybackRequest
    private(set) var index: Int
    private(set) var phase: Phase = .preparing
    private(set) var statusText = "Preparing"
    private(set) var player: AVPlayer?
    private(set) var streamURL: URL?
    /// The torrent file itself, when AVPlayer plays a remuxed copy of it:
    /// what another player should open.
    private(set) var fileURL: URL?
    /// What the remuxer made of a Matroska file it plays, for the logs.
    private(set) var remuxSummary: String?
    /// Why a file needs another player, when Bobcorn knows.
    private(set) var externalReason: String?
    private(set) var stats: TorrentStats?
    private(set) var viaTorrent = false
    private(set) var hasStarted = false
    private(set) var isBuffering = false
    private(set) var notice: String?
    private(set) var activeSubtitleID: String?
    private(set) var cueText: String?
    private(set) var localSubtitles: [SubtitleTrack] = []

    private weak var app: AppModel?
    private var session: TorrentSession?
    private var sessionIsOurs = false
    private var cues: [SubtitleCue] = []
    private var timeObserver: Any?
    private var timeObserverPlayer: AVPlayer?
    private var observations: [NSKeyValueObservation] = []
    private var endObserver: NSObjectProtocol?
    private var prepareTask: Task<Void, Never>?
    private var statsTask: Task<Void, Never>?
    private var noticeTask: Task<Void, Never>?
    private var lastDownloaded: Int64 = -1
    private var lastProgressAt = Date()
    private var lastSaved = Date.distantPast
    private var pendingSeek: Double?
    private var directCandidates: [URL] = []
    private var stopped = false

    init(request: PlaybackRequest, app: AppModel) {
        self.request = request
        self.index = request.startIndex
        self.app = app
    }

    var current: PlayableItem { request.items[index] }
    var hasNext: Bool { index + 1 < request.items.count }
    var hasPrevious: Bool { index > 0 }
    var subtitleTracks: [SubtitleTrack] { current.subtitles + localSubtitles }

    var displayTitle: String {
        request.items.count > 1 && current.title != request.title ? current.title : request.title
    }

    var displaySubtitle: String? {
        request.items.count > 1 && current.title != request.title ? request.title : nil
    }

    func start() {
        load(index)
        statsTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollStats()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        saveProgress()
        teardownItem()
        statsTask?.cancel()
        noticeTask?.cancel()
        player?.pause()
        player = nil
        if let owned = request.ownedSession { app?.engine.release(owned) }
    }

    func playNext() {
        guard hasNext else { return }
        load(index + 1)
    }

    func playPrevious() {
        guard hasPrevious else { return }
        load(index - 1)
    }

    // MARK: - Loading

    private func load(_ i: Int) {
        saveProgress()
        teardownItem()
        index = i
        phase = .preparing
        hasStarted = false
        isBuffering = false
        statusText = "Preparing"
        cues = []
        cueText = nil
        activeSubtitleID = nil
        lastDownloaded = -1
        lastProgressAt = Date()
        pendingSeek = app?.library.resumePosition(current.key)
        prepareTask = Task { [weak self] in await self?.prepare() }
    }

    private func prepare() async {
        guard let app else { return }
        let item = current
        switch item.media {
        case .archive(let identifier, let file, let torrentURLs, let directURLs, let extraSeeds):
            guard Pref.prefersTorrent, !torrentURLs.isEmpty else {
                playDirect(directURLs)
                return
            }
            statusText = "Fetching torrent"
            do {
                let meta = try await app.archiveMetainfo(identifier: identifier, torrentURLs: torrentURLs, webSeeds: extraSeeds)
                guard !Task.isCancelled else { return }
                guard let tf = meta.info.files.first(where: { $0.displayPath == file }) else {
                    throw TorrentError.noSuchFile
                }
                let s = app.engineForNewTorrent().session(for: .metainfo(meta))
                session = s
                sessionIsOurs = true
                s.select(fileIndex: tf.index)
                let url = try await app.engine.streamURL(for: s, file: tf)
                guard !Task.isCancelled else { return }
                viaTorrent = true
                directCandidates = directURLs
                statusText = "Connecting to peers"
                play(url)
            } catch {
                guard !Task.isCancelled else { return }
                show("Torrent unavailable, streaming directly from the Internet Archive")
                playDirect(directURLs)
            }

        case .torrent(let s, let file):
            session = s
            sessionIsOurs = false
            s.select(fileIndex: file.index)
            do {
                try await stream(file, from: s, app: app)
            } catch {
                guard !Task.isCancelled else { return }
                phase = .failed(error.localizedDescription)
            }

        case .link(let link, let season, let episode):
            do {
                let source: TorrentSource
                if link.lowercased().hasPrefix("magnet:") {
                    source = .magnet(try MagnetLink(string: link))
                } else if let url = URL(string: link) {
                    statusText = "Fetching torrent"
                    source = .metainfo(try await FeedClient.torrent(url))
                    guard !Task.isCancelled else { return }
                } else {
                    throw TorrentError.invalidMagnet
                }
                let s = app.engineForNewTorrent().session(for: source)
                session = s
                sessionIsOurs = true
                let info = try await s.waitForMetadata()
                guard !Task.isCancelled else { return }
                guard let file = Self.fileToPlay(in: info, season: season, episode: episode) else {
                    throw TorrentError.noSuchFile
                }
                s.select(fileIndex: file.index)
                try await stream(file, from: s, app: app)
            } catch {
                guard !Task.isCancelled else { return }
                phase = .failed(error.localizedDescription)
            }
        }
    }

    /// Plays a torrent's file as it downloads: as it is when macOS plays the
    /// format, as HLS remuxed on the fly when it's Matroska with codecs macOS
    /// decodes, and otherwise through another player.
    private func stream(_ file: TorrentFile, from s: TorrentSession, app: AppModel) async throws {
        let url = try await app.engine.streamURL(for: s, file: file)
        guard !Task.isCancelled else { return }
        viaTorrent = true
        if file.isNativelyPlayable {
            play(url)
            return
        }
        if HLSRemuxer.fileExtensions.contains(file.fileExtension) {
            statusText = "Reading the video's tracks"
            do {
                let remuxer = try await HLSRemuxer.open(TorrentByteSource(session: s, file: file))
                guard !Task.isCancelled else { return }
                let hls = app.engine.server.url(for: s, generated: "\(file.index)-hls", name: "index.m3u8") { path in
                    try await remuxer.respond(to: path)
                }
                fileURL = url
                remuxSummary = remuxer.summary
                play(hls)
                return
            } catch {
                guard !Task.isCancelled else { return }
                externalReason = error.localizedDescription
            }
        }
        streamURL = url
        phase = .needsExternalPlayer
    }

    /// When AVPlayer can't play the remuxed stream after all, the file still
    /// plays elsewhere.
    private func remuxFailed(_ message: String) {
        teardownObservers()
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        externalReason = message
        streamURL = fileURL
        fileURL = nil
        phase = .needsExternalPlayer
    }

    /// The episode's own file when the torrent names one (a season pack holds
    /// many), otherwise the main video. Samples don't count, and a file that
    /// plays in Bobcorn beats a bigger one that doesn't, unless it's a small
    /// extra.
    nonisolated static func fileToPlay(in info: TorrentInfo, season: Int?, episode: Int?) -> TorrentFile? {
        let videos = info.contentFiles.filter(\.isVideo)
        if let season, let episode, videos.count > 1 {
            // "Show.S02E05.mkv", "ShowS02e05.mp4", "Show 2x05.avi".
            let patterns = [#"(?i)(?<!\d)s0*\#(season)[ ._-]?e0*\#(episode)(?!\d)"#, #"(?<!\d)0*\#(season)x0*\#(episode)(?!\d)"#]
            let named = videos.filter { v in patterns.contains { v.name.range(of: $0, options: .regularExpression) != nil } }
            if let best = named.max(by: { $0.length < $1.length }) { return best }
        }
        let features = videos.filter { !$0.name.lowercased().contains("sample") }
        let pool = features.isEmpty ? videos : features
        let largest = pool.map(\.length).max() ?? 0
        let native = pool.filter { $0.playsInApp && $0.length * 4 >= largest }
        return (native.isEmpty ? pool : native).max { $0.length < $1.length }
    }

    /// Plays the first URL; a failure moves on to the next.
    private func playDirect(_ urls: [URL]) {
        guard let first = urls.first else {
            phase = .failed("The Internet Archive has no working copy of this file right now.")
            return
        }
        viaTorrent = false
        directCandidates = Array(urls.dropFirst())
        statusText = "Connecting to the Internet Archive"
        play(first)
    }

    private func play(_ url: URL) {
        streamURL = url
        let item = AVPlayerItem(url: url)
        item.preferredForwardBufferDuration = 20
        let p = player ?? AVPlayer()
        p.replaceCurrentItem(with: item)
        player = p
        attachObservers(p, item)
        p.play()
    }

    private func attachObservers(_ p: AVPlayer, _ item: AVPlayerItem) {
        observations = [
            item.observe(\.status, options: [.new]) { [weak self] item, _ in
                Task { @MainActor in self?.itemStatusChanged(item) }
            },
            p.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
                Task { @MainActor in self?.timeControlChanged(player) }
            },
        ]
        if timeObserverPlayer !== p {
            if let old = timeObserver, let oldPlayer = timeObserverPlayer { oldPlayer.removeTimeObserver(old) }
            timeObserver = p.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] time in
                MainActor.assumeIsolated { self?.tick(time.seconds) }
            }
            timeObserverPlayer = p
        }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.finishedItem() }
        }
    }

    private func itemStatusChanged(_ item: AVPlayerItem) {
        guard item === player?.currentItem else { return }
        switch item.status {
        case .readyToPlay:
            if let seek = pendingSeek {
                pendingSeek = nil
                player?.seek(to: CMTime(seconds: seek, preferredTimescale: 600))
                show("Resumed from \(formatTime(seek))")
            }
        case .failed:
            let message = item.error?.localizedDescription ?? "The video could not be played."
            if viaTorrent, case .archive = current.media {
                fallBackToDirect(reason: "Torrent stream failed, switching to direct streaming")
            } else if case .archive = current.media, !directCandidates.isEmpty {
                let resumeAt = pendingSeek
                teardownObservers()
                pendingSeek = resumeAt
                playDirect(directCandidates)
            } else if fileURL != nil {
                remuxFailed("macOS couldn't play the converted stream (\(message))")
            } else {
                phase = .failed(message)
            }
        default:
            break
        }
    }

    private func timeControlChanged(_ p: AVPlayer) {
        guard p === player else { return }
        switch p.timeControlStatus {
        case .playing:
            hasStarted = true
            isBuffering = false
            if phase == .preparing { phase = .playing }
        case .waitingToPlayAtSpecifiedRate:
            isBuffering = hasStarted
        case .paused:
            isBuffering = false
        @unknown default:
            break
        }
    }

    private func tick(_ seconds: Double) {
        if !cues.isEmpty {
            let text = SubtitleParser.cue(at: seconds, in: cues)?.text
            if text != cueText { cueText = text }
        }
        if Date().timeIntervalSince(lastSaved) > 5 {
            saveProgress()
        }
    }

    private func finishedItem() {
        saveProgress(finished: true)
        if hasNext && Pref.autoplay {
            playNext()
        }
    }

    private func fallBackToDirect(reason: String) {
        let resumeAt = player?.currentTime().seconds ?? 0
        if sessionIsOurs, let s = session {
            // The detail page may still hold the swarm open: stop downloading.
            s.clearSelection()
            app?.engine.release(s)
        }
        session = nil
        sessionIsOurs = false
        viaTorrent = false
        stats = nil
        show(reason)
        if resumeAt > 1 { pendingSeek = resumeAt }
        teardownObservers()
        playDirect(directCandidates)
    }

    // MARK: - Torrent status

    private func pollStats() async {
        guard let s = session, !stopped else { return }
        let st = await s.stats()
        guard s === session else { return }
        stats = st
        if st.downloaded != lastDownloaded {
            lastDownloaded = st.downloaded
            lastProgressAt = Date()
        }
        if !hasStarted {
            switch st.phase {
            case .fetchingMetadata:
                statusText = "Fetching metadata"
            case .failed(let why):
                statusText = why
            default:
                statusText = st.downloadRate > 0 ? "Buffering" : (st.connectedPeers + st.activeWebSeeds > 0 ? "Requesting data" : "Looking for peers")
            }
        }
        // A torrent that stopped moving before playback could start: the
        // Internet Archive serves the same file directly.
        if viaTorrent, case .archive = current.media,
           player?.timeControlStatus != .playing,
           Date().timeIntervalSince(lastProgressAt) > 20 {
            fallBackToDirect(reason: "The swarm stalled, switching to direct streaming")
        }
    }

    // MARK: - External players

    func openExternally(_ external: ExternalPlayer) {
        guard let url = fileURL ?? streamURL else { return }
        player?.pause()
        external.open(url)
        phase = .external(external.name)
    }

    func copyStreamURL() {
        guard let url = fileURL ?? streamURL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
        show("Stream URL copied")
    }

    // MARK: - Subtitles

    func selectSubtitle(_ id: String?) {
        activeSubtitleID = id
        cues = []
        cueText = nil
        guard let id, let track = subtitleTracks.first(where: { $0.id == id }) else { return }
        let session = self.session
        Task { [weak self] in
            do {
                let data: Data
                switch track.source {
                case .remote(let urls): data = try await ArchiveClient.fetchFirst(urls)
                case .local(let url): data = try Data(contentsOf: url)
                case .torrent(let fileIndex):
                    guard let session else { throw TorrentError.noSuchFile }
                    data = try await session.readFile(fileIndex: fileIndex)
                }
                let parsed = SubtitleParser.parse(data)
                guard let self, self.activeSubtitleID == id else { return }
                self.cues = parsed
                if parsed.isEmpty { self.show("No subtitles found in \(track.label)") }
            } catch {
                self?.show("Could not load subtitles: \(error.localizedDescription)")
            }
        }
    }

    func chooseSubtitleFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.init(filenameExtension: "srt"), .init(filenameExtension: "vtt")].compactMap { $0 }
        panel.message = "Choose a subtitle file (.srt or .vtt)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let track = SubtitleTrack(id: "local:\(url.path)", label: url.lastPathComponent, source: .local(url))
        if !localSubtitles.contains(track) { localSubtitles.append(track) }
        selectSubtitle(track.id)
    }

    // MARK: - Housekeeping

    func show(_ message: String) {
        notice = message
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }

    private func saveProgress(finished: Bool = false) {
        lastSaved = Date()
        guard let p = player, let item = p.currentItem, hasStarted else { return }
        let duration = item.duration.seconds
        guard duration.isFinite, duration > 0 else { return }
        let position = finished ? duration : p.currentTime().seconds
        app?.library.record(current.key, position: position, duration: duration, title: displayTitle, item: request.catalogItem)
    }

    private func teardownObservers() {
        observations.forEach { $0.invalidate() }
        observations.removeAll()
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
    }

    private func teardownItem() {
        prepareTask?.cancel()
        prepareTask = nil
        teardownObservers()
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        if let old = timeObserver, let oldPlayer = timeObserverPlayer { oldPlayer.removeTimeObserver(old) }
        timeObserver = nil
        timeObserverPlayer = nil
        if sessionIsOurs, let s = session {
            // The detail page may still hold the swarm open: stop downloading.
            s.clearSelection()
            app?.engine.release(s)
        }
        session = nil
        sessionIsOurs = false
        viaTorrent = false
        stats = nil
        streamURL = nil
        fileURL = nil
        remuxSummary = nil
        externalReason = nil
        directCandidates = []
    }
}
