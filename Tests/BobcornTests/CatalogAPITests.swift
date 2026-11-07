import CryptoKit
import Network
import XCTest
@testable import Bobcorn
@testable import TorrentKit

final class CatalogAPITests: XCTestCase {
    private let base = URL(string: "https://api.example")!
    private let hash1 = String(repeating: "a", count: 40)
    private let hash2 = String(repeating: "b", count: 40)

    private func data(_ json: String) -> Data { Data(json.utf8) }

    /// The single-item response from the API's documentation.
    func testDecodesDocumentedMovie() throws {
        let json = """
        [{"_id": "tt0468569", "imdb_id": "tt0468569", "title": "Example Media Title", "year": "2026",
          "synopsis": "A brief overview.", "runtime": "120", "rating": {"percentage": 85, "votes": 50000},
          "images": {"poster": "https://domain.com/p.jpg", "fanart": "https://domain.com/f.jpg"},
          "genres": ["Action", "Sci-Fi"],
          "torrents": {"en": {
            "1080p": {"url": "magnet:?xt=urn:btih:\(hash1)&dn=Title+1080p", "seed": 350, "peer": 80, "size": 2147483648, "filesize": "2.00 GB"},
            "720p": {"url": "magnet:?xt=urn:btih:\(hash2)&dn=Title+720p", "seed": 150, "peer": 40, "size": 1073741824, "filesize": "1.00 GB"}}}}]
        """
        let titles = try APIClient.titles(from: data(json), type: .movies, base: base)
        XCTAssertEqual(titles.count, 1)
        let t = try XCTUnwrap(titles.first)
        XCTAssertEqual(t.id, "tt0468569")
        XCTAssertEqual(t.year, 2026)
        XCTAssertEqual(t.runtime, 120)
        XCTAssertEqual(t.rating, 85)
        XCTAssertEqual(t.stars, 4.25)
        XCTAssertEqual(t.votes, 50000)
        XCTAssertEqual(t.genres, ["Action", "Sci-Fi"])
        XCTAssertEqual(t.posterURL?.absoluteString, "https://domain.com/p.jpg")
        XCTAssertEqual(t.qualities, ["1080p", "720p"])

        let hd = try XCTUnwrap(t.options.first { $0.release.quality == "1080p" })
        XCTAssertEqual(hd.entry.title, "Title 1080p")
        XCTAssertEqual(hd.entry.infoHash, hash1)
        XCTAssertEqual(hd.entry.seeders, 350)
        XCTAssertEqual(hd.entry.leechers, 80)
        XCTAssertEqual(hd.entry.size, 2147483648)
        XCTAssertEqual(t.options.best()?.id, hd.id)
    }

