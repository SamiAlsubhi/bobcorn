import Foundation
import Observation

/// A source's movie or show as My List keeps it: enough to show its poster
/// and open its page again.
struct SavedTitle: Codable, Hashable, Identifiable {
    /// The IMDb ID.
    let id: String
    let type: APIMediaType
    let title: String
    let year: Int?
    let poster: URL?
    /// The API it came from.
    let base: URL
}

/// My List, watch history and resume positions, kept in Application Support.
@MainActor
@Observable
final class Library {
    struct Progress: Codable, Hashable {
        var position: Double
        var duration: Double
        var updated: Date
        var title: String
        var saved: SavedTitle?

        var fraction: Double { duration > 0 ? min(1, position / duration) : 0 }
    }

    /// Each part optional, so a file from an older version still loads.
    private struct Stored: Codable {
        var saved: [SavedTitle]?
        var watched: [String]?
        var progress: [String: Progress]?
    }

    private(set) var saved: [SavedTitle] = []
    private(set) var watched: Set<String> = []
    private(set) var progress: [String: Progress] = [:]
    private var saveTask: Task<Void, Never>?
    private let fileURL: URL

    nonisolated static let defaultURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier?.hasSuffix(".debug") == true ? "Bobcorn Debug" : "Bobcorn", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("library.json")
    }()

    init(fileURL: URL = Library.defaultURL) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL),
           let stored = try? JSONDecoder().decode(Stored.self, from: data) {
            saved = stored.saved ?? []
            watched = Set(stored.watched ?? [])
            progress = stored.progress ?? [:]
        }
    }

    func isSaved(_ id: String) -> Bool { saved.contains { $0.id == id } }

    func toggleSaved(_ title: SavedTitle) {
        if let i = saved.firstIndex(where: { $0.id == title.id }) {
            saved.remove(at: i)
        } else {
            saved.insert(title, at: 0)
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

    func record(_ key: String, position: Double, duration: Double, title: String, saved: SavedTitle?) {
        guard duration > 0, position.isFinite, duration.isFinite else { return }
        if position / duration > 0.92 {
            watched.insert(key)
            progress[key] = nil
        } else if position > 30 {
            progress[key] = Progress(position: position, duration: duration, updated: Date(), title: title, saved: saved)
        }
        scheduleSave()
    }

    /// Titles left part-way, latest first; a show once, for its latest episode.
    var continueWatching: [(key: String, progress: Progress)] {
        var seen = Set<String>()
        return progress.filter { $0.value.saved != nil }
            .sorted { $0.value.updated > $1.value.updated }
            .filter { seen.insert($0.value.saved!.id).inserted }
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
        let stored = Stored(saved: saved, watched: Array(watched), progress: progress)
        if let data = try? JSONEncoder().encode(stored) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}

/// User defaults keys and their defaults.
enum Pref {
    static let subtitleSize = "subtitleSize"
    static let maxPeers = "maxPeers"
    static let enableDHT = "enableDHT"
    static let publicTrackers = "publicTrackers"
    static let clearCacheOnQuit = "clearCacheOnQuit"
    static let autoplayNext = "autoplayNext"
    static let omdbKey = "omdbKey"
    /// A folder the user picked for downloads; empty for the default.
    static let cacheFolder = "cacheFolder"

    static func register() {
        UserDefaults.standard.register(defaults: [
            subtitleSize: 26.0,
            maxPeers: 60,
            enableDHT: true,
            publicTrackers: true,
            clearCacheOnQuit: false,
            autoplayNext: true,
        ])
    }

    static var autoplay: Bool { UserDefaults.standard.bool(forKey: autoplayNext) }
}
