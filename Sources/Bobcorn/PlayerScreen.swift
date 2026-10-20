import AVKit
import CastKit
import SwiftUI
import TorrentKit

struct PlayerScreen: View {
    @Environment(AppModel.self) private var model
    let controller: PlaybackController
    @AppStorage(Pref.subtitleSize) private var subtitleSize = 26.0
    @State private var chromeVisible = true
    @State private var hideTask: Task<Void, Never>?
    @FocusState private var keyboardFocus: Bool

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let player = controller.player, !controller.isCasting {
                VideoSurface(player: player, controller: controller)
                    .ignoresSafeArea()
                    .onTapGesture(count: 2) { NSApp.keyWindow?.toggleFullScreen(nil) }
            }

            if let text = controller.cueText {
                VStack {
                    Spacer()
                    Text(text)
                        .font(.system(size: subtitleSize, weight: .semibold))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white)
                        .shadow(color: .black, radius: 2)
                        .shadow(color: .black, radius: 4)
                        .padding(.horizontal, 60)
                        .padding(.bottom, chromeVisible ? 96 : 48)
                }
                .allowsHitTesting(false)
            }

            switch controller.phase {
            case _ where controller.isCasting:
                CastPanel(controller: controller)
            case .preparing:
                LoadingPanel(controller: controller)
            case .needsExternalPlayer, .external:
                ExternalPanel(controller: controller)
            case .failed(let message):
                FailurePanel(controller: controller, message: message)
            case .playing:
                if controller.isBuffering, let stats = controller.stats {
                    BufferingBadge(stats: stats)
                }
            }

            VStack {
                topBar
                    .opacity(chromeVisible || controller.phase != .playing || controller.isCasting ? 1 : 0)
                Spacer()
                if controller.phase == .playing && !controller.isCasting {
                    ControlBar(controller: controller)
                        .opacity(chromeVisible || controller.isPaused ? 1 : 0)
                }
            }

            if let notice = controller.notice {
                VStack {
                    Spacer()
                    Text(notice)
                        .font(.system(size: 13, weight: .medium))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 9)
                        .background(Capsule().fill(.black.opacity(0.75)))
                        .padding(.bottom, 110)
                }
                .transition(.opacity)
                .allowsHitTesting(false)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: chromeVisible)
        .animation(.easeInOut(duration: 0.2), value: controller.notice)
        .onContinuousHover { phase in
            if case .active = phase { poke() }
        }
        .onAppear {
            poke()
            model.castDevices.start()
        }
        .onDisappear { model.castDevices.stop() }
        .onExitCommand { model.closePlayback() }
        .focusable()
        .focusEffectDisabled()
        .focused($keyboardFocus)
        .onAppear { keyboardFocus = true }
        .onKeyPress(.space) { controller.togglePlay(); poke(); return .handled }
        .onKeyPress(.leftArrow) { controller.skip(-10); poke(); return .handled }
        .onKeyPress(.rightArrow) { controller.skip(10); poke(); return .handled }
        .onKeyPress("f") { NSApp.keyWindow?.toggleFullScreen(nil); return .handled }
        .sheet(isPresented: Bindable(controller).subtitleSearchVisible) {
            SubtitleSearchSheet(controller: controller)
        }
    }

    private var topBar: some View {
        HStack(spacing: 14) {
            Button {
                model.closePlayback()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 15, weight: .bold))
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(.black.opacity(0.5)))
            }
            .buttonStyle(.plain)
            .help("Back (Esc)")

            VStack(alignment: .leading, spacing: 1) {
                Text(controller.displayTitle)
                    .font(.system(size: 15, weight: .bold))
                    .lineLimit(1)
                if let sub = controller.displaySubtitle {
                    Text(sub).font(.system(size: 12)).foregroundStyle(Theme.secondary).lineLimit(1)
                }
            }

            Spacer()

            if controller.viaTorrent, let stats = controller.stats {
                StatsChip(stats: stats)
            }

            if controller.hasPrevious {
                Button { controller.playPrevious() } label: { Image(systemName: "backward.end.fill") }
                    .buttonStyle(ChromeButtonStyle())
                    .help("Previous")
            }
            if controller.hasNext {
                Button { controller.playNext() } label: {
                    Label("Next", systemImage: "forward.end.fill")
                }
                .buttonStyle(ChromeButtonStyle())
                .help("Next episode")
            }

            if controller.phase == .playing || controller.phase == .preparing {
                CastMenu(controller: controller)
            }

            Menu {
                Button {
                    controller.selectSubtitle(nil)
                } label: {
                    if controller.activeSubtitleID == nil { Label("Off", systemImage: "checkmark") } else { Text("Off") }
                }
                if !controller.subtitleTracks.isEmpty { Divider() }
                ForEach(controller.subtitleTracks) { track in
                    Button {
                        controller.selectSubtitle(track.id)
                    } label: {
                        if controller.activeSubtitleID == track.id {
                            Label(track.label, systemImage: "checkmark")
                        } else {
                            Text(track.label)
                        }
                    }
                }
                Divider()
                Button("Search OpenSubtitles…") { controller.subtitleSearchVisible = true }
                    .disabled(controller.subtitleSearch == nil)
                Button("Load from File…") { controller.chooseSubtitleFile() }
            } label: {
                Image(systemName: controller.activeSubtitleID == nil ? "captions.bubble" : "captions.bubble.fill")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Subtitles")

            if controller.streamURL != nil, !ExternalPlayer.installed.isEmpty {
                Menu {
                    ForEach(ExternalPlayer.installed) { p in
                        Button("Open in \(p.name)") { controller.openExternally(p) }
                    }
                    Divider()
                    Button("Copy Stream URL") { controller.copyStreamURL() }
                } label: {
                    Image(systemName: "rectangle.portrait.and.arrow.right")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Play in another app")
            }
        }
        .foregroundStyle(.white)
        .padding(.leading, 86)
        .padding(.trailing, 20)
        .padding(.top, 10)
        .padding(.bottom, 26)
        .background(
            LinearGradient(colors: [.black.opacity(0.75), .clear], startPoint: .top, endPoint: .bottom)
                .allowsHitTesting(false)
        )
        .background(WindowDragArea())
    }

    private func poke() {
        chromeVisible = true
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(nanoseconds: 2_800_000_000)
            guard !Task.isCancelled else { return }
            chromeVisible = false
        }
    }
}

