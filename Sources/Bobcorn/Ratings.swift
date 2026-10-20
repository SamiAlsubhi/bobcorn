import Foundation
import Observation
import SwiftUI

/// Rotten Tomatoes' Tomatometer for titles, by IMDb ID, from OMDb (which
/// needs a free API key, set in Settings). Kept on disk: a score for two
/// weeks, a title without one for three days.
@MainActor
@Observable
final class Ratings {
    private struct Entry: Codable {
        var tomatometer: Int?
        var fetched: Date
    }

    private(set) var tomatometer: [String: Int] = [:]
    /// What OMDb last said was wrong, such as a bad key.
    private(set) var lastError: String?
    private var entries: [String: Entry] = [:]
    private var waiting: [String] = []
    private var asked = Set<String>()
    private var running = 0
    private var saveTask: Task<Void, Never>?

    private static let fileURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Bobcorn/ratings.json")
    private static let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 15
        return URLSession(configuration: c)
    }()

    init() {
        if let data = try? Data(contentsOf: Self.fileURL),
           let stored = try? JSONDecoder().decode([String: Entry].self, from: data) {
            entries = stored
            for (id, e) in stored { if let t = e.tomatometer { tomatometer[id] = t } }
        }
    }

    static var apiKey: String {
        UserDefaults.standard.string(forKey: Pref.omdbKey)?.trimmingCharacters(in: .whitespaces) ?? ""
    }

    /// Fetches a title's score unless it's known and fresh, or there's no key.
    func load(_ imdbID: String) {
        guard imdbID.hasPrefix("tt"), !Self.apiKey.isEmpty, !asked.contains(imdbID) else { return }
        if let e = entries[imdbID], Date().timeIntervalSince(e.fetched) < (e.tomatometer == nil ? 3 : 14) * 86400 { return }
        asked.insert(imdbID)
        waiting.append(imdbID)
        next()
    }

    #if DEBUG
    /// For checking the badges without an OMDb key.
    func debugSet(_ imdbID: String, _ score: Int) { tomatometer[imdbID] = score }
    #endif

    /// After the key changes: try again what failed.
    func keyChanged() {
        lastError = nil
        asked = Set(entries.keys)
    }

    private func next() {
        // A few at a time: a grid asks for fifty at once.
        while running < 4, !waiting.isEmpty {
            let id = waiting.removeLast()
            running += 1
            Task {
                let result = await Self.fetch(id, key: Self.apiKey)
                running -= 1
                switch result {
                case .success(let score):
                    entries[id] = Entry(tomatometer: score, fetched: Date())
                    tomatometer[id] = score
                    lastError = nil
                    scheduleSave()
                case .failure(let error):
                    asked.remove(id)
                    lastError = error.localizedDescription
                    if case OMDbError.badKey = error { waiting.removeAll() }
                }
                next()
            }
        }
    }

    enum OMDbError: LocalizedError {
        case badKey(String)
        case other(String)

        var errorDescription: String? {
            switch self {
            case .badKey(let why): return "OMDb refused the key: \(why)"
            case .other(let why): return "OMDb: \(why)"
            }
        }
    }

    /// The Tomatometer percentage, or nil when Rotten Tomatoes has none.
    nonisolated static func fetch(_ imdbID: String, key: String) async -> Result<Int?, Error> {
        var c = URLComponents(string: "https://www.omdbapi.com/")!
        c.queryItems = [URLQueryItem(name: "i", value: imdbID), URLQueryItem(name: "apikey", value: key)]
        do {
            let (data, _) = try await session.data(from: c.url!)
            return parse(data)
        } catch {
            return .failure(OMDbError.other(error.localizedDescription))
        }
    }

    nonisolated static func parse(_ data: Data) -> Result<Int?, Error> {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return .failure(OMDbError.other("an answer that isn't JSON"))
        }
        if json["Response"] as? String == "False" {
            let why = json["Error"] as? String ?? "unknown error"
            // A title OMDb doesn't know simply has no score.
            if why.lowercased().contains("not found") { return .success(nil) }
            if why.lowercased().contains("key") || why.lowercased().contains("limit") { return .failure(OMDbError.badKey(why)) }
            return .failure(OMDbError.other(why))
        }
        let ratings = json["Ratings"] as? [[String: Any]] ?? []
        let value = ratings.first { $0["Source"] as? String == "Rotten Tomatoes" }?["Value"] as? String
        return .success(value.flatMap { Int($0.replacingOccurrences(of: "%", with: "")) })
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled, let self else { return }
            try? FileManager.default.createDirectory(at: Self.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let data = try? JSONEncoder().encode(self.entries) { try? data.write(to: Self.fileURL, options: .atomic) }
        }
    }
}