    /// A show's detail is a bare object. Episodes say seeds and peers, repeat
    /// their default quality under "0", and can be listed twice.
    func testDecodesShowEpisodes() throws {
        let listed = try XCTUnwrap(APIClient.titles(from: data("""
            [{"imdb_id": "tt0903747", "title": "Example Show", "num_seasons": 2}]
            """), type: .shows, base: base).first)
        XCTAssertEqual(listed.seasonCount, 2)
        XCTAssertTrue(listed.options.isEmpty)

        let json = """
        {"imdb_id": "tt0903747", "title": "Example Show", "year": 2008,
         "episodes": [
           {"season": 2, "episode": 1, "title": "Later", "first_aired": 1250000000,
            "torrents": {"720p": {"url": "magnet:?xt=urn:btih:\(hash2)", "seeds": 9, "peers": 1}}},
           {"season": "1", "episode": "2", "title": "", "first_aired": 0, "torrents": null},
           {"season": 1, "episode": 1, "title": "Pilot", "first_aired": -100000000,
            "torrents": {"0": {"url": "magnet:?xt=urn:btih:\(hash1)", "seeds": 30, "peers": 4},
                         "480p": {"url": "magnet:?xt=urn:btih:\(hash1)", "seeds": 30, "peers": 4},
                         "720p": {"url": "https://files.example/pilot.torrent", "seeds": 12}}},
           {"season": 1, "episode": 1, "title": "Pilot", "torrents": {}},
           {"title": "No numbers"}
         ]}
        """
        let d = try APIClient.details(from: data(json), listed: listed, base: base)
        XCTAssertEqual(d.episodes.map(\.tag), ["S01E01", "S01E02", "S02E01"])
        XCTAssertEqual(d.seasons, [1, 2])

        let pilot = d.episodes[0]
        XCTAssertEqual(pilot.options.map(\.qualityLabel).sorted(), ["480p", "720p"])
        XCTAssertNotNil(pilot.aired)
        let file = try XCTUnwrap(pilot.options.first { $0.release.quality == "720p" })
        XCTAssertNil(file.entry.magnet)
        XCTAssertEqual(file.entry.link, "https://files.example/pilot.torrent")
        XCTAssertEqual(file.entry.title, "pilot.torrent")
        XCTAssertEqual(pilot.options.best(preferring: "720p")?.id, file.id)
        XCTAssertEqual(d.key(pilot), "api:tt0903747:s1e1")

        XCTAssertEqual(d.episodes[1].title, "Episode 2")
        XCTAssertNil(d.episodes[1].aired)
        XCTAssertTrue(d.episodes[1].options.isEmpty)
    }

    /// One malformed title doesn't sink the page, and odd field types decode.
    func testPagesDecodeLeniently() throws {
        let json = """
        [{"imdb_id": "tt1", "title": "Fine", "year": 1999, "runtime": 95, "rating": 7.1,
          "images": {"poster": "/img/tt1.jpg"}, "torrents": ["unexpected"]},
         {"imdb_id": "tt2"},
         {"_id": "tt3", "title": "Only an _id", "images": {"poster": "images/posterholder.png"},
          "torrents": {"en": {"1080p": null, "720p": {"url": "magnet:?xt=urn:btih:\(hash1)", "seed": "12", "filesize": "700 MB"}}}},
         "movies/2"]
        """
        let titles = try APIClient.titles(from: data(json), type: .movies, base: URL(string: "https://api.example/v2")!)
        XCTAssertEqual(titles.map(\.id), ["tt1", "tt3"])
        XCTAssertEqual(titles[0].year, 1999)
        XCTAssertEqual(titles[0].runtime, 95)
        XCTAssertNil(titles[0].rating)
        XCTAssertEqual(titles[0].posterURL?.absoluteString, "https://api.example/img/tt1.jpg")
        XCTAssertTrue(titles[0].options.isEmpty)
        XCTAssertNil(titles[1].posterURL)
        XCTAssertEqual(titles[1].options.first?.entry.seeders, 12)
        XCTAssertEqual(titles[1].options.first?.entry.size, 700_000_000)
    }

