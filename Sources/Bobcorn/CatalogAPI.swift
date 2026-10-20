import Foundation
import Observation
import TorrentKit

// MARK: - Queries

/// The two listings a catalog API serves.
enum APIMediaType: String, CaseIterable, Identifiable {
    case movies, shows

    var id: String { rawValue }

    var title: String {
        switch self {
        case .movies: return "Movies"
        case .shows: return "TV Shows"
        }
    }

    /// `/movies/<page>` lists titles, `/movie/<imdb_id>` describes one.
    var listPath: String { rawValue }
    var itemPath: String { self == .movies ? "movie" : "show" }
}

enum APISort: String, CaseIterable, Identifiable {
    case trending, views, rating, year, name

    var id: String { rawValue }

    var title: String {
        switch self {
        case .trending: return "Trending"
        case .views: return "Popularity"
        case .rating: return "Rating"
        case .year: return "Year"
        case .name: return "Title"
        }
    }

    /// Titles read A to Z; everything else best or newest first.
    var order: Int { self == .name ? 1 : -1 }
}

struct APIQuery: Hashable {
    var sourceID: UUID
    var base: URL
    var type: APIMediaType
    var genre: Genre
    var sort: APISort
    var search: String

    /// The genres a catalog API filters by. The clause is the slug it takes.
    static let genres: [Genre] = [.all] + [
        ("Action", "action"), ("Adventure", "adventure"), ("Animation", "animation"),
        ("Comedy", "comedy"), ("Crime", "crime"), ("Documentary", "documentary"),
        ("Drama", "drama"), ("Family", "family"), ("Fantasy", "fantasy"),
        ("History", "history"), ("Horror", "horror"), ("Music", "music"),
        ("Mystery", "mystery"), ("Romance", "romance"), ("Sci-Fi", "sci-fi"),
        ("Thriller", "thriller"), ("War", "war"), ("Western", "western"),
    ].map { Genre($0.0, $0.1) }
}

// MARK: - Titles

/// A movie or show as a catalog API lists it.
struct APITitle: Identifiable, Hashable {
    /// The IMDb ID, which the detail endpoints take.
    let id: String
    let type: APIMediaType
    let title: String
    let year: Int?
    let synopsis: String?
    /// Minutes; per episode for a show.
    let runtime: Int?
    /// 0 to 100.
    let rating: Double?
    let votes: Int?
    let certification: String?
    let posterURL: URL?
    let fanartURL: URL?
    let genres: [String]
    let seasonCount: Int?
    /// A movie's torrents, one per quality and language.
    let options: [FeedOption]

    /// The rating out of five, for stars.
    var stars: Double? { rating.map { $0 / 20 } }
    var imdbURL: URL? { URL(string: "https://www.imdb.com/title/\(id)/") }
    var libraryKey: String { "api:\(id)" }

    var qualities: [String] {
        Array(Set(options.compactMap(\.release.quality))).sorted { (Int($0.dropLast()) ?? 0) > (Int($1.dropLast()) ?? 0) }
    }
}

struct APIEpisode: Identifiable, Hashable {
    let season: Int
    let episode: Int
    let title: String
    let overview: String?
    let aired: Date?
    let options: [FeedOption]

    var id: String { "s\(season)e\(episode)" }
    var tag: String { String(format: "S%02dE%02d", season, episode) }
}

/// What the detail endpoint adds to a listing: full metadata, and a show's
/// episodes with their torrents.
struct APIDetails {
    let title: APITitle
    let episodes: [APIEpisode]

    var seasons: [Int] { Array(Set(episodes.map(\.season))).sorted() }

    func episodes(in season: Int) -> [APIEpisode] {
        episodes.filter { $0.season == season }
    }

    func key(_ episode: APIEpisode) -> String { "\(title.libraryKey):\(episode.id)" }
}

extension FeedEntry {
    /// What to open: the magnet, or the .torrent file.
    var link: String? { magnet ?? torrentURL?.absoluteString }
}

