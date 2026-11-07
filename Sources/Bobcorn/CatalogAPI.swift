import Foundation
import Observation
import TorrentKit

// MARK: - Queries

/// The two listings a catalog API serves.
enum APIMediaType: String, CaseIterable, Identifiable, Codable {
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
    /// The API it came from.
    let base: URL

    /// The rating out of five, for stars.
    var stars: Double? { rating.map { $0 / 20 } }
    var imdbURL: URL? { URL(string: "https://www.imdb.com/title/\(id)/") }
    var libraryKey: String { "api:\(id)" }
    var saved: SavedTitle { SavedTitle(id: id, type: type, title: title, year: year, poster: posterURL, base: base) }

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

extension APITitle {
    /// A title from My List, until its page loads the rest.
    init(saved: SavedTitle) {
        self.init(id: saved.id, type: saved.type, title: saved.title, year: saved.year, synopsis: nil, runtime: nil,
                  rating: nil, votes: nil, certification: nil, posterURL: saved.poster, fanartURL: nil, genres: [],
                  seasonCount: nil, options: [], base: saved.base)
    }
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
    ///
    /// A source is either the catalog API Bobcorn has always read
    /// (`/movies/<page>`, ...) or a YTS-style API (`/list_movies.json`, ...).
    /// The two are told apart once per base URL.
    static func page(_ query: APIQuery, page: Int) async throws -> [APITitle] {
        let dialect = await CatalogAPIDialectResolver.shared.dialect(for: query.base)
        switch dialect {
        case .current:
            guard let url = currentListURL(query, page: page) else { throw APIError.badURL }
            return try await fetchPage(url, query: query, page: page)
        case .yts(let root):
            // YTS only has films.
            guard query.type == .movies else { return [] }
            guard let url = ytsListURL(root: root, query: query, page: page) else { throw APIError.badURL }
            return try await fetchPage(url, query: query, page: page)
        }
    }

    static func details(_ base: URL, _ title: APITitle) async throws -> APIDetails {
        let dialect = await CatalogAPIDialectResolver.shared.dialect(for: base)
        let url: URL
        switch dialect {
        case .current:
            url = base.appendingPathComponent(title.type.itemPath).appendingPathComponent(title.id)
        case .yts(let root):
            guard let detail = ytsDetailURL(root: root, title: title) else { throw APIError.badURL }
            url = detail
        }
        return try details(from: try await FeedClient.data(url), listed: title, base: base)
    }

    private static func fetchPage(_ url: URL, query: APIQuery, page: Int) async throws -> [APITitle] {
        let data: Data
        do {
            data = try await FeedClient.data(url)
        } catch FeedError.http(404) where page > 1 {
            return []
        }
        return try titles(from: data, type: query.type, base: query.base)
    }

    // MARK: Catalog API URLs

    static func currentListURL(_ query: APIQuery, page: Int) -> URL? {
        let path = query.base.appendingPathComponent(query.type.listPath).appendingPathComponent(String(page))
        var c = URLComponents(url: path, resolvingAgainstBaseURL: false)
        var items = [URLQueryItem(name: "sort", value: query.sort.rawValue),
                     URLQueryItem(name: "order", value: String(query.sort.order))]
        if let slug = query.genre.clause { items.append(URLQueryItem(name: "genre", value: slug)) }
        let search = query.search.trimmingCharacters(in: .whitespaces)
        if !search.isEmpty { items.append(URLQueryItem(name: "keywords", value: search)) }
        c?.queryItems = items
        return c?.url
    }

    /// A YTS API's base may be `https://yts.gg`, `https://yts.gg/api/v2` or
    /// the list endpoint itself. Try the obvious forms.
    static func ytsRootCandidates(for base: URL) -> [URL] {
        var b = base
        let last = b.lastPathComponent.lowercased()
        if last == "list_movies.json" || last == "movie_details.json" {
            b.deleteLastPathComponent()
        }
        var bString = b.absoluteString
        while bString.hasSuffix("/") { bString.removeLast() }
        b = URL(string: bString) ?? b
        let path = b.path.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        var roots = [b]
        if path.hasSuffix("api/v2") {
            // Already the API root.
        } else if path.hasSuffix("api") {
            roots.append(b.appendingPathComponent("v2"))
        } else {
            roots.append(b.appendingPathComponent("api/v2"))
        }
        var seen = Set<String>()
        return roots.filter { seen.insert($0.absoluteString).inserted }
    }

