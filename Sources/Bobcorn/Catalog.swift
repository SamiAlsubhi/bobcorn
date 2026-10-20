import Foundation

/// The top-level tabs, each an Internet Archive collection of public-domain
/// or freely licensed film.
enum CatalogSection: String, CaseIterable, Identifiable, Codable {
    case movies, shows, animation, sources, myList

    var id: String { rawValue }

    var title: String {
        switch self {
        case .movies: return "Movies"
        case .shows: return "TV Shows"
        case .animation: return "Animation"
        case .sources: return "Sources"
        case .myList: return "My List"
        }
    }

    var collection: String? {
        switch self {
        case .movies: return "feature_films"
        case .shows: return "classic_tv"
        case .animation: return "animationandcartoons"
        case .sources, .myList: return nil
        }
    }

    var genres: [Genre] {
        switch self {
        case .movies:
            return [.all,
                    Genre("Action", "subject:(action)"),
                    Genre("Adventure", "subject:(adventure)"),
                    Genre("Comedy", "(collection:Comedy_Films OR subject:(comedy))"),
                    Genre("Crime", "subject:(crime)"),
                    Genre("Documentary", "subject:(documentary)"),
                    Genre("Drama", "subject:(drama)"),
                    Genre("Film Noir", "collection:Film_Noir"),
                    Genre("Horror", "(collection:SciFi_Horror AND subject:(horror)) OR subject:(horror)"),
                    Genre("Musical", "subject:(musical)"),
                    Genre("Mystery", "subject:(mystery)"),
                    Genre("Romance", "subject:(romance)"),
                    Genre("Sci-Fi", "(collection:SciFi_Horror OR subject:(\"science fiction\"))"),
                    Genre("Silent", "collection:silent_films"),
                    Genre("Thriller", "subject:(thriller)"),
                    Genre("War", "subject:(war)"),
                    Genre("Western", "subject:(western)")]
        case .shows:
            return [.all,
                    Genre("Adventure", "subject:(adventure)"),
                    Genre("Comedy", "subject:(comedy)"),
                    Genre("Crime", "subject:(crime)"),
                    Genre("Drama", "subject:(drama)"),
                    Genre("Kids", "subject:(kids)"),
                    Genre("Mystery", "subject:(mystery)"),
                    Genre("Sci-Fi", "subject:(sci-fi)"),
                    Genre("Western", "subject:(western)")]
        case .animation:
            return [.all,
                    Genre("Classic Cartoons", "collection:classic_cartoons"),
                    Genre("Fleischer Studios", "(fleischer)"),
                    Genre("Popeye", "(popeye)"),
                    Genre("Superman", "(superman)")]
        case .sources, .myList:
            return []
        }
    }
}

struct Genre: Hashable, Identifiable, Codable {
    let name: String
    let clause: String?

    var id: String { name }

    init(_ name: String, _ clause: String?) {
        self.name = name
        self.clause = clause
    }

    static let all = Genre("All", nil)
}

enum SortOption: String, CaseIterable, Identifiable, Codable {
    case popular, trending, rating, newest, added, title

    var id: String { rawValue }

    var title: String {
        switch self {
        case .popular: return "Popularity"
        case .trending: return "Trending"
        case .rating: return "Rating"
        case .newest: return "Year"
        case .added: return "Recently Added"
        case .title: return "Title"
        }
    }

    var sortClause: String {
        switch self {
        case .popular: return "downloads desc"
        case .trending: return "week desc"
        case .rating: return "avg_rating desc"
        case .newest: return "year desc"
        case .added: return "addeddate desc"
        case .title: return "titleSorter asc"
        }
    }
}

struct CatalogQuery: Hashable {
    var section: CatalogSection
    var genre: Genre
    var sort: SortOption
    var search: String