extension Array where Element == FeedOption {
    /// The best-seeded option, in this quality when one has seeds.
    func best(preferring quality: String? = nil) -> FeedOption? {
        let same = filter { $0.release.quality == quality && ($0.entry.seeders ?? 1) > 0 }
        return (same.isEmpty ? self : same).max {
            ($0.entry.seeders ?? -1, $0.release.qualityRank) < ($1.entry.seeders ?? -1, $1.release.qualityRank)
        }
    }
}

// MARK: - Fetching

enum APIError: LocalizedError {
    case badURL
    case notAnAPI
    case notFound

    var errorDescription: String? {
        switch self {
        case .badURL: return "That isn't a valid API address."
        case .notAnAPI: return "That address didn't answer with a list of movies or shows."
        case .notFound: return "The source has no details for this title."
        }
    }
}

enum APIClient {
    /// One page of a listing. Pages count from 1; an empty page is the end.
    static func page(_ query: APIQuery, page: Int) async throws -> [APITitle] {
        let path = query.base.appendingPathComponent(query.type.listPath).appendingPathComponent(String(page))
        var c = URLComponents(url: path, resolvingAgainstBaseURL: false)
        var items = [URLQueryItem(name: "sort", value: query.sort.rawValue),
                     URLQueryItem(name: "order", value: String(query.sort.order))]
        if let slug = query.genre.clause { items.append(URLQueryItem(name: "genre", value: slug)) }
        let search = query.search.trimmingCharacters(in: .whitespaces)
        if !search.isEmpty { items.append(URLQueryItem(name: "keywords", value: search)) }
        c?.queryItems = items
        guard let url = c?.url else { throw APIError.badURL }
        let data: Data
        do {
            data = try await FeedClient.data(url)
        } catch FeedError.http(404) where page > 1 {
            return []
        }
        return try titles(from: data, type: query.type, base: query.base)
    }

    static func details(_ base: URL, _ title: APITitle) async throws -> APIDetails {
        let url = base.appendingPathComponent(title.type.itemPath).appendingPathComponent(title.id)
        return try details(from: try await FeedClient.data(url), listed: title, base: base)
    }

    static func titles(from data: Data, type: APIMediaType, base: URL) throws -> [APITitle] {
        try decode(data).compactMap { APITitle($0, type: type, base: base) }
    }

    static func details(from data: Data, listed title: APITitle, base: URL) throws -> APIDetails {
        guard let raw = try decode(data).first,
              let full = APITitle(raw, type: title.type, base: base)
        else { throw APIError.notFound }
        let episodes = (raw.episodes ?? []).compactMap(\.value).compactMap { APIEpisode($0, show: full) }
        // Mirrors list an episode once per provider; keep the one with more torrents.
        var byID: [String: APIEpisode] = [:]
        for e in episodes where (byID[e.id]?.options.count ?? -1) < e.options.count { byID[e.id] = e }
        let sorted = byID.values.sorted { ($0.season, $0.episode) < ($1.season, $1.episode) }
        // A listing can carry torrents the detail endpoint leaves out.
        let merged = full.options.isEmpty && !title.options.isEmpty ? full.with(options: title.options) : full
        return APIDetails(title: merged, episodes: sorted)
    }

    /// A page is a JSON array of titles. A single title is an object, or on
    /// some mirrors an array holding one.
    fileprivate static func decode(_ data: Data) throws -> [RawTitle] {
        let decoder = JSONDecoder()
        if let list = try? decoder.decode([Lenient<RawTitle>].self, from: data) {
            return list.compactMap(\.value).filter(\.isTitle)
        }
        if let one = try? decoder.decode(RawTitle.self, from: data), one.isTitle {
            return [one]
        }
        throw APIError.notAnAPI
    }
}

/// The listing behind a catalog API source, loaded a page at a time.
@MainActor
@Observable
final class APIBrowseModel {
    private(set) var titles: [APITitle] = []
    private(set) var isLoading = false
    private(set) var error: String?
    private(set) var exhausted = false
    private(set) var source: CustomSource?
    private(set) var query: APIQuery?
    private var page = 0
    private var task: Task<Void, Never>?
    private var seen = Set<String>()