    static func ytsListURL(root: URL, query: APIQuery, page: Int) -> URL? {
        var c = URLComponents(url: root.appendingPathComponent("list_movies.json"), resolvingAgainstBaseURL: false)
        var items = [URLQueryItem(name: "page", value: String(page)),
                     URLQueryItem(name: "limit", value: "50"),
                     URLQueryItem(name: "sort_by", value: ytsSort(query.sort)),
                     URLQueryItem(name: "order_by", value: query.sort == .name ? "asc" : "desc")]
        if let slug = query.genre.clause { items.append(URLQueryItem(name: "genre", value: ytsGenre(slug))) }
        let search = query.search.trimmingCharacters(in: .whitespaces)
        if !search.isEmpty { items.append(URLQueryItem(name: "query_term", value: search)) }
        c?.queryItems = items
        return c?.url
    }

    static func ytsDetailURL(root: URL, title: APITitle) -> URL? {
        var c = URLComponents(url: root.appendingPathComponent("movie_details.json"), resolvingAgainstBaseURL: false)
        var items = [URLQueryItem(name: "with_images", value: "true"),
                     URLQueryItem(name: "with_cast", value: "true")]
        if title.id.lowercased().hasPrefix("tt") {
            items.append(URLQueryItem(name: "imdb_id", value: title.id))
        } else {
            items.append(URLQueryItem(name: "movie_id", value: title.id))
        }
        c?.queryItems = items
        return c?.url
    }

    private static func ytsSort(_ sort: APISort) -> String {
        switch sort {
        case .trending: return "like_count"
        case .views: return "download_count"
        case .rating: return "rating"
        case .year: return "year"
        case .name: return "title"
        }
    }

    private static func ytsGenre(_ slug: String) -> String {
        slug.split(separator: "-")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: "-")
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
    /// some mirrors an array holding one. YTS wraps its list in
    /// `data.movies` and its detail in `data.movie`.
    fileprivate static func decode(_ data: Data) throws -> [RawTitle] {
        let decoder = JSONDecoder()
        if let list = try? decoder.decode([Lenient<RawTitle>].self, from: data) {
            let titles = list.compactMap(\.value).filter(\.isTitle)
            if !titles.isEmpty { return titles }
            // An array can also be a mirror that drops YTS's wrapper.
            if let yts = ytsTitles(from: data, decoder: decoder) { return yts }
            return []
        }
        if let one = try? decoder.decode(RawTitle.self, from: data), one.isTitle {
            return [one]
        }
        if let yts = ytsTitles(from: data, decoder: decoder) { return yts }
        throw APIError.notAnAPI
    }

    /// YTS's list, detail, and the unwrapped array some mirrors return.
    fileprivate static func ytsTitles(from data: Data, decoder: JSONDecoder) -> [RawTitle]? {
        if let response = try? decoder.decode(YTSResponse.self, from: data), let body = response.data {
            let movies = (body.movies ?? []).compactMap(\.value)
            let all = body.movie.map { [ $0 ] } ?? movies
            // A search with no results, or a page past the end, has a
            // movie_count and no movies at all.
            if !all.isEmpty || body.movies != nil || body.movie_count != nil {
                return all.map { RawTitle(yts: $0) }.filter(\.isTitle)
            }
        }
        if let list = try? decoder.decode([Lenient<YTSMovie>].self, from: data) {
            let movies = list.compactMap(\.value)
            if !movies.isEmpty { return movies.map { RawTitle(yts: $0) }.filter(\.isTitle) }
        }
        if let one = try? decoder.decode(YTSMovie.self, from: data),
           (one.imdb_code?.text ?? one.id?.text) != nil,
           one.title?.text != nil {
            return [RawTitle(yts: one)].filter(\.isTitle)
        }
        return nil
    }

