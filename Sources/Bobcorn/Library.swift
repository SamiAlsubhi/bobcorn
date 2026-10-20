import Foundation
import Observation

/// Favorites, watch history and resume positions, kept in Application Support.
@MainActor
@Observable
final class Library {
    struct Progress: Codable, Hashable {
        var position: Double
        var duration: Double
        var updated: Date
        var title: String
        var item: CatalogItem?

        var fraction: Double { duration > 0 ? min(1, position / duration) : 0 }
    }

    private struct Stored: Codable {
        var favorites: [CatalogItem] = []
        var watched: [String] = []
        var progress: [String: Progress] = [:]
    }

    private(set) var favorites: [CatalogItem] = []
    private(set) var watched: Set<String> = []
    private(set) var progress: [String: Progress] = [:]
    private var saveTask: Task<Void, Never>?

    private let fileURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier?.hasSuffix(".debug") == true ? "Bobcorn Debug" : "Bobcorn", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("library.json")
    }()

    init() {
        if let data = try? Data(contentsOf: fileURL),
           let stored = try? JSONDecoder().decode(Stored.self, from: data) {
            favorites = stored.favorites
            watched = Set(stored.watched)
            progress = stored.progress
        }
    }

    func isFavorite(_ id: String) -> Bool { favorites.contains { $0.id == id } }

    func toggleFavorite(_ item: CatalogItem) {
        if let i = favorites.firstIndex(where: { $0.id == item.id }) {
            favorites.remove(at: i)
        } else {
            favorites.insert(item, at: 0)
        }
        scheduleSave()
    }

    func isWatched(_ key: String) -> Bool { watched.contains(key) }

    func setWatched(_ key: String, _ value: Bool) {
        if value { watched.insert(key) } else { watched.remove(key) }
        if value { progress[key] = nil }
        scheduleSave()
    }

    /// Where to resume, if the last session stopped somewhere worth resuming.
    func resumePosition(_ key: String) -> Double? {
        guard let p = progress[key], p.position > 30, p.fraction < 0.95 else { return nil }
        return p.position
    }

    func record(_ key: String, position: Double, duration: Double, title: String, item: CatalogItem?) {
        guard duration > 0, position.isFinite, duration.isFinite else { return }
        if position / duration > 0.92 {
            watched.insert(key)
            if let item { watched.insert(item.id) }
            progress[key] = nil
        } else if position > 30 {
            progress[key] = Progress(position: position, duration: duration, updated: Date(), title: title, item: item)
        }
        scheduleSave()
    }

    var continueWatching: [(key: String, progress: Progress)] {
        progress.filter { $0.value.item != nil }
            .sorted { $0.value.updated > $1.value.updated }
            .map { ($0.key, $0.value) }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        let stored = Stored(favorites: favorites, watched: Array(watched), progress: progress)
        if let data = try? JSONEncoder().encode(stored) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}

/// User defaults keys and their defaults.
enum Pref {
    static let streamMode = "streamMode" // "torrent" or "direct"
    static let dataSaver = "dataSaver"
    static let subtitleSize = "subtitleSize"
    static let maxPeers = "maxPeers"
    static let enableDHT = "enableDHT"
    static let publicTrackers = "publicTrackers"
    static let clearCacheOnQuit = "clearCacheOnQuit"
    static let autoplayNext = "autoplayNext"

    static func register() {
        UserDefaults.standard.register(defaults: [
            streamMode: "torrent",
            dataSaver: false,
            subtitleSize: 26.0,
            maxPeers: 60,
            enableDHT: true,
            publicTrackers: true,
            clearCacheOnQuit: false,
            autoplayNext: true,
        ])
    }

    static var prefersTorrent: Bool { UserDefaults.standard.string(forKey: streamMode) != "direct" }
    static var dataSaverOn: Bool { UserDefaults.standard.bool(forKey: dataSaver) }
    static var autoplay: Bool { UserDefaults.standard.bool(forKey: autoplayNext) }
}