    var clause: String {
        var parts = ["mediatype:movies"]
        if let c = section.collection { parts.append("collection:\(c)") }
        if let g = genre.clause { parts.append("(\(g))") }
        // Ratings are sparse; ask for items that have enough of them.
        if sort == .rating { parts.append("num_reviews:[3 TO 100000]") }
        let words = search
            .components(separatedBy: CharacterSet.alphanumerics.union(.whitespaces).inverted).joined(separator: " ")
            .split(separator: " ").map(String.init)
        if !words.isEmpty {
            let terms = words.joined(separator: " AND ")
            parts.append("(title:(\(terms)) OR description:(\(terms)) OR subject:(\(terms)))")
        }
        return parts.joined(separator: " AND ")
    }
}

/// One title in a listing.
struct CatalogItem: Identifiable, Hashable, Codable {
    let id: String
    let title: String
    let year: Int?
    let rating: Double?
    let downloads: Int?
    let runtime: String?
    let subjects: [String]
    let section: CatalogSection

    var posterURL: URL { URL(string: "https://archive.org/services/img/\(id)")! }
    var pageURL: URL { URL(string: "https://archive.org/details/\(id)")! }
}

/// Everything the detail page shows, from the item's metadata.
struct ItemDetails {
    let item: CatalogItem
    let description: String
    let director: String?
    let language: String?
    let runtime: String?
    let year: Int?
    let genres: [String]
    let videos: [VideoGroup]
    let subtitles: [SubtitleFile]
    let torrentFile: String?
    let license: String?
    /// Data nodes holding the item, healthiest first. archive.org/download
    /// redirects to one of them, and not always to one that works.
    let servers: [String]
    let directory: String?

    var hasTorrent: Bool { torrentFile != nil }

    /// Every URL the file can be fetched from: each data node, then the
    /// redirecting /download URL.
    func urls(for file: String) -> [URL] {
        var out: [URL] = []
        if let directory {
            for host in servers {
                if let u = URL(string: "https://\(host)\(directory)/\(ArchiveClient.encodePath(file))") { out.append(u) }
            }
        }
        out.append(ArchiveClient.downloadURL(item.id, file))
        return out
    }

    var torrentURLs: [URL] { torrentFile.map { urls(for: $0) } ?? [] }

    /// BEP 19 bases on each data node; the torrent's own list can be stale.
    var webSeeds: [String] {
        guard let directory, let slash = directory.lastIndex(of: "/") else { return [] }
        let parent = directory[..<slash]
        return servers.map { "https://\($0)\(parent)/" }
    }
}

/// One film or episode, which may come in several encodings.
struct VideoGroup: Identifiable, Hashable {
    let id: String
    let title: String
    let variants: [VideoVariant]
    let duration: Double?

    /// The variant to play by default: the sharpest one AVPlayer can play.
    func preferred(dataSaver: Bool) -> VideoVariant? {
        let native = variants.filter(\.isNative)
        let pool = native.isEmpty ? variants : native
        let sorted = pool.sorted { ($0.height ?? 0, $0.size) < ($1.height ?? 0, $1.size) }
        return dataSaver ? sorted.first : sorted.last
    }
}

struct VideoVariant: Identifiable, Hashable {
    let name: String
    let format: String
    let size: Int64
    let height: Int?

    var id: String { name }
    var fileExtension: String { (name as NSString).pathExtension.lowercased() }
    var isNative: Bool { ["mp4", "m4v", "mov"].contains(fileExtension) }

    var qualityLabel: String {
        if let h = height, h > 0 {
            if h >= 1000 { return "1080p" }
            if h >= 700 { return "720p" }
            return "\(h)p"
        }
        if format.contains("512Kb") { return "240p" }
        return format
    }
}

struct SubtitleFile: Identifiable, Hashable {
    let name: String
    let label: String
    var id: String { name }
}

enum ArchiveClient {
    static let pageSize = 60