    /// Used only to pick a dialect before the real request.
    fileprivate static func isCurrentJSON(_ data: Data) -> Bool {
        let decoder = JSONDecoder()
        if let list = try? decoder.decode([Lenient<RawTitle>].self, from: data) {
            return list.isEmpty || list.contains { $0.value?.isTitle == true }
        }
        if let one = try? decoder.decode(RawTitle.self, from: data) { return one.isTitle }
        return false
    }

    fileprivate static func isYTSJSON(_ data: Data) -> Bool {
        let decoder = JSONDecoder()
        if let response = try? decoder.decode(YTSResponse.self, from: data),
           let body = response.data {
            return body.movies != nil || body.movie != nil || body.movie_count != nil
        }
        if let list = try? decoder.decode([Lenient<YTSMovie>].self, from: data) {
            return list.contains {
                ($0.value?.imdb_code?.text ?? $0.value?.id?.text) != nil && $0.value?.title?.text != nil
            }
        }
        return false
    }
}

/// How a catalog API answers: Bobcorn's original endpoints, or YTS's.
private enum CatalogAPIDialect: Sendable {
    case current
    case yts(root: URL)
}

/// Picks a dialect once per base URL and remembers it for details and later
/// pages. Detection makes one cheap request, so adding a source stays a
/// single Base URL field.
private actor CatalogAPIDialectResolver {
    static let shared = CatalogAPIDialectResolver()
    private var cache: [String: CatalogAPIDialect] = [:]
    private var pending: [String: Task<CatalogAPIDialect?, Never>] = [:]

    func dialect(for base: URL) async -> CatalogAPIDialect {
        let key = base.absoluteString
        if let known = cache[key] { return known }
        if let task = pending[key] { return await task.value ?? .current }
        let task = Task { await CatalogAPIDialectResolver.detect(base) }
        pending[key] = task
        let dialect = await task.value
        // Remembered only once the source answered, so one started before
        // the network is up is asked again next time.
        if let dialect { cache[key] = dialect }
        pending[key] = nil
        return dialect ?? .current
    }

    /// Nil when nothing answered.
    private static func detect(_ base: URL) async -> CatalogAPIDialect? {
        let probe = APIQuery(sourceID: UUID(), base: base, type: .movies, genre: .all, sort: .trending, search: "")
        var unanswered = false
        switch await fetch(APIClient.currentListURL(probe, page: 1)) {
        case .body(let data) where APIClient.isCurrentJSON(data): return .current
        case .unanswered: unanswered = true
        default: break
        }
        for root in APIClient.ytsRootCandidates(for: base) {
            switch await fetch(APIClient.ytsListURL(root: root, query: probe, page: 1)) {
            case .body(let data) where APIClient.isYTSJSON(data): return .yts(root: root)
            case .unanswered: unanswered = true
            default: break
            }
        }
        return unanswered ? nil : .current
    }

    private enum Probe {
        case body(Data)
        /// An HTTP error, or no URL to ask.
        case refused
        /// Offline, timed out, or the host couldn't be found.
        case unanswered
    }

    private static func fetch(_ url: URL?) async -> Probe {
        guard let url else { return .refused }
        do {
            return .body(try await FeedClient.data(url))
        } catch is FeedError {
            return .refused
        } catch {
            return .unanswered
        }
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

    init(_ value: T?) {
        self.value = value
    }

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
    /// YTS torrents carry the resolution in the object; Bobcorn's own schema
    /// uses the dictionary key. Keeping both lets one quality appear twice
    /// (e.g. a BluRay and a WEB release) without losing a torrent.
    let quality: Loose?

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

// MARK: - YTS wire format

fileprivate struct YTSResponse: Decodable {
    struct Body: Decodable {
        let movie_count: Loose?
        let movies: [Lenient<YTSMovie>]?
        let movie: YTSMovie?
    }

    let data: Body?
}

fileprivate struct YTSMovie: Decodable {
    let id: Loose?
    let imdb_code: Loose?
    let title: Loose?
    let title_english: Loose?
    let title_long: Loose?
    let year: Loose?
    let rating: Loose?
    let runtime: Loose?
    let genres: Loose?
    let summary: Loose?
    let synopsis: Loose?
    let description_full: Loose?
    let description_intro: Loose?
    let mpa_rating: Loose?
    let language: Loose?
    let small_cover_image: Loose?
    let medium_cover_image: Loose?
    let large_cover_image: Loose?
    let background_image: Loose?
    let background_image_original: Loose?
    let torrents: [Lenient<YTSTorrent>]?
}

fileprivate struct YTSTorrent: Decodable {
    let url: Loose?
    let hash: Loose?
    let quality: Loose?
    /// "bluray" or "web".
    let type: Loose?
    let seeds: Loose?
    let peers: Loose?
    let size: Loose?
    let size_bytes: Loose?
}

fileprivate extension RawTitle {
    /// YTS sends one flat movie object; Bobcorn's older schema groups
    /// torrents by language and quality.
    init(yts movie: YTSMovie) {
        let imdb = movie.imdb_code?.text?.trimmingCharacters(in: .whitespacesAndNewlines)
        let numeric = movie.id?.text?.trimmingCharacters(in: .whitespacesAndNewlines)
        let id = (imdb?.isEmpty == false ? imdb : nil) ?? numeric
        _id = id.flatMap { $0.isEmpty ? nil : Loose($0) }
        imdb_id = (imdb?.isEmpty == false ? imdb : nil).map { Loose($0) }

        let name = movie.title?.text ?? movie.title_english?.text ?? movie.title_long?.text
        title = name.map { Loose($0) }
        year = movie.year
        let overview = movie.synopsis?.text ?? movie.summary?.text
            ?? movie.description_intro?.text ?? movie.description_full?.text
        synopsis = overview.map { Loose($0) }
        runtime = movie.runtime
        certification = movie.mpa_rating

        if let score = movie.rating?.double, score > 0 {
            // YTS rates out of ten; Bobcorn shows a percentage.
            let percentage = score <= 10 ? score * 10 : score
            rating = Lenient(RawTitle.Rating(
                percentage: Loose(Int(percentage.rounded())),
                votes: nil
            ))
        } else {
            rating = nil
        }

        let poster = movie.large_cover_image?.text
            ?? movie.medium_cover_image?.text
            ?? movie.small_cover_image?.text
        let fanart = movie.background_image_original?.text ?? movie.background_image?.text
        if poster != nil || fanart != nil {
            images = Lenient(RawTitle.Images(
                poster: poster.map { Loose($0) },
                fanart: fanart.map { Loose($0) },
                banner: nil
            ))
        } else {
            images = nil
        }

        genres = movie.genres
        num_seasons = nil
        episodes = nil

        let language = movie.language?.text.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        let languageKey = (language?.isEmpty == false ? language : nil) ?? "en"
        let releaseTitle = movie.title_long?.text ?? name
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        var group: [String: Lenient<RawTorrent>] = [:]
        for (index, item) in (movie.torrents ?? []).enumerated() {
            guard let torrent = item.value else { continue }
            let quality = (torrent.quality?.text ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let label = quality.isEmpty ? "0" : quality
            let hash = torrent.hash?.text.map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            // YTS names a .torrent by its hash, so the magnet carries a name,
            // with the release type that tells two of one resolution apart:
            // "Example Film (1994) 1080p BluRay".
            let kind = (torrent.type?.text?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
                .flatMap { $0.isEmpty ? nil : $0 == "bluray" ? "BluRay" : $0 == "web" ? "WEB" : $0.uppercased() }
            let releaseName = [releaseTitle, quality.isEmpty ? nil : quality, kind].compactMap { $0 }.joined(separator: " ")
            let displayName = releaseName.isEmpty ? "" : "&dn=" + (releaseName.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")
            let magnet = hash.flatMap { $0.isEmpty ? nil : "magnet:?xt=urn:btih:\($0)\(displayName)" }
            let link = RawTorrent(
                url: torrent.url?.text,
                magnet: magnet,
                seed: torrent.seeds,
                seeds: torrent.seeds,
                peer: torrent.peers,
                peers: torrent.peers,
                size: torrent.size_bytes,
                filesize: torrent.size,
                quality: Loose(label)
            )
            // Keep every release, not just one per quality: YTS often lists
            // both a BluRay and a WEB release in the same resolution.
            group["\(label)#\(index)"] = Lenient(link)
        }
        torrents = group.isEmpty ? nil : Lenient([languageKey: Lenient(TorrentNode.group(group))])
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
            synopsis: raw.synopsis?.text.map(HTML.clean),
            runtime: raw.runtime?.int.flatMap { $0 > 0 ? $0 : nil },
            // 0 is what sources send for a title nobody has rated.
            rating: raw.rating?.value?.percentage?.double.flatMap { $0 > 0 ? $0 : nil },
            votes: raw.rating?.value?.votes?.int,
            certification: raw.certification?.text.flatMap { $0.isEmpty ? nil : $0 },
            posterURL: Self.image(raw.images?.value?.poster, base),
            fanartURL: Self.image(raw.images?.value?.fanart, base) ?? Self.image(raw.images?.value?.banner, base),
            // Slugs ("science-fiction") read as words; names ("Sci-Fi") stay.
            genres: (raw.genres?.list ?? []).map { $0 == $0.lowercased() ? $0.replacingOccurrences(of: "-", with: " ").capitalized : $0 },
            seasonCount: raw.num_seasons?.int,
            options: makeOptions(raw.torrents?.value, release: ReleaseInfo(title: title, year: year), artwork: Self.image(raw.images?.value?.poster, base)),
            base: base
        )
    }

    func with(options: [FeedOption]) -> APITitle {
        APITitle(id: id, type: type, title: title, year: year, synopsis: synopsis, runtime: runtime, rating: rating,
                 votes: votes, certification: certification, posterURL: posterURL, fanartURL: fanartURL,
                 genres: genres, seasonCount: seasonCount, options: options, base: base)
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
            title: raw.title?.text.flatMap { $0.isEmpty ? nil : HTML.clean($0) } ?? "Episode \(episode)",
            overview: raw.overview?.text.map(HTML.clean),
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
        case .torrent(let t):
            flat.append((t.quality?.text ?? key, nil, t))
        case .group(let g):
            for (quality, t) in g {
                if let torrent = t.value {
                    flat.append((torrent.quality?.text ?? quality, key, torrent))
                }
            }
        case nil:
            break
        }
    }
    let languages = Set(flat.compactMap(\.language))
    // Episodes repeat their default quality under "0"; keep the named one.
    flat.sort { ($0.quality == "0" ? 1 : 0, $0.quality) < ($1.quality == "0" ? 1 : 0, $1.quality) }
    var seen = Set<String>()
    var options: [FeedOption] = []
    for (quality, language, t) in flat {
        guard let rawLink = t.link?.trimmingCharacters(in: .whitespacesAndNewlines), !rawLink.isEmpty else { continue }
        let magnetString = t.magnet?.trimmingCharacters(in: .whitespacesAndNewlines)
        let urlString = t.url?.trimmingCharacters(in: .whitespacesAndNewlines)
        // The older schema sometimes puts a magnet in `url`.
        let urlIsMagnet = urlString?.lowercased().hasPrefix("magnet:") == true
        let magnet: String? = magnetString?.lowercased().hasPrefix("magnet:") == true
            ? magnetString
            : (urlIsMagnet ? urlString : nil)
        let torrentURL: URL? = urlIsMagnet ? nil : urlString.flatMap { URL(string: $0) }
        guard magnet != nil || torrentURL != nil else { continue }
        let id = torrentURL?.absoluteString ?? magnet ?? rawLink
        guard seen.insert(id).inserted else { continue }
        let parsed = magnet.flatMap { try? MagnetLink(string: $0) }
        let label = quality == "0" ? "SD" : quality
        var name = parsed?.displayName ?? torrentURL?.lastPathComponent ?? "\(fallbackName ?? release.title) \(label)"
        if languages.count > 1, let language { name += " · \(language.uppercased())" }
        var r = release
        r.quality = label
        let entry = FeedEntry(
            id: id,
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
