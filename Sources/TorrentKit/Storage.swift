import Foundation

/// The torrent's data as one sparse file, addressed by torrent offset. Only
/// what has been written takes up disk space, so a 40 GB torrent of which one
/// 700 MB film is watched costs about 700 MB.
final class BlobStorage {
    private let fd: Int32
    let length: Int64

    init(url: URL, length: Int64) throws {
        fd = open(url.path, O_RDWR | O_CREAT, 0o644)
        guard fd >= 0 else { throw TorrentError.storage("cannot open \(url.path): \(String(cString: strerror(errno)))") }
        self.length = length
        var st = stat()
        if fstat(fd, &st) == 0, st.st_size != length {
            guard ftruncate(fd, off_t(length)) == 0 else {
                let why = String(cString: strerror(errno))
                close(fd)
                throw TorrentError.storage("cannot size cache file: \(why)")
            }
        }
    }

    deinit { close(fd) }

    func write(_ bytes: [UInt8], at offset: Int64) throws {
        try bytes.withUnsafeBytes { raw in
            var done = 0
            while done < raw.count {
                let n = pwrite(fd, raw.baseAddress! + done, raw.count - done, off_t(offset) + off_t(done))
                guard n > 0 else { throw TorrentError.storage("write failed: \(String(cString: strerror(errno)))") }
                done += n
            }
        }
    }

    func read(at offset: Int64, length: Int) throws -> [UInt8] {
        var out = [UInt8](repeating: 0, count: length)
        try out.withUnsafeMutableBytes { raw in
            var done = 0
            while done < length {
                let n = pread(fd, raw.baseAddress! + done, length - done, off_t(offset) + off_t(done))
                guard n > 0 else { throw TorrentError.storage("read failed: \(String(cString: strerror(errno)))") }
                done += n
            }
        }
        return out
    }
}

/// What survives between launches: the info dictionary (so a magnet opens
/// instantly the second time) and which pieces are already verified.
struct ResumeState: Codable {
    var have: Data
    var pieceCount: Int
}

struct SessionDirectory {
    let url: URL

    var infoURL: URL { url.appendingPathComponent("info.bencode") }
    var dataURL: URL { url.appendingPathComponent("data.blob") }
    var stateURL: URL { url.appendingPathComponent("state.json") }

    init(cache: URL, infoHash: [UInt8]) {
        url = cache.appendingPathComponent(infoHash.hexString, isDirectory: true)
    }

    func ensureExists() throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func loadInfo(expecting hash: [UInt8]) -> TorrentInfo? {
        guard let data = try? Data(contentsOf: infoURL),
              let info = try? TorrentInfo(rawInfo: [UInt8](data)),
              info.infoHash == hash
        else { return nil }
        return info
    }

    func saveInfo(_ info: TorrentInfo) {
        try? Data(info.rawInfo).write(to: infoURL, options: .atomic)
    }

    func loadHave(pieceCount: Int) -> Bitfield? {
        guard FileManager.default.fileExists(atPath: dataURL.path),
              let data = try? Data(contentsOf: stateURL),
              let state = try? JSONDecoder().decode(ResumeState.self, from: data),
              state.pieceCount == pieceCount
        else { return nil }
        return Bitfield(bytes: [UInt8](state.have), count: pieceCount)
    }

    func saveHave(_ have: Bitfield) {
        let state = ResumeState(have: Data(have.bytes), pieceCount: have.count)
        if let data = try? JSONEncoder().encode(state) {
            try? data.write(to: stateURL, options: .atomic)
        }
    }
}
