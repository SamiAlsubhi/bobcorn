import Foundation
import Observation
import TorrentKit

// MARK: - Sources

/// A source the user added in Settings: an RSS or Atom feed listing torrents,
/// optionally with a search URL with `{query}` in it, or a catalog API that
/// serves movies and shows as JSON.
struct CustomSource: Codable, Identifiable, Hashable {
    enum Kind: String, Codable, CaseIterable {
        case feed, api
    }

    var id = UUID()
    var kind: Kind = .feed
    var name: String
    /// The feed's address, or the API's base URL.
    var feedURL: String
    var searchURL: String = ""
    var enabled = true

    var feed: URL? { kind == .feed ? Self.validURL(feedURL) : nil }
    var canSearch: Bool {
        kind == .api || searchURL.contains("{query}") && Self.validURL(searchURL.replacingOccurrences(of: "{query}", with: "x")) != nil
    }

    /// A catalog API's base URL, without a trailing slash.
    var apiBase: URL? {
        guard kind == .api, let url = Self.validURL(feedURL), url.scheme != "file" else { return nil }
        var s = url.absoluteString
        while s.hasSuffix("/") { s.removeLast() }
        return URL(string: s)
    }

    func search(_ query: String) -> URL? {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=?#/")
        let encoded = query.addingPercentEncoding(withAllowedCharacters: allowed) ?? query
        return Self.validURL(searchURL.replacingOccurrences(of: "{query}", with: encoded))
    }

    static func validURL(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased() else { return nil }
        if scheme == "file" { return url }
        guard scheme == "http" || scheme == "https", url.host?.isEmpty == false else { return nil }
        return url
    }
}

extension CustomSource {
    /// Sources saved before catalog APIs existed have no kind.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        kind = try c.decodeIfPresent(Kind.self, forKey: .kind) ?? .feed
        name = try c.decode(String.self, forKey: .name)
        feedURL = try c.decode(String.self, forKey: .feedURL)
        searchURL = try c.decodeIfPresent(String.self, forKey: .searchURL) ?? ""
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    }
}

@MainActor
@Observable
final class SourceStore {
    private static let key = "customSources"
    private(set) var sources: [CustomSource] = []

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let decoded = try? JSONDecoder().decode([CustomSource].self, from: data) {
            sources = decoded
        }
    }

    var enabled: [CustomSource] { sources.filter(\.enabled) }

    func upsert(_ source: CustomSource) {
        if let i = sources.firstIndex(where: { $0.id == source.id }) {
            sources[i] = source
        } else {
            sources.append(source)
        }
        save()
    }

    func remove(_ id: UUID) {
        sources.removeAll { $0.id == id }
        save()
    }

    func setEnabled(_ id: UUID, _ on: Bool) {
        guard let i = sources.firstIndex(where: { $0.id == id }) else { return }
        sources[i].enabled = on
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(sources) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }
}

// MARK: - Feed entries

/// One torrent listed by a feed.
struct FeedEntry: Identifiable, Hashable {
    let id: String
    let title: String
    let magnet: String?
    let torrentURL: URL?
    let infoHash: String?
    let size: Int64?
    let seeders: Int?
    let leechers: Int?
    let published: Date?
    let summary: String?
    let imageURL: URL?
    let category: String?
}

enum FeedError: LocalizedError {
    case badURL
    case notAFeed
    case http(Int)

    var errorDescription: String? {
        switch self {
        case .badURL: return "That isn't a valid feed URL."
        case .notAFeed: return "That address didn't return an RSS or Atom feed."
        case .http(let code): return "The source answered HTTP \(code)."
        }
    }
}

/// RSS 2.0 and Atom, including the torrent extensions trackers and indexers
/// use (Torznab/Newznab `attr`, the `torrent:` namespace, and look-alikes).
final class FeedParser: NSObject, XMLParserDelegate {
    private struct Draft {
        var title = ""
        var links: [String] = []
        var enclosures: [(url: String, type: String, length: Int64?)] = []
        var guid: String?
        var summary: String?
        var published: Date?
        var size: Int64?
        var seeders: Int?
        var leechers: Int?
        var totalPeers: Int?
        var infoHash: String?
        var magnet: String?
        var image: String?
        var category: String?
    }

