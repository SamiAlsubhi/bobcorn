import XCTest
@testable import Bobcorn

final class OpenSubtitlesTests: XCTestCase {
    private func query(_ q: OpenSubtitles.Query) -> String {
        q.items.map { "\($0.name)=\($0.value ?? "")" }.joined(separator: "&")
    }

    func testMovieQueryIsSortedWithoutLeadingZeros() {
        let q = OpenSubtitles.Query(imdbID: "tt0133093", fileName: "The.Matrix.1999.1080p", hash: "8e245d9679d31e12", language: "pt-BR")
        XCTAssertEqual(query(q), "imdb_id=133093&languages=pt-br&moviehash=8e245d9679d31e12")
    }

    func testEpisodeQueryUsesTheShow() {
        let q = OpenSubtitles.Query(imdbID: "tt0944947", season: 2, episode: 5, language: "en")
        XCTAssertEqual(query(q), "episode_number=5&languages=en&parent_imdb_id=944947&season_number=2")
    }

    func testWithoutAnIDItSearchesTheFileName() {
        let q = OpenSubtitles.Query(fileName: "Some.Film.1962.720p.WEB", language: "fr")
        XCTAssertEqual(query(q), "languages=fr&query=some.film.1962.720p.web")
        XCTAssertNil(OpenSubtitles.Query.imdbNumber("tt0000000"))
        XCTAssertNil(OpenSubtitles.Query.imdbNumber("nm123"))
    }

    func testParsesSearchResults() throws {
        let json = """
        {"total_pages": 1, "total_count": 3, "per_page": 60, "page": 1, "data": [
          {"id": "1", "type": "subtitle", "attributes": {"language": "en", "download_count": 1200,
            "hearing_impaired": false, "machine_translated": false, "ai_translated": false,
            "release": "Film.2019.1080p.BluRay.x264-GROUP", "moviehash_match": true,
            "files": [{"file_id": 111, "cd_number": 1, "file_name": "film.srt"}]}},
          {"id": "2", "type": "subtitle", "attributes": {"language": "en", "download_count": 50,
            "hearing_impaired": true, "ai_translated": true, "release": "",
            "files": [{"file_id": 222, "cd_number": 1, "file_name": "film.hi.srt"}]}},
          {"id": "3", "type": "subtitle", "attributes": {"language": "en", "download_count": 9,
            "release": "Film.2019.2CD", "files": [{"file_id": 331}, {"file_id": 332}]}}
        ]}
        """
        let subs = try OpenSubtitles.subtitles(from: Data(json.utf8))
        XCTAssertEqual(subs.map(\.fileID), [111, 222], "a subtitle split over two CDs is left out")
        XCTAssertEqual(subs[0].release, "Film.2019.1080p.BluRay.x264-GROUP")
        XCTAssertEqual(subs[0].downloads, 1200)
        XCTAssertTrue(subs[0].matchesFile)
        XCTAssertFalse(subs[0].hearingImpaired)
        XCTAssertEqual(subs[1].release, "film.hi.srt", "falls back to the file name")
        XCTAssertTrue(subs[1].hearingImpaired)
        XCTAssertTrue(subs[1].machineTranslated)
        XCTAssertFalse(subs[1].matchesFile)
    }

    func testRanksMatchesThenPeopleThenSimilarReleasesThenDownloads() {
        func sub(_ id: Int, _ release: String, downloads: Int, match: Bool = false, machine: Bool = false) -> OpenSubtitles.Subtitle {
            OpenSubtitles.Subtitle(fileID: id, language: "en", release: release, downloads: downloads,
                                   hearingImpaired: false, machineTranslated: machine, matchesFile: match)
        }
        let ranked = OpenSubtitles.ranked([
            sub(1, "Film.2019.720p.WEB-OTHER", downloads: 9000),
            sub(2, "Film.2019.1080p.BluRay.x264-GROUP", downloads: 10),
            sub(3, "Film.2019.1080p.BluRay.x264-GROUP", downloads: 99_999, machine: true),
            sub(4, "Film 2019", downloads: 5, match: true),
            sub(5, "Film.2019.720p.WEB-OTHER", downloads: 100),
        ], fileName: "Film.2019.1080p.BluRay.x264-GROUP")
        XCTAssertEqual(ranked.map(\.fileID), [4, 2, 1, 5, 3])
    }