    /// YTS wraps its list in `data.movies`, rates out of ten, and puts every
    /// torrent in a flat array. It often has two releases in one resolution.
    func testDecodesYTSList() throws {
        let json = """
        {"status": "ok", "status_message": "Query was successful", "data": {
          "movie_count": 2, "limit": 50, "page_number": 1, "movies": [
            {"id": 123, "imdb_code": "tt0111161", "title": "Example Film", "title_long": "Example Film (1994)", "year": 1994,
             "rating": 8.7, "runtime": 142, "genres": ["Drama"],
             "summary": "Short.", "synopsis": "A longer synopsis.", "mpa_rating": "R", "language": "en",
             "small_cover_image": "https://img.example/s.jpg",
             "medium_cover_image": "https://img.example/m.jpg",
             "large_cover_image": "https://img.example/l.jpg",
             "background_image": "https://img.example/bg.jpg",
             "background_image_original": "https://img.example/bg-o.jpg",
             "torrents": [
               {"url": "https://yts.example/torrent/aaa.torrent", "hash": "\(hash1)", "quality": "720p", "type": "bluray",
                "seeds": 12, "peers": 3, "size": "700 MB", "size_bytes": 700000000},
               {"url": "https://yts.example/torrent/bbb.torrent", "hash": "\(hash2)", "quality": "1080p", "type": "web",
                "seeds": 30, "peers": 4, "size": "1.4 GB", "size_bytes": 1400000000},
               {"url": "https://yts.example/torrent/ccc.torrent", "hash": "\(hash1)", "quality": "720p", "type": "web",
                "seeds": 5, "peers": 1, "size": "650 MB", "size_bytes": 650000000}
             ]}
          ]}}
        """
        let titles = try APIClient.titles(from: data(json), type: .movies, base: URL(string: "https://yts.example")!)
        XCTAssertEqual(titles.count, 1)
        let t = try XCTUnwrap(titles.first)
        XCTAssertEqual(t.id, "tt0111161")
        XCTAssertEqual(t.title, "Example Film")
        XCTAssertEqual(t.year, 1994)
        XCTAssertEqual(t.runtime, 142)
        XCTAssertEqual(t.rating, 87)
        XCTAssertNil(t.votes)
        XCTAssertEqual(t.certification, "R")
        XCTAssertEqual(t.genres, ["Drama"])
        XCTAssertEqual(t.posterURL?.absoluteString, "https://img.example/l.jpg")
        XCTAssertEqual(t.fanartURL?.absoluteString, "https://img.example/bg-o.jpg")
        XCTAssertEqual(t.qualities, ["1080p", "720p"])
        XCTAssertEqual(t.options.count, 3)
        XCTAssertEqual(t.options.compactMap(\.release.quality).sorted(), ["1080p", "720p", "720p"])

        let hd = try XCTUnwrap(t.options.first { $0.release.quality == "1080p" })
        XCTAssertEqual(hd.entry.seeders, 30)
        XCTAssertEqual(hd.entry.leechers, 4)
        XCTAssertEqual(hd.entry.size, 1_400_000_000)
        XCTAssertEqual(hd.entry.torrentURL?.absoluteString, "https://yts.example/torrent/bbb.torrent")
        // The .torrent URL ends in a hash, so the name comes from the magnet,
        // and the release type tells the two 720p releases apart.
        XCTAssertEqual(hd.entry.magnet, "magnet:?xt=urn:btih:\(hash2)&dn=Example%20Film%20%281994%29%201080p%20WEB")
        XCTAssertEqual(hd.entry.title, "Example Film (1994) 1080p WEB")
        XCTAssertEqual(t.options.filter { $0.release.quality == "720p" }.map(\.entry.title).sorted(),
                       ["Example Film (1994) 720p BluRay", "Example Film (1994) 720p WEB"])
    }

    /// A search with no results, or a page past the end, has a movie_count and
    /// no movies at all.
    func testYTSEmptyPageIsEmpty() throws {
        let json = """
        {"status": "ok", "status_message": "Query was successful", "data": {"movie_count": 0, "limit": 50, "page_number": 1}}
        """
        XCTAssertEqual(try APIClient.titles(from: data(json), type: .movies, base: base).count, 0)
    }

    /// A source that doesn't answer while its kind is worked out is asked
    /// again next time, not taken for the original format.
    func testWorksOutASourceAgainAfterNoAnswer() async throws {
        let movies = """
        {"status": "ok", "data": {"movie_count": 1, "movies": [{"id": 1, "imdb_code": "tt0111161", "title": "Example Film", "year": 1994}]}}
        """
        let server = try LoopbackServer { path in path.contains("list_movies.json") ? (200, movies) : (404, "") }
        let base = try await server.start()
        defer { server.stop() }
        let query = APIQuery(sourceID: UUID(), base: base, type: .movies, genre: .all, sort: .trending, search: "")

        do {
            _ = try await APIClient.page(query, page: 1)
            XCTFail("expected no answer")
        } catch {}
        server.answering = true
        let titles = try await APIClient.page(query, page: 1)
        XCTAssertEqual(titles.map(\.id), ["tt0111161"])
    }