private struct ChromeButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Capsule().fill(.white.opacity(configuration.isPressed ? 0.25 : 0.14)))
    }
}

/// AVKit's player view, with its own floating transport controls.
struct VideoSurface: NSViewRepresentable {
    let player: AVPlayer
    let controller: PlaybackController

    func makeNSView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView()
        view.playerLayer.player = player
        controller.attach(view.playerLayer)
        return view
    }

    func updateNSView(_ view: PlayerLayerView, context: Context) {
        if view.playerLayer.player !== player { view.playerLayer.player = player }
    }
}

/// The video alone; Bobcorn draws its own controls over it.
final class PlayerLayerView: NSView {
    let playerLayer = AVPlayerLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor.black.cgColor
        playerLayer.videoGravity = .resizeAspect
        layer?.addSublayer(playerLayer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        CATransaction.commit()
    }
}

// MARK: - Controls

/// Play, seek and volume, over the bottom of the video. The seek bar shows
/// what's downloaded as well as what's played.
private struct ControlBar: View {
    @Bindable var controller: PlaybackController

    var body: some View {
        VStack(spacing: 8) {
            Scrubber(controller: controller)
            HStack(spacing: 18) {
                Button { controller.togglePlay() } label: {
                    Image(systemName: controller.isPaused ? "play.fill" : "pause.fill").font(.system(size: 18)).frame(width: 22)
                }
                .help(controller.isPaused ? "Play (Space)" : "Pause (Space)")
                Button { controller.skip(-10) } label: { Image(systemName: "gobackward.10") }
                    .help("Back 10 seconds (←)")
                Button { controller.skip(10) } label: { Image(systemName: "goforward.10") }
                    .help("Forward 10 seconds (→)")
                Text("\(formatTime(controller.currentTime)) / \(formatTime(controller.duration))")
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(Theme.secondary)
                Spacer()
                bufferLabel
                HStack(spacing: 6) {
                    Button { controller.volume = controller.volume > 0 ? 0 : 1 } label: {
                        Image(systemName: controller.volume == 0 ? "speaker.slash.fill" : controller.volume < 0.5 ? "speaker.wave.1.fill" : "speaker.wave.2.fill")
                            .frame(width: 20)
                    }
                    .help(controller.volume == 0 ? "Unmute" : "Mute")
                    Slider(value: $controller.volume, in: 0...1)
                        .controlSize(.mini)
                        .frame(width: 80)
                        .tint(.white)
                }
                AirPlayButton()
                    .frame(width: 22, height: 22)
                    .help("AirPlay")
                if controller.canPictureInPicture {
                    Button { controller.togglePictureInPicture() } label: { Image(systemName: "pip.enter") }
                        .help("Picture in Picture")
                }
                Button { NSApp.keyWindow?.toggleFullScreen(nil) } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                }
                .help("Full Screen (F)")
            }
            .buttonStyle(.plain)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.white)
        }
        .padding(.horizontal, 24)
        .padding(.top, 34)
        .padding(.bottom, 16)
        .background(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black.opacity(0.6), location: 0.3),
                                           .init(color: .black.opacity(0.85), location: 1)], startPoint: .top, endPoint: .bottom))
    }

    @ViewBuilder
    private var bufferLabel: some View {
        if controller.isFullyDownloaded {
            Label("Downloaded", systemImage: "checkmark.circle.fill")
                .help("The whole video is on this Mac")
        } else if let ahead = controller.bufferedAhead {
            Label(ahead >= 1 ? "\(formatTime(ahead)) buffered" : "Buffering", systemImage: "arrow.down.circle")
                .help("Downloaded ahead of where you are\(controller.isPaused ? "; it keeps downloading while paused" : "")")
        }
        EmptyView()
    }
}