    private var entries: [FeedEntry] = []
    private var draft: Draft?
    private var text = ""
    private var sawFeed = false

    static func parse(_ data: Data) throws -> [FeedEntry] {
        let delegate = FeedParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldResolveExternalEntities = false
        let ok = parser.parse()
        guard delegate.sawFeed else { throw FeedError.notAFeed }
        if !ok && delegate.entries.isEmpty { throw parser.parserError ?? FeedError.notAFeed }
        return delegate.entries
    }

    private static func local(_ name: String) -> String {
        (name.split(separator: ":").last.map(String.init) ?? name).lowercased()
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes: [String: String] = [:]) {
        let name = Self.local(elementName)
        text = ""
        if name == "rss" || name == "feed" || name == "rdf" { sawFeed = true }
        if name == "item" || name == "entry" {
            draft = Draft()
            return
        }
        guard var d = draft else { return }
        defer { draft = d }
        let attrs = Dictionary(uniqueKeysWithValues: attributes.map { ($0.key.lowercased(), $0.value) })
        switch name {
        case "enclosure":
            if let url = attrs["url"] {
                d.enclosures.append((url, attrs["type"] ?? "", attrs["length"].flatMap { Int64($0) }))
            }
        case "link":
            if let href = attrs["href"] {
                let rel = attrs["rel"] ?? ""
                let type = attrs["type"] ?? ""
                if rel == "enclosure" || type.contains("bittorrent") {
                    d.enclosures.append((href, type, attrs["length"].flatMap { Int64($0) }))
                } else if type.hasPrefix("image") {
                    d.image = d.image ?? href
                } else {
                    d.links.append(href)
                }
            }
        case "attr":
            guard let key = attrs["name"]?.lowercased(), let value = attrs["value"] else { break }
            switch key {
            case "seeders": d.seeders = Int(value)
            case "leechers": d.leechers = Int(value)
            case "peers": d.totalPeers = Int(value)
            case "size": d.size = Int64(value)
            case "infohash": d.infoHash = value
            case "magneturl": d.magnet = value
            case "coverurl", "poster": d.image = value
            default: break
            }
        case "thumbnail":
            if let url = attrs["url"] { d.image = d.image ?? url }
        case "content":
            if let url = attrs["url"], attrs["medium"] == "image" || (attrs["type"] ?? "").hasPrefix("image") {
                d.image = d.image ?? url
            }
        case "image":
            if let href = attrs["href"] ?? attrs["url"] { d.image = d.image ?? href }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        text += String(decoding: CDATABlock, as: UTF8.self)
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let name = Self.local(elementName)
        if name == "item" || name == "entry" {
            if let d = draft, let entry = finish(d) { entries.append(entry) }
            draft = nil
            return
        }
        guard var d = draft else { return }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        text = ""
        guard !value.isEmpty else { return }
        defer { draft = d }
        switch name {
        case "title":
            if d.title.isEmpty { d.title = value }
        case "link":
            d.links.append(value)
        case "guid", "id":
            d.guid = value
        case "description", "summary", "content", "encoded":
            if (d.summary ?? "").isEmpty { d.summary = value }
        case "pubdate", "published", "updated", "date":
            d.published = Self.parseDate(value) ?? d.published
        case "size", "contentlength":
            d.size = Self.parseSize(value) ?? d.size
        case "seeds", "seeders":
            d.seeders = Int(value) ?? d.seeders
        case "peers", "leechers":
            d.leechers = Int(value) ?? d.leechers
        case "infohash":
            d.infoHash = value
        case "magneturi", "magnet", "magnetlink":
            d.magnet = value
        case "category":
            d.category = value
        default:
            break
        }
    }

    private func finish(_ d: Draft) -> FeedEntry? {
        let candidates = d.enclosures.map(\.url) + d.links + (d.guid.map { [$0] } ?? [])
        let magnet = d.magnet ?? candidates.first { $0.lowercased().hasPrefix("magnet:") }

        func isTorrentPath(_ s: String) -> Bool {
            (URL(string: s)?.path.lowercased() ?? s.lowercased()).hasSuffix(".torrent")
        }
        var torrent: String? =
            d.enclosures.first { $0.type.contains("bittorrent") }?.url
            ?? candidates.first { !$0.lowercased().hasPrefix("magnet:") && isTorrentPath($0) }
        if torrent == nil && magnet == nil {
            // An archive.org item page: every item has a torrent at a fixed place.
            if let link = d.links.first, let url = URL(string: link), url.host?.hasSuffix("archive.org") == true,
               url.pathComponents.count >= 3, url.pathComponents[1] == "details" {
                let id = url.pathComponents[2]
                torrent = "https://archive.org/download/\(id)/\(id)_archive.torrent"
            } else {
                // Indexers often link a download endpoint with no extension.
                torrent = d.enclosures.first { !$0.type.hasPrefix("image") && !$0.type.hasPrefix("video") && !$0.type.hasPrefix("audio") }?.url
                    ?? d.links.first { $0.lowercased().contains("download") || Self.hexHash(in: $0) != nil }
            }
        }
        let torrentURL = torrent.flatMap { URL(string: $0) }
        guard magnet != nil || torrentURL != nil else { return nil }

        var hash = d.infoHash?.lowercased()
        if hash == nil, let magnet, let m = try? MagnetLink(string: magnet) { hash = m.infoHashHex }
        if hash == nil, let torrent { hash = Self.hexHash(in: torrent) }

        var image = d.image
        if image == nil, let summary = d.summary,
           let range = summary.range(of: #"<img[^>]+src=["']([^"']+)["']"#, options: .regularExpression) {
            let tag = String(summary[range])
            if let src = tag.range(of: #"(?<=src=["'])[^"']+"#, options: .regularExpression) {
                image = String(tag[src]).replacingOccurrences(of: "&amp;", with: "&")
            }
        }

        let leechers = d.leechers ?? {
            guard let total = d.totalPeers, let s = d.seeders else { return nil }
            return max(0, total - s)
        }()
        let title = d.title.isEmpty ? (torrentURL?.lastPathComponent ?? "Untitled") : d.title
        return FeedEntry(
            id: d.guid ?? magnet ?? torrent ?? title,
            title: title,
            magnet: magnet,
            torrentURL: torrentURL,
            infoHash: hash,
            size: d.size ?? d.enclosures.compactMap(\.length).first { $0 > 0 },
            seeders: d.seeders,
            leechers: leechers,
            published: d.published,
            summary: d.summary,
            imageURL: image.flatMap { URL(string: $0) },
            category: d.category
        )
    }

    private static func hexHash(in s: String) -> String? {
        guard let r = s.range(of: #"(?<![0-9a-fA-F])[0-9a-fA-F]{40}(?![0-9a-fA-F])"#, options: .regularExpression) else { return nil }
        return s[r].lowercased()
    }

    private static let rfc822: [DateFormatter] = ["EEE, dd MMM yyyy HH:mm:ss Z", "EEE, dd MMM yyyy HH:mm Z", "dd MMM yyyy HH:mm:ss Z", "EEE, dd MMM yyyy HH:mm:ss zzz"].map {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = $0
        return f
    }

    static func parseDate(_ s: String) -> Date? {
        let iso = ISO8601DateFormatter()
        if let d = iso.date(from: s) { return d }
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: s) { return d }
        for f in rfc822 { if let d = f.date(from: s) { return d } }
        return nil
    }

    /// "1234567", "1.4 GiB", "700 MB".
    static func parseSize(_ s: String) -> Int64? {
        if let n = Int64(s) { return n }
        let parts = s.replacingOccurrences(of: ",", with: "").split(separator: " ")
        guard parts.count == 2, let n = Double(parts[0]) else { return nil }
        let unit = parts[1].uppercased()
        let power: Double
        switch unit {
        case "B": power = 0
        case "KB", "KIB": power = 1
        case "MB", "MIB": power = 2
        case "GB", "GIB": power = 3
        case "TB", "TIB": power = 4
        default: return nil
        }
        return Int64(n * pow(unit.contains("I") ? 1024 : 1000, power))
    }
}

// MARK: - Release names

/// What a torrent's name says about it: "Some.Film.1962.1080p.BluRay" or
/// "Some Show S02E05 720p".
struct ReleaseInfo: Hashable {
    var title: String
    var year: Int?
    var season: Int?
    var episode: Int?
    var quality: String?

