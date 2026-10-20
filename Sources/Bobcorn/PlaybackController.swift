import AVFoundation
import AppKit
import AVKit
import CastKit
import Observation
import Remux
import TorrentKit

struct PlayableItem: Identifiable {
    enum Media {
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
    let subtitles: [SubtitleTrack]

    var id: String { key }
}

struct PlaybackRequest {
    var title: String
    var artwork: URL?
    var items: [PlayableItem]
    var startIndex: Int
    /// The source's title, so My List can offer it under Continue Watching.
    var saved: SavedTitle?
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
    /// Where playback is and how long the video runs, in seconds.
    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0
    private(set) var isPaused = false
    /// The parts of the playing file that are downloaded, as fractions.
    private(set) var downloaded: [ClosedRange<Double>] = []
    var volume: Float = 1 {
        didSet { player?.volume = volume }
    }
    /// The torrent file playing, whose download the seek bar shows.
    private var currentFile: TorrentFile?
    private var pictureInPicture: AVPictureInPictureController?
    /// The Chromecast playing this instead of the Mac, if any.
    private(set) var castDevice: CastDevice?
    private(set) var castStatus: CastStatus?
    private var cast: CastSession?
    /// This Mac's address on the Chromecast's network, once connected.
    private var castAddress: String?
    /// The subtitle tracks handed to the Chromecast with the video, by their
    /// IDs there: it switches between these without reloading.
    private var castTrackIDs: [String: Int] = [:]

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
    private var lastSaved = Date.distantPast
    private var pendingSeek: Double?
    private var stopped = false

    init(request: PlaybackRequest, app: AppModel) {
        self.request = request
        self.index = request.startIndex
        self.app = app
    }

    var current: PlayableItem { request.items[index] }
    var hasNext: Bool { index + 1 < request.items.count }
    var hasPrevious: Bool { index > 0 }
    var subtitleTracks: [SubtitleTrack] { current.subtitles + torrentSubtitles + downloadedSubtitles + localSubtitles }
    /// Subtitle files in the torrent of a title from a source, found once its
    /// file list arrives.
    private(set) var torrentSubtitles: [SubtitleTrack] = []
    /// Subtitles picked from OpenSubtitles for this item.
    private(set) var downloadedSubtitles: [SubtitleTrack] = []
    var subtitleSearchVisible = false
    private var hashState = FileHash.unknown

    private enum FileHash {
        case unknown
        case working(Task<Void, Never>)
        case done(String?)
    }

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
        cast?.stop()
        cast = nil
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
        torrentSubtitles = []
        cueText = nil
        activeSubtitleID = nil
        // Subtitles downloaded for this video before, the last one showing.
        let picked = OpenSubtitles.picked(for: current.key)
        downloadedSubtitles = picked.downloads.compactMap(OpenSubtitles.track)
        if let showing = picked.showing { selectSubtitle(OpenSubtitles.trackID(showing)) }
        pendingSeek = app?.library.resumePosition(current.key)
        prepareTask = Task { [weak self] in await self?.prepare() }
    }