/// Played, downloaded and not yet here, along the length of the video.
private struct Scrubber: View {
    let controller: PlaybackController
    @State private var dragging: Double?
    @State private var hover: Double?

    var body: some View {
        GeometryReader { geo in
            let width = max(1, geo.size.width)
            let duration = controller.duration
            let played = duration > 0 ? min(1, (dragging ?? controller.currentTime / duration)) : 0
            let tall = hover != nil || dragging != nil
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.18))
                ForEach(Array(controller.downloaded.enumerated()), id: \.offset) { _, run in
                    Rectangle()
                        .fill(Color.white.opacity(0.42))
                        .frame(width: max(1, width * (run.upperBound - run.lowerBound)))
                        .offset(x: width * run.lowerBound)
                }
                Capsule().fill(Theme.accent).frame(width: width * played)
            }
            .frame(height: tall ? 7 : 4)
            .clipShape(Capsule())
            .frame(maxHeight: .infinity)
            .overlay(alignment: .leading) {
                Circle()
                    .fill(.white)
                    .frame(width: 13, height: 13)
                    .shadow(radius: 2)
                    .offset(x: width * played - 6.5)
                    .opacity(tall ? 1 : 0)
            }
            .overlay(alignment: .topLeading) {
                if let at = dragging ?? hover, duration > 0 {
                    Text(formatTime(at * duration))
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(.black.opacity(0.8)))
                        .fixedSize()
                        .offset(x: min(max(0, width * at - 24), width - 52), y: -22)
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { dragging = min(1, max(0, $0.location.x / width)) }
                .onEnded { _ in
                    if let at = dragging, duration > 0 { controller.seek(to: at * duration) }
                    dragging = nil
                })
            .onContinuousHover { phase in
                if case .active(let p) = phase { hover = min(1, max(0, p.x / width)) } else { hover = nil }
            }
            .animation(.easeOut(duration: 0.12), value: tall)
        }
        .frame(height: 16)
    }
}

/// The system's AirPlay menu.
private struct AirPlayButton: NSViewRepresentable {
    func makeNSView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.isRoutePickerButtonBordered = false
        picker.setRoutePickerButtonColor(.white, for: .normal)
        return picker
    }

    func updateNSView(_ view: AVRoutePickerView, context: Context) {}
}

private struct StatsChip: View {
    let stats: TorrentStats

    var body: some View {
        HStack(spacing: 10) {
            Label(formatRate(stats.downloadRate), systemImage: "arrow.down")
            Label("\(stats.connectedPeers)", systemImage: "person.2.fill")
                .help("\(stats.connectedPeers) peers connected, \(stats.activeWebSeeds) web seeds")
            if stats.selectedProgress > 0 {
                Text("\(Int(stats.selectedProgress * 100))%")
            }
        }
        .labelStyle(CompactLabelStyle())
        .font(.system(size: 11, weight: .semibold, design: .rounded))
        .foregroundStyle(Theme.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Capsule().fill(.black.opacity(0.45)))
    }
}

private struct CompactLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.icon.font(.system(size: 9, weight: .bold))
            configuration.title
        }
    }
}

private struct BufferingBadge: View {
    let stats: TorrentStats

    var body: some View {
        VStack(spacing: 8) {
            ProgressView().controlSize(.large)
            Text("Buffering · \(formatRate(stats.downloadRate))")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.secondary)
        }
        .padding(20)
        .background(RoundedRectangle(cornerRadius: 14).fill(.black.opacity(0.5)))
        .allowsHitTesting(false)
    }
}