    var episodeTag: String? {
        guard let season else { return nil }
        if let episode { return String(format: "S%02dE%02d", season, episode) }
        return "Season \(season)"
    }

    /// Sorts options by resolution.
    var qualityRank: Int { Int(quality?.dropLast() ?? "") ?? 0 }

    private static func regex(_ p: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: p, options: [.caseInsensitive])
    }

    private static let episodeRe = regex(#"\bS(\d{1,2})[ ._-]?E(\d{1,3})\b"#)
    private static let crossRe = regex(#"\b(\d{1,2})x(\d{2})\b"#)
    private static let seasonRe = regex(#"\b(?:S|Season ?)(\d{1,2})\b"#)
    private static let qualityRe = regex(#"\b(2160|1080|720|576|480|360)[pi]\b"#)
    private static let uhdRe = regex(#"\b(4K|UHD)\b"#)
    private static let yearRe = regex(#"[(\[]?\b(19[2-9]\d|20[0-4]\d)\b[)\]]?"#)
    private static let tagRe = regex(#"\b(WEB[- ]?DL|WEBRip|BluRay|BDRip|BRRip|HDTV|DVDRip|HDRip|x264|x265|HEVC|REPACK|PROPER|COMPLETE)\b"#)

    static func parse(_ raw: String) -> ReleaseInfo {
        var s = raw.trimmingCharacters(in: .whitespaces)
        for ext in [".torrent", ".mkv", ".mp4", ".avi", ".m4v"] where s.lowercased().hasSuffix(ext) {
            s = String(s.dropLast(ext.count))
        }
        s = s.replacingOccurrences(of: #"^\s*\[[^\]]*\]\s*"#, with: "", options: .regularExpression)
        // Scene names use dots or underscores for spaces.
        let sceneStyle = !s.contains(" ") || s.filter({ $0 == "." }).count > 2
        if sceneStyle {
            s = s.replacingOccurrences(of: ".", with: " ").replacingOccurrences(of: "_", with: " ")
        }
        let ns = s as NSString
        let all = NSRange(location: 0, length: ns.length)
        var info = ReleaseInfo(title: s)
        var cut = ns.length

        func int(_ m: NSTextCheckingResult, _ g: Int) -> Int? { Int(ns.substring(with: m.range(at: g))) }

        if let m = episodeRe.firstMatch(in: s, range: all) ?? crossRe.firstMatch(in: s, range: all) {
            info.season = int(m, 1)
            info.episode = int(m, 2)
            cut = min(cut, m.range.location)
        } else if let m = seasonRe.firstMatch(in: s, range: all), m.range.location > 0 {
            info.season = int(m, 1)
            cut = min(cut, m.range.location)
        }
        if let m = qualityRe.firstMatch(in: s, range: all) {
            info.quality = "\(ns.substring(with: m.range(at: 1)))p"
            cut = min(cut, m.range.location)
        } else if let m = uhdRe.firstMatch(in: s, range: all) {
            info.quality = "2160p"
            cut = min(cut, m.range.location)
        }
        if let m = yearRe.matches(in: s, range: all).first(where: { $0.range.location > 0 }) {
            info.year = int(m, 1)
            cut = min(cut, m.range.location)
        }
        // Words like "Complete" or "Web" are only release tags in scene names;
        // in a title written with spaces they are part of the title.
        if sceneStyle, let m = tagRe.firstMatch(in: s, range: all), m.range.location > 0 {
            cut = min(cut, m.range.location)
        }
        let title = ns.substring(to: cut).trimmingCharacters(in: CharacterSet(charactersIn: " -–([._,:;|"))
        info.title = title.isEmpty ? s : title
        return info
    }
}

// MARK: - Titles

/// One quality of a title: a single torrent.
struct FeedOption: Identifiable, Hashable {
    let entry: FeedEntry
    let release: ReleaseInfo
    var id: String { entry.id }
    var qualityLabel: String { release.quality ?? "Unknown quality" }
}

/// A film or episode as shown in the grid, with every torrent of it a feed
/// lists grouped as its options.
struct FeedTitle: Identifiable, Hashable {
    let id: String
    let title: String
    let year: Int?
    let episodeTag: String?
    var options: [FeedOption]

    var imageURL: URL? { options.lazy.compactMap(\.entry.imageURL).first }
    var summary: String? { options.lazy.compactMap(\.entry.summary).first { !$0.isEmpty } }
    var published: Date? { options.compactMap(\.entry.published).max() }
    var bestSeeders: Int? { options.compactMap(\.entry.seeders).max() }
    var qualities: [String] {
        Array(Set(options.compactMap(\.release.quality))).sorted { (Int($0.dropLast()) ?? 0) > (Int($1.dropLast()) ?? 0) }
    }

    var displayTitle: String {
        [title, episodeTag].compactMap { $0 }.joined(separator: " · ")
    }

    static func group(_ entries: [FeedEntry]) -> [FeedTitle] {
        var order: [String] = []
        var groups: [String: FeedTitle] = [:]
        for e in entries {
            let r = ReleaseInfo.parse(e.title)
            let norm = r.title.lowercased().filter { $0.isLetter || $0.isNumber }
            let key = [norm, r.year.map(String.init) ?? "", r.episodeTag ?? ""].joined(separator: "|")
            let option = FeedOption(entry: e, release: r)
            if groups[key] == nil {
                order.append(key)
                groups[key] = FeedTitle(id: key, title: r.title, year: r.year, episodeTag: r.episodeTag, options: [option])
            } else if groups[key]?.options.contains(where: { $0.id == option.id }) == false {
                groups[key]?.options.append(option)
            }
        }
        return order.compactMap { groups[$0] }
    }
}

enum FeedSort: String, CaseIterable, Identifiable {
    case seeds, newest, title

    var id: String { rawValue }

    var title: String {
        switch self {
        case .seeds: return "Seeds"
        case .newest: return "Newest"
        case .title: return "Title"
        }
    }

    func sorted(_ titles: [FeedTitle]) -> [FeedTitle] {
        switch self {
        case .seeds:
            // Feeds without seed counts keep their own order.
            return titles.enumerated().sorted { a, b in
                let sa = a.element.bestSeeders ?? -1
                let sb = b.element.bestSeeders ?? -1
                return sa != sb ? sa > sb : a.offset < b.offset
            }.map(\.element)
        case .newest:
            return titles.enumerated().sorted { a, b in
                let da = a.element.published ?? .distantPast
                let db = b.element.published ?? .distantPast
                return da != db ? da > db : a.offset < b.offset
            }.map(\.element)
        case .title:
            return titles.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        }
    }
}

// MARK: - Fetching

enum FeedClient {
    private static let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 30
        c.httpAdditionalHeaders = ["User-Agent": "Bobcorn/1.0 (macOS)"]
        return URLSession(configuration: c)
    }()

    static func entries(from url: URL) async throws -> [FeedEntry] {
        try FeedParser.parse(try await data(url))
    }

    static func data(_ url: URL) async throws -> Data {
        let (data, response) = try await session.data(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw FeedError.http(http.statusCode)
        }
        return data
    }

    private static let torrentCache = TorrentFileCache()

    /// A .torrent file, kept so checking its seeds and then playing it
    /// downloads it once.
    static func torrent(_ url: URL) async throws -> Metainfo {
        if let hit = await torrentCache.get(url) { return hit }
        let meta = try Metainfo(data: try await data(url))
        await torrentCache.set(url, meta)
        return meta
    }
}

private actor TorrentFileCache {
    private var items: [URL: Metainfo] = [:]
    func get(_ url: URL) -> Metainfo? { items[url] }
    func set(_ url: URL, _ meta: Metainfo) {
        if items.count > 200 { items.removeAll() }
        items[url] = meta
    }
}

/// The listing behind the Sources tab.
@MainActor
@Observable
final class FeedBrowseModel {
    private(set) var titles: [FeedTitle] = []
    private(set) var entryCount = 0
    private(set) var isLoading = false
    private(set) var error: String?
    private(set) var source: CustomSource?
    private var task: Task<Void, Never>?

    private var loadedQuery: String?

    func load(_ source: CustomSource?, search: String, sort: FeedSort, force: Bool = false) {
        let query = search.trimmingCharacters(in: .whitespaces)
        // Both tabs show the same feed: fetched once.
        if !force, source == self.source, query == loadedQuery, error == nil, isLoading || !titles.isEmpty { return }
        task?.cancel()
        loadedQuery = query
        self.source = source
        titles = []
        entryCount = 0
        error = nil
        guard let source else {
            isLoading = false
            return
        }
        isLoading = true
        task = Task { [weak self] in
            do {
                let searching = !query.isEmpty && source.canSearch
                guard let url = searching ? source.search(query) : source.feed else { throw FeedError.badURL }
                var entries = try await FeedClient.entries(from: url)
                if !query.isEmpty && !searching {
                    let words = query.lowercased().split(separator: " ")
                    entries = entries.filter { e in words.allSatisfy { e.title.lowercased().contains($0) } }
                }
                guard let self, !Task.isCancelled else { return }
                self.entryCount = entries.count
                self.titles = sort.sorted(FeedTitle.group(entries))
                self.isLoading = false
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.error = error.localizedDescription
                self.isLoading = false
            }
        }
    }

    func resort(_ sort: FeedSort) {
        titles = sort.sorted(titles)
    }
}

/// Live seed counts from trackers, for torrents whose feed gives none.
@MainActor
@Observable
final class SeedCheck {
    private(set) var results: [String: TrackerScrape.Result] = [:]
    private(set) var pending: Set<String> = []
    private var task: Task<Void, Never>?

    func run(_ options: [FeedOption]) {
        let todo = options.filter { $0.entry.seeders == nil }
        pending = Set(todo.map(\.id))
        task = Task { [weak self] in
            await withTaskGroup(of: (String, TrackerScrape.Result?).self) { group in
                for o in todo {
                    group.addTask {
                        if let m = o.entry.magnet, var magnet = try? MagnetLink(string: m) {
                            if magnet.trackers.isEmpty { magnet.trackers = defaultPublicTrackers }
                            return (o.id, await TrackerScrape.scrape(magnet))
                        }
                        if let url = o.entry.torrentURL, let meta = try? await FeedClient.torrent(url) {
                            return (o.id, await TrackerScrape.scrape(meta))
                        }
                        return (o.id, nil)
                    }
                }
                for await (id, result) in group {
                    guard let self, !Task.isCancelled else { return }
                    self.pending.remove(id)
                    if let result { self.results[id] = result }
                }
            }
        }
    }

    func cancel() { task?.cancel() }

    func seeders(_ o: FeedOption) -> Int? { o.entry.seeders ?? results[o.id]?.seeders }
    func leechers(_ o: FeedOption) -> Int? { o.entry.leechers ?? results[o.id]?.leechers }

    /// Most seeds first; unknown last; then sharper, then bigger.
    func ordered(_ options: [FeedOption]) -> [FeedOption] {
        options.sorted { a, b in
            let sa = seeders(a) ?? -1
            let sb = seeders(b) ?? -1
            if sa != sb { return sa > sb }
            if a.release.qualityRank != b.release.qualityRank { return a.release.qualityRank > b.release.qualityRank }
            return (a.entry.size ?? 0) > (b.entry.size ?? 0)
        }
    }
}