    private static let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 30
        c.httpAdditionalHeaders = ["User-Agent": "Bobcorn/1.0 (macOS)"]
        c.urlCache = URLCache(memoryCapacity: 16 << 20, diskCapacity: 64 << 20)
        return URLSession(configuration: c)
    }()

    static func search(_ query: CatalogQuery, page: Int) async throws -> (items: [CatalogItem], total: Int) {
        var c = URLComponents(string: "https://archive.org/advancedsearch.php")!
        var q = [URLQueryItem(name: "q", value: query.clause)]
        for f in ["identifier", "title", "year", "avg_rating", "downloads", "runtime", "subject"] {
            q.append(URLQueryItem(name: "fl[]", value: f))
        }
        q.append(URLQueryItem(name: "sort[]", value: query.sort.sortClause))
        q.append(URLQueryItem(name: "rows", value: String(pageSize)))
        q.append(URLQueryItem(name: "page", value: String(page)))
        q.append(URLQueryItem(name: "output", value: "json"))
        c.queryItems = q
        let (data, _) = try await session.data(from: c.url!)
        let decoded = try JSONDecoder().decode(SearchResponse.self, from: data)
        let items = decoded.response.docs.compactMap { doc -> CatalogItem? in
            guard let title = doc.title?.text, !title.isEmpty else { return nil }
            return CatalogItem(
                id: doc.identifier,
                title: title,
                year: doc.year?.int,
                rating: doc.avg_rating?.double,
                downloads: doc.downloads?.int,
                runtime: doc.runtime?.text,
                subjects: doc.subject?.list ?? [],
                section: query.section
            )
        }
        return (items, decoded.response.numFound)
    }

    static func details(for item: CatalogItem) async throws -> ItemDetails {
        let url = URL(string: "https://archive.org/metadata/\(item.id)")!
        let (data, _) = try await session.data(from: url)
        let meta = try JSONDecoder().decode(MetadataResponse.self, from: data)
        let m = meta.metadata ?? [:]
        let files = meta.files ?? []

        let videoExts: Set = ["mp4", "m4v", "mov", "mkv", "avi", "mpeg", "mpg", "ogv", "webm", "wmv", "flv"]
        var groups: [String: (title: String?, variants: [VideoVariant], duration: Double?)] = [:]
        var torrent: String?
        var subs: [SubtitleFile] = []
        for f in files {
            let ext = (f.name as NSString).pathExtension.lowercased()
            if f.format == "Archive BitTorrent" {
                torrent = f.name
            }
            if ext == "srt" || ext == "vtt" {
                let auto = f.name.contains(".asr.")
                subs.append(SubtitleFile(name: f.name, label: auto ? "English (auto-generated)" : prettyName(f.name)))
            }
            guard videoExts.contains(ext), !f.name.contains(".thumbs/"), (f.size?.int64 ?? 0) > 0 else { continue }
            let key = f.source == "derivative" ? (f.original ?? f.name) : f.name
            let variant = VideoVariant(name: f.name, format: f.format ?? ext.uppercased(), size: f.size?.int64 ?? 0, height: f.height?.int)
            var g = groups[key] ?? (nil, [], nil)
            g.variants.append(variant)
            if g.title == nil, let t = f.title?.text, !t.isEmpty { g.title = t }
            if g.duration == nil, let len = f.length?.text { g.duration = parseDuration(len) }
            groups[key] = g
        }
        let videos = groups.map { key, g in
            VideoGroup(id: key, title: g.title ?? prettyName(key), variants: g.variants, duration: g.duration)
        }
        .sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }

        let description = cleanHTML(m["description"]?.text ?? "")
        return ItemDetails(
            item: item,
            description: description,
            director: m["director"]?.text ?? m["creator"]?.text,
            language: m["language"]?.text,
            runtime: m["runtime"]?.text ?? item.runtime,
            year: m["year"]?.int ?? Int((m["date"]?.text ?? "").prefix(4)) ?? item.year,
            genres: (m["subject"]?.list ?? item.subjects).flatMap { $0.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) } }
                .filter { !$0.isEmpty }.prefix(6).map { $0.capitalized },
            videos: videos,
            subtitles: subs,
            torrentFile: torrent,
            license: m["licenseurl"]?.text,
            servers: Array(NSOrderedSet(array: (meta.workable_servers ?? []) + [meta.server, meta.d1, meta.d2].compactMap { $0 })) as? [String] ?? [],
            directory: meta.dir
        )
    }

    static func encodePath(_ file: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "?#;")
        return file.addingPercentEncoding(withAllowedCharacters: allowed) ?? file
    }

    static func downloadURL(_ identifier: String, _ file: String) -> URL {
        URL(string: "https://archive.org/download/\(identifier)/\(encodePath(file))")!
    }

    /// The first of `urls` that answers.
    static func fetchFirst(_ urls: [URL]) async throws -> Data {
        var lastError: Error = URLError(.fileDoesNotExist)
        for url in urls {
            do { return try await fetch(url) } catch { lastError = error }
        }
        throw lastError
    }

    static func fetch(_ url: URL) async throws -> Data {
        let (data, response) = try await session.data(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode) for \(url.lastPathComponent)"])
        }
        return data
    }

    static func prettyName(_ file: String) -> String {
        var base = ((file as NSString).lastPathComponent as NSString).deletingPathExtension
        for suffix in [".asr", "_512kb", "_edit", ".ia"] where base.hasSuffix(suffix) {
            base = String(base.dropLast(suffix.count))
        }
        return base.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
            .split(separator: " ").joined(separator: " ")
    }

    static func parseDuration(_ s: String) -> Double? {
        if let d = Double(s) { return d }
        let parts = s.split(separator: ":").compactMap { Double($0) }
        guard !parts.isEmpty else { return nil }
        return parts.reduce(0) { $0 * 60 + $1 }
    }

    static func cleanHTML(_ html: String) -> String {
        var s = html
        for br in ["<br>", "<br/>", "<br />", "</p>", "</div>"] {
            s = s.replacingOccurrences(of: br, with: "\n", options: .caseInsensitive)
        }
        s = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        let entities = ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&apos;": "'", "&nbsp;": " "]
        for (k, v) in entities { s = s.replacingOccurrences(of: k, with: v) }
        s = s.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Wire formats

/// The search API returns a field as a string, a number or a list depending
/// on the item, so every field is decoded leniently.
struct Loose: Decodable {
    let values: [String]

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) {
            values = [s]
        } else if let d = try? c.decode(Double.self) {
            values = [d == d.rounded() ? String(Int(d)) : String(d)]
        } else if let list = try? c.decode([Loose].self) {
            values = list.flatMap(\.values)
        } else {
            values = []
        }
    }

    var text: String? { values.first }
    var list: [String] { values }
    var int: Int? { values.first.flatMap { Int($0) ?? Double($0).map { Int($0) } } }
    var int64: Int64? { values.first.flatMap { Int64($0) } }
    var double: Double? { values.first.flatMap { Double($0) } }
}

private struct SearchResponse: Decodable {
    struct Body: Decodable {
        let numFound: Int
        let docs: [Doc]
    }

    struct Doc: Decodable {
        let identifier: String
        let title: Loose?
        let year: Loose?
        let avg_rating: Loose?
        let downloads: Loose?
        let runtime: Loose?
        let subject: Loose?
    }

    let response: Body
}

private struct MetadataResponse: Decodable {
    struct File: Decodable {
        let name: String
        let format: String?
        let source: String?
        let original: String?
        let size: Loose?
        let height: Loose?
        let length: Loose?
        let title: Loose?
    }

    let metadata: [String: Loose]?
    let files: [File]?
    let server: String?
    let d1: String?
    let d2: String?
    let dir: String?
    let workable_servers: [String]?
}