/// Shown until the first frame plays: artwork, title and what the swarm is doing.
private struct LoadingPanel: View {
    @Environment(AppModel.self) private var model
    let controller: PlaybackController

    var body: some View {
        ZStack {
            if let art = controller.request.artwork {
                BlurredBackdrop(url: art)
                    .opacity(0.4)
                    .ignoresSafeArea()
            }
            Color.black.opacity(0.45).ignoresSafeArea()

            VStack(spacing: 18) {
                Text(controller.displayTitle)
                    .font(.system(size: 28, weight: .heavy))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                if let sub = controller.displaySubtitle {
                    Text(sub).foregroundStyle(Theme.secondary)
                }

                ProgressView()
                    .progressViewStyle(.linear)
                    .tint(Theme.accent)
                    .frame(width: 320)

                Text(controller.statusText + "…")
                    .font(.system(size: 14, weight: .semibold))

                if let s = controller.stats {
                    HStack(spacing: 22) {
                        Stat(value: formatRate(s.downloadRate), label: "Download")
                        Stat(value: "\(s.connectedPeers)", label: "Peers")
                        if s.activeWebSeeds > 0 { Stat(value: "\(s.activeWebSeeds)", label: "Web seeds") }
                        if let seeders = s.seeders { Stat(value: "\(seeders)", label: "Seeders") }
                        Stat(value: formatSize(s.bufferedAhead), label: "Buffered")
                    }
                    .padding(.top, 6)
                }

                Button("Cancel") { model.closePlayback() }
                    .buttonStyle(AccentButtonStyle(prominent: false))
                    .padding(.top, 10)
            }
            .padding(40)
        }
        .transition(.opacity)
    }
}

private struct Stat: View {
    let value: String
    let label: String

    var body: some View {
        VStack(spacing: 3) {
            Text(value).font(.system(size: 16, weight: .bold, design: .rounded))
            Text(label.uppercased()).font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.tertiary)
        }
        .frame(minWidth: 64)
    }
}

private struct ExternalPanel: View {
    @Environment(AppModel.self) private var model
    let controller: PlaybackController

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "rectangle.portrait.and.arrow.right")
                .font(.system(size: 40))
                .foregroundStyle(Theme.accent)
            if case .external(let name) = controller.phase {
                Text("Playing in \(name)").font(.system(size: 22, weight: .bold))
                Text("Bobcorn keeps downloading while \(name) plays. Leave this screen open until you're done.")
                    .foregroundStyle(Theme.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            } else {
                Text("This video needs another player").font(.system(size: 22, weight: .bold))
                let ext = controller.streamURL?.pathExtension.uppercased() ?? "This"
                Text(controller.externalReason.map { "Bobcorn can't play this \(ext) file itself: \($0). Open the stream in a player that supports it." }
                     ?? "\(ext) files can't be played by macOS itself. Open the stream in a player that supports them.")
                    .foregroundStyle(Theme.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }

            if let s = controller.stats {
                HStack(spacing: 22) {
                    Stat(value: formatRate(s.downloadRate), label: "Download")
                    Stat(value: "\(s.connectedPeers)", label: "Peers")
                    Stat(value: "\(Int(s.selectedProgress * 100))%", label: "Downloaded")
                }
            }

            HStack(spacing: 12) {
                ForEach(ExternalPlayer.installed) { p in
                    Button("Open in \(p.name)") { controller.openExternally(p) }
                        .buttonStyle(AccentButtonStyle())
                }
                Button("Copy Stream URL") { controller.copyStreamURL() }
                    .buttonStyle(AccentButtonStyle(prominent: ExternalPlayer.installed.isEmpty))
            }
            if ExternalPlayer.installed.isEmpty {
                Text("Install IINA or VLC to play it here, or paste the stream URL into any player.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.tertiary)
            }
            Button("Stop") { model.closePlayback() }
                .buttonStyle(AccentButtonStyle(prominent: false))
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.85))
    }
}

private struct FailurePanel: View {
    @Environment(AppModel.self) private var model
    let controller: PlaybackController
    let message: String

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 38))
                .foregroundStyle(Theme.gold)
            Text("Playback failed").font(.system(size: 22, weight: .bold))
            Text(message)
                .foregroundStyle(Theme.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
            HStack(spacing: 12) {
                if controller.streamURL != nil {
                    ForEach(ExternalPlayer.installed) { p in
                        Button("Open in \(p.name)") { controller.openExternally(p) }
                            .buttonStyle(AccentButtonStyle())
                    }
                }
                Button("Close") { model.closePlayback() }
                    .buttonStyle(AccentButtonStyle(prominent: false))
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.85))
    }
}