    /// YTS details use `data.movie` and `description_intro` rather than the
    /// list's `synopsis`.
    func testDecodesYTSDetail() throws {
        let listed = try XCTUnwrap(APIClient.titles(from: data("""
            {"status": "ok", "data": {"movies": [
              {"id": 123, "imdb_code": "tt0111161", "title": "Example Film", "year": 1994}
            ]}}
            """), type: .movies, base: base).first)

        let json = """
        {"status": "ok", "data": {"movie": {
          "id": 123, "imdb_code": "tt0111161", "title": "Example Film", "year": 1994,
          "rating": 9.3, "runtime": 142, "genres": ["Drama"],
          "description_intro": "The intro.", "description_full": "The whole synopsis.",
          "mpa_rating": "R", "language": "en",
          "large_cover_image": "https://img.example/l.jpg",
          "background_image_original": "https://img.example/bg-o.jpg",
          "torrents": [
            {"url": "https://yts.example/torrent/aaa.torrent", "hash": "\(hash1)", "quality": "720p",
             "seeds": 12, "peers": 3, "size": "700 MB", "size_bytes": 700000000}
          ]
        }}}
        """
        let d = try APIClient.details(from: data(json), listed: listed, base: base)
        XCTAssertEqual(d.title.id, "tt0111161")
        XCTAssertEqual(d.title.rating, 93)
        XCTAssertEqual(d.title.synopsis, "The intro.")
        XCTAssertEqual(d.title.options.count, 1)
        XCTAssertTrue(d.episodes.isEmpty)
    }