    func testFailures() {
        let quota = Data(#"{"requests": 6, "remaining": -1, "message": "You have downloaded your allowed 5 subtitles for 24h.", "reset_time": "23 hours"}"#.utf8)
        XCTAssertEqual(OpenSubtitles.failure(status: 406, body: quota), .other("OpenSubtitles: You have downloaded your allowed 5 subtitles for 24h."))
        XCTAssertEqual(OpenSubtitles.failure(status: 403, body: Data(#"{"message": "You cannot consume this service"}"#.utf8)),
                       .refused("You cannot consume this service"))
        XCTAssertEqual(OpenSubtitles.failure(status: 429, body: Data()), .busy)
        XCTAssertEqual(OpenSubtitles.failure(status: 502, body: Data("<html>".utf8)), .other("OpenSubtitles answered HTTP 502."))
        XCTAssertTrue(OpenSubtitles.Failure.noKey.isAboutTheKey)
        XCTAssertFalse(OpenSubtitles.Failure.busy.isAboutTheKey)
    }

    // MARK: - Hash

    func testHashOfZerosIsTheSize() {
        let zeros = Data(count: 65536)
        XCTAssertEqual(OpenSubtitles.hash(length: 140_000, head: zeros, tail: zeros), "00000000000222e0")
    }

    func testHashWrapsAround() {
        // Each all-ones word is -1, so both ends take 2 × 8192 off the size.
        let ones = Data(repeating: 0xFF, count: 65536)
        XCTAssertEqual(OpenSubtitles.hash(length: 140_000, head: ones, tail: ones), "000000000001e2e0")
    }

    func testHashReadsBothEndsAPartAtATime() async throws {
        var file = Data(count: 300_000)
        for i in file.indices { file[i] = UInt8(truncatingIfNeeded: i &* 31 &+ i / 7) }
        var expected = UInt64(file.count)
        for start in [0, file.count - 65536] {
            for word in stride(from: start, to: start + 65536, by: 8) {
                var value: UInt64 = 0
                for b in 0..<8 { value |= UInt64(file[word + b]) << (8 * UInt64(b)) }
                expected &+= value
            }
        }
        var reads = 0
        let hash = try await OpenSubtitles.hash(length: Int64(file.count)) { offset, count in
            reads += 1
            let start = Int(offset)
            return file.subdata(in: start..<min(file.count, start + min(count, 5000)))
        }
        XCTAssertEqual(hash, String(format: "%016llx", expected))
        XCTAssertEqual(reads, 28, "14 reads of at most 5000 bytes for each 64 KB end")
    }

    func testOnlyHashesSizesOpenSubtitlesKnows() {
        XCTAssertFalse(OpenSubtitles.canHash(length: 131_072))
        XCTAssertTrue(OpenSubtitles.canHash(length: 700_000_000))
        XCTAssertFalse(OpenSubtitles.canHash(length: 9_000_000_000))
    }

    // MARK: - Languages

    func testLanguageFromTheMac() {
        XCTAssertEqual(OpenSubtitles.code(forLocale: "en-US"), "en")
        XCTAssertEqual(OpenSubtitles.code(forLocale: "ar-SA"), "ar")
        XCTAssertEqual(OpenSubtitles.code(forLocale: "pt-BR"), "pt-br")
        XCTAssertEqual(OpenSubtitles.code(forLocale: "pt-PT"), "pt-pt")
        XCTAssertEqual(OpenSubtitles.code(forLocale: "zh-Hans-CN"), "zh-cn")
        XCTAssertEqual(OpenSubtitles.code(forLocale: "zh-Hant-TW"), "zh-tw")
        XCTAssertNil(OpenSubtitles.code(forLocale: "xx"))
        XCTAssertEqual(OpenSubtitles.languageName("PT-BR"), "Portuguese (Brazilian)")
    }
}
