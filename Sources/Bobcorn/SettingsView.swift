import SwiftUI
import TorrentKit

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(Pref.subtitleSize) private var subtitleSize = 26.0
    @AppStorage(Pref.subtitleLanguage) private var subtitleLanguage = "ar"
    @AppStorage(Pref.autoplayNext) private var autoplayNext = true
    @AppStorage(Pref.maxPeers) private var maxPeers = 60
    @AppStorage(Pref.enableDHT) private var enableDHT = true
    @AppStorage(Pref.publicTrackers) private var publicTrackers = true
    @AppStorage(Pref.clearCacheOnQuit) private var clearCacheOnQuit = false
    @State private var cacheSize: Int64?
    @State private var movingCache = false
    @AppStorage(Pref.cacheFolder) private var cacheFolder = ""

    var body: some View {
        TabView {
            Form {
                Toggle("Play the next episode automatically", isOn: $autoplayNext)

                LabeledContent("Subtitle size") {
                    HStack {
                        Slider(value: $subtitleSize, in: 16...44, step: 2)
                            .frame(width: 180)
                        Text("\(Int(subtitleSize)) pt").monospacedDigit().frame(width: 44, alignment: .trailing)
                    }
                }

                Picker("Subtitle language", selection: $subtitleLanguage) {
                    ForEach(OpenSubtitles.languages, id: \.code) { Text($0.name).tag($0.code) }
                }
                .help("The language OpenSubtitles is searched in")

                LabeledContent("External players") {
                    let installed = ExternalPlayer.installed
                    Text(installed.isEmpty ? "None found (IINA or VLC play AVI, and MKVs with DTS audio)" : installed.map(\.name).joined(separator: ", "))
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("Playback", systemImage: "play.rectangle") }

            Form {
                LabeledContent("Maximum connections") {
                    HStack {
                        Slider(value: Binding(get: { Double(maxPeers) }, set: { maxPeers = Int($0) }), in: 20...150, step: 10)
                            .frame(width: 180)
                        Text("\(maxPeers)").monospacedDigit().frame(width: 34, alignment: .trailing)
                    }
                }
                Toggle("Find peers through the DHT", isOn: $enableDHT)
                Toggle("Add public trackers to magnet links", isOn: $publicTrackers)
                Text("Changes apply to the next torrent you open.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .formStyle(.grouped)
            .tabItem { Label("BitTorrent", systemImage: "point.3.connected.trianglepath.dotted") }

            SourcesSettings()
                .tabItem { Label("Sources", systemImage: "dot.radiowaves.up.forward") }

            Form {
                LabeledContent("Location") {
                    Button(AppModel.cacheDirectory.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")) {
                        try? FileManager.default.createDirectory(at: AppModel.cacheDirectory, withIntermediateDirectories: true)
                        NSWorkspace.shared.activateFileViewerSelecting([AppModel.cacheDirectory])
                    }
                    .buttonStyle(.link)
                    .id(cacheFolder)
                }
                if let chosen = AppModel.chosenCacheFolder, !FileManager.default.fileExists(atPath: chosen.path) {
                    Text("\(chosen.path) isn't available, so downloads go to the default folder for now.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                HStack {
                    if movingCache {
                        ProgressView().controlSize(.small)
                        Text("Moving the cache…").foregroundStyle(.secondary)
                    }
                    Spacer()
                    if !cacheFolder.isEmpty {
                        Button("Use Default") { moveCache(to: nil) }
                    }
                    Button("Change…") { chooseCacheFolder() }
                }
                .disabled(movingCache)
                LabeledContent("Size on disk") {
                    Text(cacheSize.map(formatSize) ?? "…").foregroundStyle(.secondary)
                }
                Toggle("Clear the cache when Bobcorn quits", isOn: $clearCacheOnQuit)
                HStack {
                    Spacer()
                    Button("Clear Cache Now") {
                        model.clearCache()
                        refreshSize()
                    }
                }
                Text("Watched films stay cached so they resume instantly and help seed the swarm while they play.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .formStyle(.grouped)
            .tabItem { Label("Cache", systemImage: "internaldrive") }
            .onAppear(perform: refreshSize)

            Form {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        Image(systemName: "popcorn.fill").font(.system(size: 30)).foregroundStyle(Theme.accent)
                        VStack(alignment: .leading) {
                            Text("Bobcorn").font(.title2.bold())
                            Text("A streaming BitTorrent movie player").foregroundStyle(.secondary)
                        }
                    }
                    Text("Bobcorn shows the movies and shows of the sources you add, and streams them over BitTorrent while they download. You can also open any magnet link or .torrent file. Only add sources and open torrents you have the right to download.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 560, height: 430)
    }

    private func chooseCacheFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use This Folder"
        panel.message = "Choose where Bobcorn keeps downloads. It makes a “Bobcorn Torrents” folder inside, and moves what's downloaded there."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        moveCache(to: url)
    }

    private func moveCache(to folder: URL?) {
        movingCache = true
        Task {
            _ = await model.moveCache(to: folder)
            movingCache = false
            refreshSize()
        }
    }

    private func refreshSize() {
        cacheSize = nil
        Task.detached {
            let size = TorrentEngine.cacheSize(at: AppModel.cacheDirectory)
            await MainActor.run { cacheSize = size }
        }
    }
}