    func testYTSURLs() {
        let base = URL(string: "https://yts.example")!
        let query = APIQuery(sourceID: UUID(), base: base, type: .movies,
                             genre: Genre("Sci-Fi", "sci-fi"), sort: .rating, search: "matrix")
        let list = try! XCTUnwrap(APIClient.ytsListURL(root: base.appendingPathComponent("api/v2"), query: query, page: 2))
        let items = URLComponents(url: list, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertEqual(list.path, "/api/v2/list_movies.json")
        XCTAssertEqual(items.first { $0.name == "page" }?.value, "2")
        XCTAssertEqual(items.first { $0.name == "limit" }?.value, "50")
        XCTAssertEqual(items.first { $0.name == "sort_by" }?.value, "rating")
        XCTAssertEqual(items.first { $0.name == "order_by" }?.value, "desc")
        XCTAssertEqual(items.first { $0.name == "genre" }?.value, "Sci-Fi")
        XCTAssertEqual(items.first { $0.name == "query_term" }?.value, "matrix")

        let title = APITitle(id: "tt0111161", type: .movies, title: "Example Film", year: 1994, synopsis: nil,
                             runtime: nil, rating: nil, votes: nil, certification: nil, posterURL: nil,
                             fanartURL: nil, genres: [], seasonCount: nil, options: [], base: base)
        let detail = try! XCTUnwrap(APIClient.ytsDetailURL(root: base.appendingPathComponent("api/v2"), title: title))
        let dItems = URLComponents(url: detail, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertEqual(detail.path, "/api/v2/movie_details.json")
        XCTAssertEqual(dItems.first { $0.name == "imdb_id" }?.value, "tt0111161")
    }

    func testYTSRootCandidates() {
        XCTAssertEqual(APIClient.ytsRootCandidates(for: URL(string: "https://yts.example")!).map(\.absoluteString),
                       ["https://yts.example", "https://yts.example/api/v2"])
        XCTAssertEqual(APIClient.ytsRootCandidates(for: URL(string: "https://yts.example/api/v2")!).map(\.absoluteString),
                       ["https://yts.example/api/v2"])
        XCTAssertEqual(APIClient.ytsRootCandidates(for: URL(string: "https://yts.example/api")!).map(\.absoluteString),
                       ["https://yts.example/api", "https://yts.example/api/v2"])
        XCTAssertEqual(APIClient.ytsRootCandidates(for: URL(string: "https://yts.example/api/v2/list_movies.json")!).map(\.absoluteString),
                       ["https://yts.example/api/v2"])
    }

    func testRejectsWhatIsNotAnAPI() {
        XCTAssertThrowsError(try APIClient.titles(from: data("<html>hi</html>"), type: .movies, base: base))
        XCTAssertThrowsError(try APIClient.titles(from: data(#"{"error": "nope"}"#), type: .movies, base: base))
        XCTAssertEqual(try APIClient.titles(from: data("[]"), type: .movies, base: base).count, 0)
    }

    func testBestSkipsAPreferredQualityWithoutSeeds() throws {
        let json = """
        [{"imdb_id": "tt1", "title": "T", "torrents": {"en": {
            "1080p": {"url": "magnet:?xt=urn:btih:\(hash1)", "seed": 0},
            "720p": {"url": "magnet:?xt=urn:btih:\(hash2)", "seed": 100}}}}]
        """
        let options = try XCTUnwrap(APIClient.titles(from: data(json), type: .movies, base: base).first).options
        XCTAssertEqual(options.best(preferring: "1080p")?.release.quality, "720p")
        XCTAssertEqual(options.best()?.release.quality, "720p")
    }

    func testOldSourcesDecodeAsFeeds() throws {
        let json = #"[{"id": "E621E1F8-C36C-495A-93FC-0C247A3E6E5F", "name": "Old", "feedURL": "https://x.example/rss", "searchURL": "", "enabled": true}]"#
        let sources = try JSONDecoder().decode([CustomSource].self, from: data(json))
        XCTAssertEqual(sources.first?.kind, .feed)
        XCTAssertNotNil(sources.first?.feed)

        let api = CustomSource(kind: .api, name: "API", feedURL: " https://api.example/v2// ")
        XCTAssertNil(api.feed)
        XCTAssertTrue(api.canSearch)
        XCTAssertEqual(api.apiBase?.absoluteString, "https://api.example/v2")
        let roundTrip = try JSONDecoder().decode(CustomSource.self, from: JSONEncoder().encode(api))
        XCTAssertEqual(roundTrip, api)
    }
}

/// Answers HTTP on loopback; until `answering`, drops every connection
/// without a word.
private final class LoopbackServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "loopback-server")
    private let lock = NSLock()
    private var isAnswering = false
    private let respond: (String) -> (Int, String)

    var answering: Bool {
        get { lock.lock(); defer { lock.unlock() }; return isAnswering }
        set { lock.lock(); isAnswering = newValue; lock.unlock() }
    }

    init(respond: @escaping (String) -> (Int, String)) throws {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: params)
        self.respond = respond
    }

    func start() async throws -> URL {
        listener.newConnectionHandler = { [weak self] c in
            guard let self else { return }
            c.start(queue: self.queue)
            guard self.answering else { c.cancel(); return }
            c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, _ in
                let request = String(decoding: data ?? Data(), as: UTF8.self)
                let path = request.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
                let (status, body) = self.respond(path)
                let head = "HTTP/1.1 \(status) X\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n"
                c.send(content: Data((head + body).utf8), completion: .contentProcessed { _ in c.cancel() })
            }
        }
        let port: UInt16 = try await withCheckedThrowingContinuation { c in
            listener.stateUpdateHandler = { [listener] state in
                switch state {
                case .ready: listener.stateUpdateHandler = nil; c.resume(returning: listener.port!.rawValue)
                case .failed(let e): listener.stateUpdateHandler = nil; c.resume(throwing: e)
                default: break
                }
            }
            listener.start(queue: queue)
        }
        return URL(string: "http://127.0.0.1:\(port)")!
    }

    func stop() { listener.cancel() }
}

final class FileToPlayTests: XCTestCase {
    private func info(_ files: [(String, Int)]) throws -> TorrentInfo {
        let total = files.reduce(0) { $0 + $1.1 }
        let pieceLength = 16
        let dict = BValue.dict([
            "name": .string("pack"),
            "piece length": .int(Int64(pieceLength)),
            "pieces": .bytes([UInt8](repeating: 1, count: (total + pieceLength - 1) / pieceLength * 20)),
            "files": .list(files.map { .dict(["length": .int(Int64($0.1)), "path": .list([.string($0.0)])]) }),
        ])
        return try TorrentInfo(rawInfo: Bencode.encode(dict))
    }

