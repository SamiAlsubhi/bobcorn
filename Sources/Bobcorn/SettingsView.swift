import SwiftUI
import TorrentKit

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(Pref.streamMode) private var streamMode = "torrent"
    @AppStorage(Pref.dataSaver) private var dataSaver = false
    @AppStorage(Pref.subtitleSize) private var subtitleSize = 26.0
    @AppStorage(Pref.autoplayNext) private var autoplayNext = true
    @AppStorage(Pref.maxPeers) private var maxPeers = 60
    @AppStorage(Pref.enableDHT) private var enableDHT = true
    @AppStorage(Pref.publicTrackers) private var publicTrackers = true
    @AppStorage(Pref.clearCacheOnQuit) private var clearCacheOnQuit = false
    @State private var cacheSize: Int64?

    var body: some View {
        TabView {
            Form {
                Picker("Stream Internet Archive titles", selection: $streamMode) {
                    Text("Over BitTorrent").tag("torrent")
                    Text("Directly over HTTPS").tag("direct")
                }
                .pickerStyle(.radioGroup)
                Text("BitTorrent fetches from peers and the Archive's web seeds at once. If a swarm stalls, Bobcorn switches to the direct stream on its own.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Prefer smaller files (data saver)", isOn: $dataSaver)
                Toggle("Play the next episode automatically", isOn: $autoplayNext)

                LabeledContent("Subtitle size") {
                    HStack {
                        Slider(value: $subtitleSize, in: 16...44, step: 2)
                            .frame(width: 180)
                        Text("\(Int(subtitleSize)) pt").monospacedDigit().frame(width: 44, alignment: .trailing)
                    }
                }

                LabeledContent("External players") {
                    let installed = ExternalPlayer.installed
                    Text(installed.isEmpty ? "None found (IINA or VLC play MKV and AVI)" : installed.map(\.name).joined(separator: ", "))
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
                }
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
                    Text("The catalog is the Internet Archive's collections of public-domain and openly licensed film, television and animation. You can also open any magnet link or .torrent file you have the right to download.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Link("Internet Archive: Moving Image Archive", destination: URL(string: "https://archive.org/details/movies")!)
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 560, height: 430)
    }

    private func refreshSize() {
        cacheSize = nil
        Task.detached {
            let size = TorrentEngine.cacheSize(at: AppModel.cacheDirectory)
            await MainActor.run { cacheSize = size }
        }
    }
}
