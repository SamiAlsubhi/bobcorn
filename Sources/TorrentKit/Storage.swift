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

    init(url: URL) {
        self.url = url
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

/// A torrent in a cache folder, as it was last saved. A running session
/// saves what it has every few seconds.
public struct CachedTorrent: Sendable {
    public let info: TorrentInfo
    public let folder: URL
    /// How much of each content file is here, 0 to 1.
    public let progress: [Int: Double]
    /// What its data takes up on disk: only what's downloaded.
    public let bytesOnDisk: Int64

    public var infoHashHex: String { info.infoHashHex }

    /// Every torrent in `cache` that got as far as its file list.
    public static func all(in cache: URL) -> [CachedTorrent] {
        let folders = (try? FileManager.default.contentsOfDirectory(at: cache, includingPropertiesForKeys: nil)) ?? []
        return folders.compactMap { folder in
            let dir = SessionDirectory(url: folder)
            guard let raw = try? Data(contentsOf: dir.infoURL),
                  let info = try? TorrentInfo(rawInfo: [UInt8](raw)),
                  info.infoHashHex == folder.lastPathComponent
            else { return nil }
            let have = dir.loadHave(pieceCount: info.pieceCount) ?? Bitfield(count: info.pieceCount)
            let size = (try? dir.dataURL.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0
            return CachedTorrent(info: info, folder: folder, progress: progress(of: info.contentFiles.map(\.index), in: info, have: have),
                                 bytesOnDisk: Int64(size))
        }
    }

    /// Where a torrent keeps its data in `cache`, beside which an app may
    /// keep files of its own.
    public static func folder(forInfoHash hex: String, in cache: URL) -> URL {
        cache.appendingPathComponent(hex.lowercased(), isDirectory: true)
    }

    /// Deletes one file's share of a torrent that isn't running: the pieces
    /// holding only its bytes count as missing again, and their space is
    /// freed where the file system can. The rest of the torrent stays.
    @discardableResult
    public static func discard(fileIndex: Int, in folder: URL) -> Bool {
        let dir = SessionDirectory(url: folder)
        guard let raw = try? Data(contentsOf: dir.infoURL),
              let info = try? TorrentInfo(rawInfo: [UInt8](raw)),
              var have = dir.loadHave(pieceCount: info.pieceCount)
        else { return false }
        let pieces = ownPieces(of: fileIndex, in: info)
        for i in pieces { have[i] = false }
        dir.saveHave(have)
        let fd = open(dir.dataURL.path, O_RDWR)
        guard fd >= 0 else { return true }
        defer { close(fd) }
        // Runs of whole pieces, so each hole starts on a block boundary.
        var runs: [(start: Int64, end: Int64)] = []
        for i in pieces {
            let start = info.pieceOffset(i)
            let end = start + Int64(info.pieceSize(i))
            if let last = runs.last, last.end == start { runs[runs.count - 1].end = end } else { runs.append((start, end)) }
        }
        for run in runs {
            let length = (run.end - run.start) / 4096 * 4096
            guard length > 0 else { continue }
            var hole = fpunchhole_t(fp_flags: 0, reserved: 0, fp_offset: off_t(run.start), fp_length: off_t(length))
            _ = fcntl(fd, F_PUNCHHOLE, &hole)
        }
        return true
    }

    /// The pieces holding nothing but this file's bytes and padding.
    static func ownPieces(of fileIndex: Int, in info: TorrentInfo) -> [Int] {
        guard info.files.indices.contains(fileIndex), let range = info.pieceRange(for: info.files[fileIndex]) else { return [] }
        return range.filter { i in
            info.segments(start: info.pieceOffset(i), length: info.pieceSize(i))
                .allSatisfy { $0.file.index == fileIndex || $0.file.isPadding }
        }
    }

    static func progress(of fileIndices: [Int], in info: TorrentInfo, have: Bitfield) -> [Int: Double] {
        var out: [Int: Double] = [:]
        for f in fileIndices where info.files.indices.contains(f) {
            let file = info.files[f]
            guard file.length > 0, let range = info.pieceRange(for: file) else {
                out[f] = 1
                continue
            }
            var done: Int64 = 0
            for i in range where i < have.count && have[i] {
                let start = max(info.pieceOffset(i), file.offset)
                let end = min(info.pieceOffset(i) + Int64(info.pieceSize(i)), file.offset + file.length)
                done += max(0, end - start)
            }
            out[f] = Double(done) / Double(file.length)
        }
        return out
    }
}