    func testPicksTheEpisodeOutOfASeasonPack() throws {
        let pack = try info([("Show.S01E01.1080p.mkv", 900), ("ShowS01e02.mp4", 500), ("Show 1x03.mp4", 400), ("Show.S01E12.mp4", 450), ("sample.mp4", 20)])
        XCTAssertEqual(PlaybackController.fileToPlay(in: pack, season: 1, episode: 2)?.name, "ShowS01e02.mp4")
        XCTAssertEqual(PlaybackController.fileToPlay(in: pack, season: 1, episode: 3)?.name, "Show 1x03.mp4")
        XCTAssertEqual(PlaybackController.fileToPlay(in: pack, season: 1, episode: 1)?.name, "Show.S01E01.1080p.mkv")
        // S01E1 must not match S01E12.
        XCTAssertNotEqual(PlaybackController.fileToPlay(in: pack, season: 1, episode: 12)?.name, "Show.S01E01.1080p.mkv")
    }

    func testPicksTheEpisodesFileThatPlaysHere() throws {
        // The Internet Archive's packs hold each episode as MP4 and as a bigger Ogg.
        let pack = try info([("Show s01e19.mp4", 189), ("Show s01e19.ogv", 213), ("Show s01e21.mp4", 160), ("Show s01e21.ogv", 214)])
        XCTAssertEqual(PlaybackController.fileToPlay(in: pack, season: 1, episode: 19)?.name, "Show s01e19.mp4")
        XCTAssertEqual(PlaybackController.fileToPlay(in: pack, season: 1, episode: 21)?.name, "Show s01e21.mp4")
    }