    private func prepare() async {
        guard let app else { return }
        let item = current
        switch item.media {
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
                torrentSubtitles = info.contentFiles.filter(\.isSubtitle)
                    .sorted { $0.displayPath.localizedStandardCompare($1.displayPath) == .orderedAscending }
                    .map { SubtitleTrack(id: "bt:\($0.index)", label: $0.name, source: .torrent(fileIndex: $0.index)) }
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
        currentFile = file
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

    private func play(_ url: URL) {
        streamURL = url
        if cast != nil {
            castLoad(url)
            return
        }
        let item = AVPlayerItem(url: url)
        item.preferredForwardBufferDuration = 20
        let p = player ?? AVPlayer()
        p.replaceCurrentItem(with: item)
        p.volume = volume
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
            if fileURL != nil {
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
        isPaused = p.timeControlStatus == .paused
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
        if seconds.isFinite { currentTime = seconds }
        if let d = player?.currentItem?.duration.seconds, d.isFinite, d > 0, d != duration { duration = d }
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

    // MARK: - Torrent status

    private func pollStats() async {
        guard let s = session, !stopped else { return }
        let st = await s.stats()
        guard s === session else { return }
        stats = st
        if let file = currentFile {
            let ranges = await s.downloadedRanges(of: file.index)
            if s === session, ranges != downloaded { downloaded = ranges }
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

    // MARK: - Controls

    func togglePlay() {
        if cast != nil { return castTogglePlay() }
        guard let player else { return }
        if player.timeControlStatus == .paused { player.play() } else { player.pause() }
    }

    func seek(to seconds: Double) {
        let target = max(0, duration > 0 ? min(seconds, duration - 1) : seconds)
        currentTime = target
        if cast != nil { return castSeek(to: target) }
        player?.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func skip(_ seconds: Double) {
        seek(to: currentTime + seconds)
    }

    /// Seconds downloaded ahead of the play position, or nil before there's
    /// a file to measure. The whole rest of the file counts once it's all here.
    var bufferedAhead: Double? {
        guard duration > 0, currentFile != nil else { return nil }
        let here = currentTime / duration
        guard let run = downloaded.first(where: { $0.lowerBound <= here + 0.001 && $0.upperBound >= here }) else { return 0 }
        return max(0, (run.upperBound - here) * duration)
    }

    var isFullyDownloaded: Bool {
        downloaded.count == 1 && downloaded[0].lowerBound <= 0.0001 && downloaded[0].upperBound >= 0.9999
    }

    /// The video's layer, for picture in picture.
    func attach(_ layer: AVPlayerLayer) {
        guard AVPictureInPictureController.isPictureInPictureSupported(), pictureInPicture?.playerLayer !== layer else { return }
        pictureInPicture = AVPictureInPictureController(playerLayer: layer)
    }

    var canPictureInPicture: Bool { pictureInPicture != nil }

    func togglePictureInPicture() {
        guard let pip = pictureInPicture else { return }
        if pip.isPictureInPictureActive { pip.stopPictureInPicture() } else { pip.startPictureInPicture() }
    }

    // MARK: - Chromecast

    var isCasting: Bool { cast != nil }

    /// Moves playback to `device`, from where the Mac is.
    func startCasting(to device: CastDevice) {
        guard castDevice?.id != device.id else { return }
        if cast != nil { endCasting(nil, resumeHere: false) }
        let position = player?.currentTime().seconds
        player?.pause()
        let session = CastSession(device: device)
        cast = session
        castDevice = device
        castStatus = CastStatus()
        session.onStatus = { [weak self] status in
            MainActor.assumeIsolated { self?.castStatusChanged(status, from: session) }
        }
        #if DEBUG
        session.trace = { line in
            print("[cast] \(line)")
            fflush(stdout)
        }
        #endif
        Task { [weak self] in
            do {
                let address = try await session.connect()
                guard let self, self.cast === session else { return }
                self.castAddress = address
                if let url = self.streamURL {
                    if self.hasStarted, let position, position > 1 { self.pendingSeek = position }
                    self.castLoad(url)
                }
            } catch {
                guard let self, self.cast === session else { return }
                self.endCasting(error.localizedDescription)
            }
        }
    }

    func stopCasting() {
        endCasting(nil)
    }

    func castTogglePlay() {
        if castStatus?.state == .playing { cast?.pause() } else { cast?.play() }
    }

    func castSeek(to seconds: Double) {
        cast?.seek(to: seconds)
    }

    /// Hands the device a URL it can reach for the stream this Mac serves,
    /// and the subtitles.
    private func castLoad(_ url: URL) {
        guard let cast, let address = castAddress, let app else { return }
        let start = pendingSeek ?? 0
        pendingSeek = nil
        let media = { (lan: URL) in
            var m = CastMedia(url: lan, contentType: Self.castContentType(url), title: self.displayTitle,
                              subtitle: self.displaySubtitle, imageURL: self.request.artwork, startTime: start)
            m.textTracks = self.castTextTracks(host: address)
            m.activeTextTrack = self.activeSubtitleID.flatMap { self.castTrackIDs[$0] }
            m.textScale = UserDefaults.standard.double(forKey: Pref.subtitleSize) / 26
            return m
        }
        Task {
            do {
                try await app.engine.server.startLAN()
            } catch {
                endCasting("Couldn't share the stream on the network: \(error.localizedDescription)")
                return
            }
            // A remuxed stream has a version for Chromecasts, with AAC audio
            // when its own (AC-3 and the like) needs a TV that decodes it.
            let castURL = self.fileURL != nil ? url.deletingLastPathComponent().appendingPathComponent("cast/index.m3u8") : url
            guard self.cast === cast, let lan = app.engine.server.lanURL(for: castURL, host: address) else { return }
            cast.load(media(lan))
        }
    }

    /// Serves this item's subtitles to the device as WebVTT, and notes the
    /// ID each has there.
    private func castTextTracks(host: String) -> [CastTextTrack] {
        castTrackIDs = [:]
        let tracks = subtitleTracks
        guard let app, let session, !tracks.isEmpty else { return [] }
        let byFile = Dictionary(uniqueKeysWithValues: tracks.enumerated().map { ("\($0.offset + 1).vtt", $0.element) })
        let first = app.engine.server.url(for: session, generated: "subtitles", name: "1.vtt") { path in
            guard let track = byFile[(path as NSString).lastPathComponent] else { return nil }
            let cues = SubtitleParser.parse(try await Self.data(of: track, in: session))
            return ("text/vtt", Data(SubtitleParser.webVTT(cues).utf8))
        }
        return tracks.enumerated().compactMap { i, track in
            let local = first.deletingLastPathComponent().appendingPathComponent("\(i + 1).vtt")
            guard let lan = app.engine.server.lanURL(for: local, host: host) else { return nil }
            castTrackIDs[track.id] = i + 1
            return CastTextTrack(id: i + 1, url: lan, name: track.label, language: track.language.map(OpenSubtitles.languageTag) ?? "und")
        }
    }

    /// The picked subtitles on the device: a track it was handed switches
    /// there, and a new one reloads the video where it is.
    private func castShowSubtitle(_ id: String?) {
        guard let cast, castAddress != nil, let url = streamURL else { return }
        if let id, castTrackIDs[id] == nil {
            if let position = castStatus?.currentTime, position > 1 { pendingSeek = position }
            castLoad(url)
        } else {
            cast.showTextTrack(id.flatMap { castTrackIDs[$0] })
        }
    }

    static func castContentType(_ url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "m3u8": return "application/x-mpegurl"
        case "webm": return "video/webm"
        default: return "video/mp4"
        }
    }

    private func castStatusChanged(_ status: CastStatus, from session: CastSession) {
        guard session === cast else { return }
        castStatus = status
        // The seek bar and what's buffered follow the device.
        currentTime = status.currentTime
        if let d = status.duration { duration = d }
        switch status.state {
        case .connecting, .loading:
            if !hasStarted { statusText = "Starting on \(castDevice?.name ?? "the Chromecast")" }
        case .playing, .paused:
            hasStarted = true
            isBuffering = false
            if phase == .preparing { phase = .playing }
        case .buffering:
            isBuffering = hasStarted
        case .finished:
            saveProgress(finished: true)
            if hasNext && Pref.autoplay { playNext() }
        case .failed:
            endCasting("\(castDevice?.name ?? "The Chromecast") couldn't play this video's format")
        case .ended:
            endCasting("Casting to \(castDevice?.name ?? "the Chromecast") stopped")
        case .idle:
            break
        }
        if Date().timeIntervalSince(lastSaved) > 5 { saveProgress() }
    }

    /// Back to the Mac, where the device left off.
    private func endCasting(_ message: String?, resumeHere: Bool = true) {
        let position = castStatus.map(\.currentTime)
        saveProgress()
        cast?.stop()
        cast = nil
        castDevice = nil
        castStatus = nil
        castAddress = nil
        castTrackIDs = [:]
        if let message { show(message) }
        guard resumeHere, !stopped else { return }
        if let p = player, p.currentItem != nil {
            if let position, position > 1 { p.seek(to: CMTime(seconds: position, preferredTimescale: 600)) }
            p.play()
        } else if let url = streamURL, phase != .needsExternalPlayer {
            if let position, position > 1 { pendingSeek = position }
            play(url)
        }
    }

    // MARK: - Subtitles

    func selectSubtitle(_ id: String?) {
        activeSubtitleID = id
        rememberShowing(id)
        cues = []
        cueText = nil
        castShowSubtitle(id)
        guard let id, let track = subtitleTracks.first(where: { $0.id == id }) else { return }
        let session = self.session
        Task { [weak self] in
            do {
                let parsed = SubtitleParser.parse(try await Self.data(of: track, in: session))
                guard let self, self.activeSubtitleID == id else { return }
                self.cues = parsed
                if parsed.isEmpty { self.show("No subtitles found in \(track.label)") }
            } catch {
                self?.show("Could not load subtitles: \(error.localizedDescription)")
            }
        }
    }

    /// What to ask OpenSubtitles for: the title's IMDb ID when its source
    /// gives one, otherwise the video's file name. Nil until there's either.
    var subtitleSearch: OpenSubtitles.Query? {
        var q = OpenSubtitles.Query(fileName: currentFile.map { ($0.name as NSString).deletingPathExtension })
        if let saved = request.saved {
            switch (saved.type, current.media) {
            case (.movies, _):
                q.imdbID = saved.id
            case (.shows, .link(_, let season?, let episode?)):
                q.imdbID = saved.id
                q.season = season
                q.episode = episode
            default:
                break
            }
        }
        return q.imdbID != nil || q.fileName != nil ? q : nil
    }

    /// The OpenSubtitles hash of the playing torrent file, if it can be had
    /// within `seconds`. It needs the file's first and last 64 KB, which are
    /// fetched first when they aren't here yet.
    func fileHash(within seconds: Double) async -> String? {
        if case .unknown = hashState, let s = session, let file = currentFile, OpenSubtitles.canHash(length: file.length) {
            let source = TorrentByteSource(session: s, file: file)
            let stream = UUID()
            hashState = .working(Task { [weak self] in
                let hash = try? await OpenSubtitles.hash(length: file.length) {
                    try await source.read(at: $0, count: $1, stream: stream)
                }
                source.finish(stream: stream)
                guard let self, !Task.isCancelled, self.session === s, self.currentFile == file else { return }
                self.hashState = .done(hash)
            })
        }
        let deadline = Date().addingTimeInterval(seconds)
        while case .working = hashState, Date() < deadline {
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        if case .done(let hash) = hashState { return hash }
        return nil
    }

    /// Shows a subtitle downloaded from OpenSubtitles, and keeps it in the
    /// menu for this video, now and when it plays again.
    func useDownloadedSubtitle(_ subtitle: OpenSubtitles.Subtitle, at url: URL) {
        var picked = OpenSubtitles.picked(for: current.key)
        let download = OpenSubtitles.Picked.Download(fileID: subtitle.fileID, label: OpenSubtitles.label(subtitle), language: subtitle.language)
        if !picked.downloads.contains(download) { picked.downloads.append(download) }
        OpenSubtitles.remember(picked, for: current.key)
        let track = SubtitleTrack(id: OpenSubtitles.trackID(subtitle.fileID), label: download.label, source: .local(url),
                                  language: subtitle.language)
        if !downloadedSubtitles.contains(track) { downloadedSubtitles.append(track) }
        selectSubtitle(track.id)
    }

    /// Notes whether a downloaded subtitle is showing, for when this video
    /// plays again.
    private func rememberShowing(_ id: String?) {
        var picked = OpenSubtitles.picked(for: current.key)
        guard !picked.downloads.isEmpty else { return }
        picked.showing = picked.downloads.first { OpenSubtitles.trackID($0.fileID) == id }?.fileID
        OpenSubtitles.remember(picked, for: current.key)
    }

    /// A subtitle track's file, from disk or out of the torrent.
    nonisolated private static func data(of track: SubtitleTrack, in session: TorrentSession?) async throws -> Data {
        switch track.source {
        case .local(let url): return try Data(contentsOf: url)
        case .torrent(let fileIndex):
            guard let session else { throw TorrentError.noSuchFile }
            return try await session.readFile(fileIndex: fileIndex)
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
        guard hasStarted else { return }
        let duration: Double
        let now: Double
        if cast != nil, let status = castStatus {
            guard let d = status.duration else { return }
            duration = d
            now = status.currentTime
        } else {
            guard let p = player, let item = p.currentItem else { return }
            duration = item.duration.seconds
            now = p.currentTime().seconds
        }
        guard duration.isFinite, duration > 0 else { return }
        let position = finished ? duration : now
        app?.library.record(current.key, position: position, duration: duration, title: displayTitle, saved: request.saved)
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
        currentFile = nil
        downloaded = []
        currentTime = 0
        duration = 0
        fileURL = nil
        remuxSummary = nil
        externalReason = nil
        if case .working(let task) = hashState { task.cancel() }
        hashState = .unknown
    }
}