// MARK: - Chromecast

private struct CastMenu: View {
    @Environment(AppModel.self) private var model
    let controller: PlaybackController

    var body: some View {
        Menu {
            let devices = model.castDevices.devices
            if devices.isEmpty {
                Text("Looking for Chromecasts…")
            }
            ForEach(devices) { device in
                Button {
                    controller.startCasting(to: device)
                } label: {
                    if controller.castDevice?.id == device.id {
                        Label(device.name, systemImage: "checkmark")
                    } else {
                        Text(device.name)
                    }
                }
            }
            if controller.isCasting {
                Divider()
                Button("Stop Casting") { controller.stopCasting() }
            }
        } label: {
            Image(systemName: controller.isCasting ? "tv.fill" : "tv")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Play on a Chromecast")
    }
}

/// While a Chromecast plays: what's on, and its controls.
private struct CastPanel: View {
    let controller: PlaybackController
    @State private var scrub: Double?

    var body: some View {
        let status = controller.castStatus ?? CastStatus()
        let name = controller.castDevice?.name ?? "Chromecast"
        ZStack {
            if let art = controller.request.artwork {
                BlurredBackdrop(url: art)
                    .opacity(0.35)
                    .ignoresSafeArea()
            }
            Color.black.opacity(0.55).ignoresSafeArea()

            VStack(spacing: 18) {
                Image(systemName: "tv.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(Theme.accent)
                Text(heading(status.state, name))
                    .font(.system(size: 22, weight: .bold))
                VStack(spacing: 4) {
                    Text(controller.displayTitle)
                        .font(.system(size: 15, weight: .semibold))
                    if let sub = controller.displaySubtitle {
                        Text(sub).font(.system(size: 13)).foregroundStyle(Theme.secondary)
                    }
                }
                .multilineTextAlignment(.center)

                if let duration = status.duration, duration > 0 {
                    VStack(spacing: 6) {
                        Slider(value: Binding(get: { min(duration, scrub ?? status.currentTime) }, set: { scrub = $0 }),
                               in: 0...duration) { editing in
                            if !editing, let target = scrub {
                                controller.castSeek(to: target)
                                scrub = nil
                            }
                        }
                        .tint(Theme.accent)
                        HStack {
                            Text(formatTime(scrub ?? status.currentTime))
                            Spacer()
                            Text(formatTime(duration))
                        }
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Theme.secondary)
                    }
                    .frame(width: 460)
                } else {
                    ProgressView()
                        .progressViewStyle(.linear)
                        .tint(Theme.accent)
                        .frame(width: 320)
                }

                HStack(spacing: 26) {
                    Button { controller.castSeek(to: status.currentTime - 10) } label: {
                        Image(systemName: "gobackward.10").font(.system(size: 22))
                    }
                    Button { controller.castTogglePlay() } label: {
                        Image(systemName: status.state == .playing ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 46))
                            .foregroundStyle(.white, Theme.accent)
                    }
                    Button { controller.castSeek(to: status.currentTime + 10) } label: {
                        Image(systemName: "goforward.10").font(.system(size: 22))
                    }
                }
                .buttonStyle(.plain)
                .disabled(status.duration == nil)

                HStack(spacing: 12) {
                    if controller.hasNext {
                        Button { controller.playNext() } label: {
                            Label("Next Episode", systemImage: "forward.end.fill")
                        }
                        .buttonStyle(AccentButtonStyle(prominent: false))
                    }
                    Button("Stop Casting") { controller.stopCasting() }
                        .buttonStyle(AccentButtonStyle(prominent: false))
                }
                .padding(.top, 4)

                if let s = controller.stats {
                    Text("\(formatRate(s.downloadRate)) · \(s.connectedPeers) peers · \(formatSize(s.bufferedAhead)) buffered")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.tertiary)
                }
            }
            .padding(40)
        }
    }

    private func heading(_ state: CastStatus.State, _ name: String) -> String {
        switch state {
        case .connecting: return "Connecting to \(name)"
        case .loading, .idle: return "Starting on \(name)"
        case .buffering: return "Buffering on \(name)"
        case .paused: return "Paused on \(name)"
        case .finished: return "Finished on \(name)"
        case .playing, .ended, .failed: return "Playing on \(name)"
        }
    }
}