    func testPicksAMoviesMainFile() throws {
        let withExtras = try info([("Movie.mkv", 1000), ("Movie.sample.mp4", 50), ("Extras.mp4", 100)])
        XCTAssertEqual(PlaybackController.fileToPlay(in: withExtras, season: nil, episode: nil)?.name, "Movie.mkv")
        let twoCuts = try info([("Film.mpeg", 1000), ("Film.mp4", 400)])
        XCTAssertEqual(PlaybackController.fileToPlay(in: twoCuts, season: nil, episode: nil)?.name, "Film.mp4")
    }
}

@MainActor
final class LibraryTests: XCTestCase {
    /// A library written before My List held source titles keeps its watch
    /// history and resume positions.
    func testOlderLibraryStillLoads() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("library-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let old = """
        {"favorites": [{"id": "x", "title": "X", "subjects": [], "section": "movies"}],
         "watched": ["api:tt1"],
         "progress": {"bt:abc:0": {"position": 100, "duration": 1000, "updated": 0, "title": "Film",
                                   "item": {"id": "x", "title": "X", "subjects": [], "section": "movies"}}}}
        """
        try Data(old.utf8).write(to: url)
        let library = Library(fileURL: url)
        XCTAssertTrue(library.isWatched("api:tt1"))
        XCTAssertEqual(library.resumePosition("bt:abc:0"), 100)
        XCTAssertTrue(library.saved.isEmpty)
        XCTAssertTrue(library.continueWatching.isEmpty)

        let show = SavedTitle(id: "tt2", type: .shows, title: "Show", year: 2020, poster: nil, base: URL(string: "https://api.example")!)
        library.toggleSaved(show)
        library.record("api:tt2:s1e1", position: 200, duration: 1000, title: "S01E01", saved: show)
        library.record("api:tt2:s1e2", position: 300, duration: 1000, title: "S01E02", saved: show)
        library.saveNow()
        let reloaded = Library(fileURL: url)
        XCTAssertEqual(reloaded.saved, [show])
        XCTAssertEqual(reloaded.continueWatching.map(\.key), ["api:tt2:s1e2"])
        XCTAssertTrue(reloaded.isWatched("api:tt1"))
    }
}

final class RatingsTests: XCTestCase {
    private func parse(_ json: String) -> Result<Int?, Error> { Ratings.parse(Data(json.utf8)) }

    func testReadsTheTomatometer() throws {
        let found = parse("""
        {"Title": "Film", "Ratings": [{"Source": "Internet Movie Database", "Value": "7.5/10"},
         {"Source": "Rotten Tomatoes", "Value": "91%"}, {"Source": "Metacritic", "Value": "81/100"}], "Response": "True"}
        """)
        XCTAssertEqual(try found.get(), 91)
        XCTAssertTrue(isFresh(91))
        XCTAssertFalse(isFresh(59))
    }

    func testNoScoreIsNotAnError() throws {
        XCTAssertNil(try parse(#"{"Title": "Show", "Ratings": [{"Source": "Internet Movie Database", "Value": "8.1/10"}], "Response": "True"}"#).get())
        XCTAssertNil(try parse(#"{"Response": "False", "Error": "Movie not found!"}"#).get())
    }

    func testABadKeyIsReported() {
        guard case .failure(let error) = parse(#"{"Response": "False", "Error": "Invalid API key!"}"#) else {
            return XCTFail("expected a failure")
        }
        XCTAssertTrue(error.localizedDescription.contains("Invalid API key"))
    }
}

final class UpdaterTests: XCTestCase {
    func testComparesVersionsByNumber() {
        XCTAssertTrue(Updater.isNewer("1.10.0", than: "1.9.2"))
        XCTAssertTrue(Updater.isNewer("1.1", than: "1.0.9"))
        XCTAssertFalse(Updater.isNewer("1.0", than: "1.0.0"))
        XCTAssertFalse(Updater.isNewer("0.9", than: "1.0"))
    }

    func testReadsAGitHubRelease() throws {
        let json = """
        {"tag_name": "v1.2.0", "draft": false, "prerelease": false, "html_url": "https://github.com/o/r/releases/tag/v1.2.0",
         "assets": [{"name": "Bobcorn.dmg", "browser_download_url": "https://github.com/o/r/releases/download/v1.2.0/Bobcorn.dmg"},
                    {"name": "Bobcorn.dmg.sig", "browser_download_url": "https://github.com/o/r/releases/download/v1.2.0/Bobcorn.dmg.sig"}]}
        """
        let release = try XCTUnwrap(Updater.parse(Data(json.utf8)))
        XCTAssertEqual(release.version, "1.2.0")
        XCTAssertEqual(release.installer.lastPathComponent, "Bobcorn.dmg")
        // Without a signature there's nothing to install.
        XCTAssertNil(Updater.parse(Data(json.replacingOccurrences(of: "Bobcorn.dmg.sig", with: "notes.txt").utf8)))
        XCTAssertNil(Updater.parse(Data(json.replacingOccurrences(of: "\"prerelease\": false", with: "\"prerelease\": true").utf8)))
    }

    func testOnlyInstallsWhatTheReleaseKeySigned() throws {
        let key = Curve25519.Signing.PrivateKey()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("update-\(UUID().uuidString).dmg")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("installer".utf8).write(to: file)
        let signature = Data(try key.signature(for: Data("installer".utf8)).base64EncodedString().utf8)
        let publicKey = key.publicKey.rawRepresentation.base64EncodedString()
        XCTAssertNoThrow(try Updater.verify(installer: file, signature: signature, key: publicKey))

        let stranger = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
        XCTAssertThrowsError(try Updater.verify(installer: file, signature: signature, key: stranger))
        try Data("tampered".utf8).write(to: file)
        XCTAssertThrowsError(try Updater.verify(installer: file, signature: signature, key: publicKey))
        XCTAssertEqual(Data(base64Encoded: Updater.publicKey)?.count, 32)
    }
}