    func load(_ source: CustomSource, _ q: APIQuery) {
        task?.cancel()
        self.source = source
        query = q
        titles = []
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
                let result = try await APIClient.page(query, page: next)
                guard let self, !Task.isCancelled, self.query == query else { return }
                let fresh = result.filter { self.seen.insert($0.id).inserted }
                self.titles.append(contentsOf: fresh)
                self.page = next
                self.exhausted = fresh.isEmpty
                self.isLoading = false
            } catch {
                guard let self, !Task.isCancelled, self.query == query else { return }
                self.error = error.localizedDescription
                self.isLoading = false
            }
        }
    }

    func retry() {
        if let source, let query, titles.isEmpty { load(source, query) } else { loadMore() }
    }
}

// MARK: - Wire format

/// Decodes what it can and leaves nil for the rest, so one odd entry doesn't
/// sink a whole page.
private struct Lenient<T: Decodable>: Decodable {
    let value: T?

    init(from decoder: Decoder) throws {
        value = try? T(from: decoder)
    }
}

fileprivate struct RawTitle: Decodable {
    struct Rating: Decodable {
        let percentage: Loose?
        let votes: Loose?
    }

    struct Images: Decodable {
        let poster: Loose?
        let fanart: Loose?
        let banner: Loose?
    }

    let _id: Loose?
    let imdb_id: Loose?
    let title: Loose?
    let year: Loose?
    let synopsis: Loose?
    let runtime: Loose?
    let certification: Loose?
    let rating: Lenient<Rating>?
    let images: Lenient<Images>?
    let genres: Loose?
    let num_seasons: Loose?
    let torrents: Lenient<[String: Lenient<TorrentNode>]>?
    let episodes: [Lenient<RawEpisode>]?

    var isTitle: Bool { (imdb_id?.text ?? _id?.text) != nil && title?.text != nil }
}

fileprivate struct RawEpisode: Decodable {
    let season: Loose?
    let episode: Loose?
    let title: Loose?
    let overview: Loose?
    let first_aired: Loose?
    let torrents: Lenient<[String: Lenient<TorrentNode>]>?
}

fileprivate struct RawTorrent: Decodable {
    let url: String?
    let magnet: String?
    // Movies say seed and peer, episodes seeds and peers.
    let seed: Loose?
    let seeds: Loose?
    let peer: Loose?
    let peers: Loose?
    let size: Loose?
    let filesize: Loose?

    var link: String? { url ?? magnet }
}

/// A movie's torrents are grouped by language, then quality; an episode's by
/// quality alone. Each node is a torrent or a group of them.
fileprivate enum TorrentNode: Decodable {
    case torrent(RawTorrent)
    case group([String: Lenient<RawTorrent>])

    init(from decoder: Decoder) throws {
        if let t = try? RawTorrent(from: decoder), t.link != nil {
            self = .torrent(t)
        } else {
            self = .group(try [String: Lenient<RawTorrent>](from: decoder))
        }
    }
}

private extension APITitle {
    init?(_ raw: RawTitle, type: APIMediaType, base: URL) {
        guard let id = raw.imdb_id?.text ?? raw._id?.text, let title = raw.title?.text, !title.isEmpty else { return nil }
        let year = raw.year?.int
        self.init(
            id: id,
            type: type,
            title: title,
            year: year,
            synopsis: raw.synopsis?.text.map(ArchiveClient.cleanHTML),
            runtime: raw.runtime?.int.flatMap { $0 > 0 ? $0 : nil },
            rating: raw.rating?.value?.percentage?.double,
            votes: raw.rating?.value?.votes?.int,
            certification: raw.certification?.text.flatMap { $0.isEmpty ? nil : $0 },
            posterURL: Self.image(raw.images?.value?.poster, base),
            fanartURL: Self.image(raw.images?.value?.fanart, base) ?? Self.image(raw.images?.value?.banner, base),
            // Slugs ("science-fiction") read as words; names ("Sci-Fi") stay.
            genres: (raw.genres?.list ?? []).map { $0 == $0.lowercased() ? $0.replacingOccurrences(of: "-", with: " ").capitalized : $0 },
            seasonCount: raw.num_seasons?.int,
            options: makeOptions(raw.torrents?.value, release: ReleaseInfo(title: title, year: year), artwork: Self.image(raw.images?.value?.poster, base))
        )
    }

