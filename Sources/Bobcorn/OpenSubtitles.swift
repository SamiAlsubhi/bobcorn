import Foundation

/// Subtitles from OpenSubtitles.com, with an API key set in Settings. A search
/// goes by the title's IMDb ID when the source gives one, otherwise by the
/// video's file name, and by the file's hash once it's worked out: subtitles
/// uploaded for that very release come first, since they're timed to it.
/// Searching is free; a free key downloads 5 subtitles a day per IP address,
/// so downloads are kept in the cache folder, and picking one again costs
/// nothing. Each video remembers its downloads, and the one it showed.
enum OpenSubtitles {
    static let api = URL(string: "https://api.opensubtitles.com/api/v1/")!
    /// Where a key is made: the API consumers page of an OpenSubtitles profile.
    static let keyPage = URL(string: "https://www.opensubtitles.com/en/consumers")!

    static var apiKey: String {
        UserDefaults.standard.string(forKey: Pref.openSubtitlesKey)?.trimmingCharacters(in: .whitespaces) ?? ""
    }

    /// The API turns away requests that don't name the app and its version.
    private static let userAgent = "Bobcorn v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0")"

    private static let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 20
        return URLSession(configuration: c)
    }()

    /// In the cache folder, so they move and clear with the downloads.
    private static var cacheDirectory: URL {
        AppModel.cacheDirectory.appendingPathComponent("Subtitles", isDirectory: true)
    }

    // MARK: - Searching

    /// What a search asks for.
    struct Query: Hashable {
        /// The movie's IMDb ID, or the show's for an episode.
        var imdbID: String?
        var season: Int?
        var episode: Int?
        /// The video's file name, without its extension: searched when
        /// there's no IMDb ID, and used to rank what's found.
        var fileName: String?
        var hash: String?
        var language = "en"

        /// Sorted, lowercased and without leading zeros, as the API asks, so
        /// it answers without a redirect.
        var items: [URLQueryItem] {
            var params = ["languages": language.lowercased()]
            if let hash { params["moviehash"] = hash }
            if let id = imdbID.flatMap(Self.imdbNumber) {
                if let season, let episode {
                    params["parent_imdb_id"] = id
                    params["season_number"] = String(season)
                    params["episode_number"] = String(episode)
                } else {
                    params["imdb_id"] = id
                }
            } else if let fileName, !fileName.isEmpty {
                params["query"] = fileName.lowercased()
            }
            return params.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        }

        /// "tt0133093" → "133093".
        static func imdbNumber(_ id: String) -> String? {
            let digits = id.lowercased().hasPrefix("tt") ? id.dropFirst(2) : Substring(id)
            guard let n = Int(digits), n > 0 else { return nil }
            return String(n)
        }
    }

    /// A subtitle a search found.
    struct Subtitle: Identifiable, Hashable {
        let fileID: Int
        let language: String
        /// The release it was made for, such as "Film.2019.1080p.BluRay.x264-GROUP".
        let release: String
        let downloads: Int
        let hearingImpaired: Bool
        /// Translated by a machine or an AI rather than by a person.
        let machineTranslated: Bool
        /// Uploaded for a file with this video's hash, so it's timed to it.
        let matchesFile: Bool

        var id: Int { fileID }
        /// Downloaded before, so picking it again is free.
        var isOnDisk: Bool { FileManager.default.fileExists(atPath: cacheFile(fileID).path) }
    }

    /// The first page of results, which is plenty for one title in one language.
    static func search(_ query: Query) async throws -> [Subtitle] {
        try subtitles(from: try await send(request("subtitles", query: query.items)))
    }

    static func subtitles(from data: Data) throws -> [Subtitle] {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let list = json["data"] as? [[String: Any]]
        else { throw Failure.other("OpenSubtitles sent an answer Bobcorn can't read.") }
        return list.compactMap { item in
            // A subtitle split over several files is for a video on several CDs.
            guard let a = item["attributes"] as? [String: Any],
                  let files = a["files"] as? [[String: Any]], files.count == 1,
                  let fileID = (files[0]["file_id"] as? NSNumber)?.intValue
            else { return nil }
            func flag(_ key: String) -> Bool { (a[key] as? NSNumber)?.boolValue ?? false }
            let release = (a["release"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? files[0]["file_name"] as? String ?? ""
            return Subtitle(
                fileID: fileID,
                language: a["language"] as? String ?? "",
                release: release.trimmingCharacters(in: .whitespacesAndNewlines),
                downloads: (a["download_count"] as? NSNumber)?.intValue ?? 0,
                hearingImpaired: flag("hearing_impaired"),
                machineTranslated: flag("machine_translated") || flag("ai_translated"),
                matchesFile: flag("moviehash_match")
            )
        }
    }

    /// Timed to this file first, then translated by people, then made for a
    /// release whose name is most like the file's, then the most downloaded.
    static func ranked(_ subtitles: [Subtitle], fileName: String?) -> [Subtitle] {
        let words = fileName.map(releaseWords) ?? []
        func key(_ s: Subtitle) -> (Int, Int, Int, Int) {
            (s.matchesFile ? 1 : 0, s.machineTranslated ? 0 : 1, releaseWords(s.release).intersection(words).count, s.downloads)
        }
        return subtitles.sorted { key($0) > key($1) }
    }

    /// "The.Film.2019.1080p.BluRay.x264-GROUP" → the, film, 2019, 1080p, bluray, x264, group.
    static func releaseWords(_ name: String) -> Set<String> {
        Set(name.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init))
    }

    // MARK: - Downloading

    /// The subtitle as an .srt on disk, downloaded unless it already is, and
    /// how many downloads the key has left today when it was.
    static func file(for subtitle: Subtitle) async throws -> (url: URL, remaining: Int?) {
        let url = cacheFile(subtitle.fileID)
        if FileManager.default.fileExists(atPath: url.path) { return (url, nil) }
        var r = request("download")
        r.httpMethod = "POST"
        r.httpBody = try JSONSerialization.data(withJSONObject: ["file_id": subtitle.fileID])
        let answer = (try? JSONSerialization.jsonObject(with: try await send(r))) as? [String: Any]
        guard let link = (answer?["link"] as? String).flatMap(URL.init(string:)) else {
            throw Failure.other("OpenSubtitles didn't say where to download the subtitle from.")
        }
        let (data, response) = try await session.data(from: link)
        guard (response as? HTTPURLResponse)?.statusCode == 200, !data.isEmpty else {
            throw Failure.other("The subtitle's download link didn't work. Try again.")
        }
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        return (url, (answer?["remaining"] as? NSNumber)?.intValue)
    }

    private static func cacheFile(_ fileID: Int) -> URL {
        cacheDirectory.appendingPathComponent("\(fileID).srt")
    }

    // MARK: - Remembered

    /// A video's downloaded subtitles, and the one it showed last.
    struct Picked: Codable, Equatable {
        struct Download: Codable, Equatable {
            let fileID: Int
            let label: String
            let language: String
        }

        var downloads: [Download] = []
        var showing: Int?
    }

    private static var pickedFile: URL { cacheDirectory.appendingPathComponent("picked.json") }

    /// By the video's library key.
    static func picked(for key: String) -> Picked {
        allPicked()[key] ?? Picked()
    }

    static func remember(_ picked: Picked, for key: String) {
        var all = allPicked()
        guard all[key] != picked else { return }
        all[key] = picked.downloads.isEmpty ? nil : picked
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(all) { try? data.write(to: pickedFile, options: .atomic) }
    }

    private static func allPicked() -> [String: Picked] {
        guard let data = try? Data(contentsOf: pickedFile) else { return [:] }
        return (try? JSONDecoder().decode([String: Picked].self, from: data)) ?? [:]
    }

    /// The menu's track for a download, while its file is still in the cache.
    static func track(_ download: Picked.Download) -> SubtitleTrack? {
        let url = cacheFile(download.fileID)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return SubtitleTrack(id: trackID(download.fileID), label: download.label, source: .local(url), language: download.language)
    }

    static func trackID(_ fileID: Int) -> String { "os:\(fileID)" }

    static func label(_ subtitle: Subtitle) -> String {
        "\(languageName(subtitle.language)) · \(subtitle.release)"
    }

    // MARK: - Requests

    enum Failure: LocalizedError, Equatable {
        case noKey
        case refused(String)
        case busy
        case other(String)

        var errorDescription: String? {
            switch self {
            case .noKey: return "Add an OpenSubtitles API key in Settings → Sources to search for subtitles."
            case .refused(let why): return "OpenSubtitles refused the API key: \(why)"
            case .busy: return "OpenSubtitles is busy. Try again in a moment."
            case .other(let why): return why
            }
        }

        /// Fixed in Settings.
        var isAboutTheKey: Bool {
            switch self {
            case .noKey, .refused: return true
            case .busy, .other: return false
            }
        }
    }

    private static func request(_ path: String, query: [URLQueryItem] = []) -> URLRequest {
        var c = URLComponents(url: api.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty {
            c.queryItems = query
            // A "+" left as it is would arrive as a space.
            c.percentEncodedQuery = c.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        }
        var r = URLRequest(url: c.url!)
        r.setValue(apiKey, forHTTPHeaderField: "Api-Key")
        r.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        r.setValue("*/*", forHTTPHeaderField: "Accept")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return r
    }

    /// The answer's body, after one more try when the server fails, as the
    /// API asks.
    private static func send(_ request: URLRequest) async throws -> Data {
        guard !apiKey.isEmpty else { throw Failure.noKey }
        var attempt = 0
        while true {
            let (data, response): (Data, URLResponse)
            do {
                (data, response) = try await session.data(for: request)
            } catch {
                throw Failure.other("Couldn't reach OpenSubtitles: \(error.localizedDescription)")
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 200 { return data }
            if status >= 500, attempt == 0 {
                attempt += 1
                try await Task.sleep(nanoseconds: 1_000_000_000)
                continue
            }
            throw failure(status: status, body: data)
        }
    }

    static func failure(status: Int, body: Data) -> Failure {
        let message = (((try? JSONSerialization.jsonObject(with: body)) as? [String: Any])?["message"] as? String)?
            .trimmingCharacters(in: .whitespaces)
        switch status {
        case 401, 403: return .refused(message ?? "HTTP \(status)")
        case 429: return .busy
        // A used-up download quota, for one, explains itself.
        default: return .other(message.map { "OpenSubtitles: \($0)" } ?? "OpenSubtitles answered HTTP \(status).")
        }
    }

    // MARK: - File hash

    /// Files OpenSubtitles hashes: over 128 KB and under 9 GB.
    static func canHash(length: Int64) -> Bool { length > 131_072 && length < 9_000_000_000 }

    private static let hashChunk = 65536

    /// OpenSubtitles' hash of a video of `length` bytes, from its first and
    /// last 64 KB, which `read` returns a part at a time.
    static func hash(length: Int64, read: (Int64, Int) async throws -> Data) async throws -> String {
        func chunk(at offset: Int64) async throws -> Data {
            var out = Data()
            while out.count < hashChunk {
                let part = try await read(offset + Int64(out.count), hashChunk - out.count)
                guard !part.isEmpty else { throw Failure.other("The video ended early.") }
                out.append(part)
            }
            return out
        }
        let head = try await chunk(at: 0)
        let tail = try await chunk(at: length - Int64(hashChunk))
        return hash(length: length, head: head, tail: tail)
    }

    /// The size plus both ends summed as little-endian 64-bit words,
    /// wrapping, in 16 hex digits.
    static func hash(length: Int64, head: Data, tail: Data) -> String {
        var sum = UInt64(length)
        for chunk in [head, tail] {
            chunk.withUnsafeBytes { raw in
                for i in stride(from: 0, to: raw.count - 7, by: 8) {
                    sum &+= UInt64(littleEndian: raw.loadUnaligned(fromByteOffset: i, as: UInt64.self))
                }
            }
        }
        return String(format: "%016llx", sum)
    }

    // MARK: - Languages

    /// The languages OpenSubtitles sorts subtitles by, as its API lists them.
    static let languages: [(code: String, name: String)] = [
        ("af", "Afrikaans"), ("sq", "Albanian"), ("ar", "Arabic"), ("an", "Aragonese"), ("hy", "Armenian"),
        ("at", "Asturian"), ("eu", "Basque"), ("be", "Belarusian"), ("bn", "Bengali"), ("bs", "Bosnian"),
        ("br", "Breton"), ("bg", "Bulgarian"), ("my", "Burmese"), ("ca", "Catalan"),
        ("zh-cn", "Chinese (simplified)"), ("zh-tw", "Chinese (traditional)"), ("ze", "Chinese bilingual"),
        ("hr", "Croatian"), ("cs", "Czech"), ("da", "Danish"), ("nl", "Dutch"), ("en", "English"),
        ("eo", "Esperanto"), ("et", "Estonian"), ("fi", "Finnish"), ("fr", "French"), ("gl", "Galician"),
        ("ka", "Georgian"), ("de", "German"), ("el", "Greek"), ("he", "Hebrew"), ("hi", "Hindi"),
        ("hu", "Hungarian"), ("is", "Icelandic"), ("id", "Indonesian"), ("it", "Italian"), ("ja", "Japanese"),
        ("kk", "Kazakh"), ("km", "Khmer"), ("ko", "Korean"), ("lv", "Latvian"), ("lt", "Lithuanian"),
        ("lb", "Luxembourgish"), ("mk", "Macedonian"), ("ms", "Malay"), ("ml", "Malayalam"), ("ma", "Manipuri"),
        ("mn", "Mongolian"), ("me", "Montenegrin"), ("no", "Norwegian"), ("oc", "Occitan"), ("fa", "Persian"),
        ("pl", "Polish"), ("pt-pt", "Portuguese"), ("pt-br", "Portuguese (Brazilian)"), ("ro", "Romanian"),
        ("ru", "Russian"), ("sr", "Serbian"), ("si", "Sinhalese"), ("sk", "Slovak"), ("sl", "Slovenian"),
        ("es", "Spanish"), ("sw", "Swahili"), ("sv", "Swedish"), ("sy", "Syriac"), ("tl", "Tagalog"),
        ("ta", "Tamil"), ("te", "Telugu"), ("th", "Thai"), ("tr", "Turkish"), ("uk", "Ukrainian"),
        ("ur", "Urdu"), ("uz", "Uzbek"), ("vi", "Vietnamese"),
    ]

    static func languageName(_ code: String) -> String {
        languages.first { $0.code == code.lowercased() }?.name ?? code
    }

    /// As an RFC 5646 tag, for a Chromecast: "pt-br" → "pt-BR".
    static func languageTag(_ code: String) -> String {
        let parts = code.split(separator: "-")
        return parts.count == 2 ? "\(parts[0])-\(parts[1].uppercased())" : code
    }
}