/// Rotten Tomatoes counts 60% and up as fresh.
func isFresh(_ tomatometer: Int) -> Bool { tomatometer >= 60 }

/// A ripe tomato for a fresh score, a green splat for a rotten one. Drawn
/// here, not Rotten Tomatoes' own artwork.
struct TomatoIcon: View {
    let fresh: Bool
    var size: CGFloat = 14

    var body: some View {
        Canvas { ctx, canvas in
            let w = canvas.width
            let h = canvas.height
            if fresh {
                let body = Path(ellipseIn: CGRect(x: w * 0.04, y: h * 0.2, width: w * 0.92, height: h * 0.76))
                ctx.fill(body, with: .linearGradient(
                    Gradient(colors: [Color(red: 0.98, green: 0.32, blue: 0.2), Color(red: 0.8, green: 0.1, blue: 0.06)]),
                    startPoint: CGPoint(x: w * 0.3, y: h * 0.25), endPoint: CGPoint(x: w * 0.7, y: h)))
                ctx.fill(Path(ellipseIn: CGRect(x: w * 0.22, y: h * 0.36, width: w * 0.22, height: h * 0.14)),
                         with: .color(.white.opacity(0.45)))
                // The leaves: a five-pointed star on top.
                var leaves = Path()
                let center = CGPoint(x: w * 0.5, y: h * 0.24)
                for k in 0..<10 {
                    let angle = Double(k) * .pi / 5 - .pi / 2
                    let r = k % 2 == 0 ? w * 0.3 : w * 0.1
                    let p = CGPoint(x: center.x + r * cos(angle), y: center.y + r * sin(angle) * 0.6)
                    if k == 0 { leaves.move(to: p) } else { leaves.addLine(to: p) }
                }
                leaves.closeSubpath()
                ctx.fill(leaves, with: .color(Color(red: 0.2, green: 0.62, blue: 0.22)))
            } else {
                // A splat: a blob with uneven lobes, and two drops.
                var splat = Path()
                let center = CGPoint(x: w * 0.5, y: h * 0.52)
                let lobes: [CGFloat] = [0.46, 0.3, 0.42, 0.28, 0.47, 0.32, 0.4, 0.27, 0.44, 0.31]
                for (k, r) in lobes.enumerated() {
                    let angle = Double(k) * 2 * .pi / Double(lobes.count)
                    let p = CGPoint(x: center.x + w * r * cos(angle), y: center.y + h * r * sin(angle))
                    if k == 0 { splat.move(to: p) } else { splat.addLine(to: p) }
                }
                splat.closeSubpath()
                let green = Color(red: 0.42, green: 0.7, blue: 0.16)
                ctx.fill(splat, with: .color(green))
                ctx.fill(Path(ellipseIn: CGRect(x: w * 0.02, y: h * 0.04, width: w * 0.16, height: h * 0.16)), with: .color(green))
                ctx.fill(Path(ellipseIn: CGRect(x: w * 0.82, y: h * 0.8, width: w * 0.13, height: h * 0.13)), with: .color(green))
                ctx.fill(Path(ellipseIn: CGRect(x: w * 0.36, y: h * 0.4, width: w * 0.28, height: h * 0.24)),
                         with: .color(Color(red: 0.3, green: 0.52, blue: 0.1)))
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel(fresh ? "Fresh" : "Rotten")
    }
}

/// The Tomatometer: an icon and a percentage.
struct TomatometerLabel: View {
    let score: Int
    var size: CGFloat = 13

    var body: some View {
        HStack(spacing: 3) {
            TomatoIcon(fresh: isFresh(score), size: size)
            Text("\(score)%")
        }
        .help("Rotten Tomatoes: \(score)%, \(isFresh(score) ? "fresh" : "rotten")")
    }
}