    func with(options: [FeedOption]) -> APITitle {
        APITitle(id: id, type: type, title: title, year: year, synopsis: synopsis, runtime: runtime, rating: rating,
                 votes: votes, certification: certification, posterURL: posterURL, fanartURL: fanartURL,
                 genres: genres, seasonCount: seasonCount, options: options)
    }

    /// Image URLs may be relative to the API.
    static func image(_ value: Loose?, _ base: URL) -> URL? {
        guard let s = value?.text, !s.isEmpty, !s.contains("posterholder") else { return nil }
        return URL(string: s, relativeTo: base)?.absoluteURL
    }
}

private extension APIEpisode {
    init?(_ raw: RawEpisode, show: APITitle) {
        guard let season = raw.season?.int, let episode = raw.episode?.int else { return nil }
        let tag = String(format: "S%02dE%02d", season, episode)
        let release = ReleaseInfo(title: show.title, season: season, episode: episode)
        self.init(
            season: season,
            episode: episode,
            title: raw.title?.text.flatMap { $0.isEmpty ? nil : ArchiveClient.cleanHTML($0) } ?? "Episode \(episode)",
            overview: raw.overview?.text.map(ArchiveClient.cleanHTML),
            aired: raw.first_aired?.double.flatMap { $0 != 0 ? Date(timeIntervalSince1970: $0) : nil },
            options: makeOptions(raw.torrents?.value, release: release, artwork: show.posterURL, fallbackName: "\(show.title) \(tag)")
        )
    }
}

/// Every torrent in a `torrents` object as a playable option, one per link.
private func makeOptions(_ torrents: [String: Lenient<TorrentNode>]?, release: ReleaseInfo, artwork: URL?, fallbackName: String? = nil) -> [FeedOption] {
    var flat: [(quality: String, language: String?, torrent: RawTorrent)] = []
    for (key, node) in torrents ?? [:] {
        switch node.value {
        case .torrent(let t): flat.append((key, nil, t))
        case .group(let g): for (quality, t) in g { if let t = t.value { flat.append((quality, key, t)) } }
        case nil: break
        }
    }
    let languages = Set(flat.compactMap(\.language))
    // Episodes repeat their default quality under "0"; keep the named one.
    flat.sort { ($0.quality == "0" ? 1 : 0, $0.quality) < ($1.quality == "0" ? 1 : 0, $1.quality) }
    var seen = Set<String>()
    var options: [FeedOption] = []
    for (quality, language, t) in flat {
        guard let link = t.link?.trimmingCharacters(in: .whitespacesAndNewlines), !link.isEmpty, seen.insert(link).inserted else { continue }
        let magnet = link.lowercased().hasPrefix("magnet:") ? link : nil
        let torrentURL = magnet == nil ? URL(string: link) : nil
        guard magnet != nil || torrentURL != nil else { continue }
        let parsed = magnet.flatMap { try? MagnetLink(string: $0) }
        let label = quality == "0" ? "SD" : quality
        var name = parsed?.displayName ?? torrentURL?.lastPathComponent ?? "\(fallbackName ?? release.title) \(label)"
        if languages.count > 1, let language { name += " · \(language.uppercased())" }
        var r = release
        r.quality = label
        let entry = FeedEntry(
            id: link,
            title: name,
            magnet: magnet,
            torrentURL: torrentURL,
            infoHash: parsed?.infoHashHex,
            size: t.size?.int64.flatMap { $0 > 0 ? $0 : nil } ?? t.filesize?.text.flatMap(FeedParser.parseSize),
            seeders: (t.seed ?? t.seeds)?.int,
            leechers: (t.peer ?? t.peers)?.int,
            published: nil,
            summary: nil,
            imageURL: artwork,
            category: language
        )
        options.append(FeedOption(entry: entry, release: r))
    }
    return options
}
