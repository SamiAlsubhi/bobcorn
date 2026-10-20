import Foundation

public enum TorrentSource: Sendable {
    case magnet(MagnetLink)
    case metainfo(Metainfo)

    public var infoHash: [UInt8] {
        switch self {
        case .magnet(let m): return m.infoHash
        case .metainfo(let m): return m.info.infoHash
        }
    }

    public var infoHashHex: String { infoHash.hexString }
}

public struct TorrentConfiguration: Sendable {
    public var cacheDirectory: URL
    public var maxPeers = 60
    public var enableDHT = true
    /// Adds well-known open trackers to magnets.
    public var usePublicTrackers = true
    /// How far ahead of the play position to fetch urgently.
    public var streamWindowBytes = 24 * 1024 * 1024
    /// The port announced to trackers. Bobcorn does not accept incoming
    /// connections, so this only matters to trackers that insist on one.
    public var announcePort: UInt16 = 6881

    public init(cacheDirectory: URL) {
        self.cacheDirectory = cacheDirectory
    }
}

public enum TorrentPhase: Sendable, Equatable {
    case fetchingMetadata
    case downloading
    case complete
    case stopped
    case failed(String)
}

/// How available one file is in the swarm right now, from the bitfields of
/// the peers connected to.
public struct FileAvailability: Sendable, Equatable {
    /// Peers holding the whole file.
    public var seeds = 0
    /// Peers holding part of it.
    public var peers = 0
    /// A web seed that has not failed, i.e. an HTTP server with all of it.
    public var webSeeded = false

    public init() {}
}

public struct TorrentStats: Sendable {
    public var phase: TorrentPhase = .fetchingMetadata
    public var name: String?
    public var downloadRate: Double = 0
    public var uploadRate: Double = 0
    public var connectedPeers = 0
    /// Peers currently sending to us.
    public var activePeers = 0
    public var knownPeers = 0
    public var seeders: Int?
    public var leechers: Int?
    public var activeWebSeeds = 0
    public var downloaded: Int64 = 0
    public var uploaded: Int64 = 0
    public var piecesHave = 0
    public var piecesTotal = 0
    /// Of the files being streamed.
    public var selectedProgress: Double = 0
    /// Contiguous verified bytes from the current read position onward.
    public var bufferedAhead: Int64 = 0
    public var hashFailures = 0

    public init() {}
}

/// One torrent. Everything mutable is touched only on `queue`; the public
/// methods hop onto it.
public final class TorrentSession: @unchecked Sendable {
    public let infoHash: [UInt8]
    public var infoHashHex: String { infoHash.hexString }

    static let blockSize = 16 * 1024
    static let utMetadataID: UInt8 = 2

    let queue: DispatchQueue
    private let config: TorrentConfiguration
    private let peerID: [UInt8]
    private let directory: SessionDirectory
    private let isMagnet: Bool

    private(set) var info: TorrentInfo?
    private var displayName: String?
    private var trackerURLs: [String]
    private var webSeedURLs: [String]
    private var webSeeds: [WebSeed] = []
    private var magnetPeers: [PeerAddress]

    private var stopped = false
    private var failure: String?
    private var storage: BlobStorage?
    private var have = Bitfield(count: 0)
    private var wanted: [Bool] = []
    private var wantedTotal = 0
    private var wantedRemaining = 0
    private var selectedFiles: Set<Int> = []
    private var pinned: Set<Int> = []
    private var progress: [Int: PieceProgress] = [:]
    private var order: [Int] = []
    private var critical: Set<Int> = []
    private var orderDirty = true
    private var heads: [UUID: StreamHead] = [:]
    private var lastHeadPiece: Int?
    private var haveDirty = false
    private var lastHaveSave = Date()

    private var peers: [ObjectIdentifier: Peer] = [:]
    private var peerByAddress: [PeerAddress: Peer] = [:]
    private var candidates: [PeerAddress: Candidate] = [:]

    private var metadataSize: Int?
    private var metadataPieces: [[UInt8]?] = []
    private var metadataRequestedAt: [Int: Date] = [:]
    private var metadataWaiters: [CheckedContinuation<TorrentInfo, Error>] = []

    private var pieceWaiters: [Int: [(id: UUID, continuation: CheckedContinuation<Void, Error>)]] = [:]
    private var cancelledWaits: Set<UUID> = []

    private var trackerTasks: [Task<Void, Never>] = []
    private var webSeedTasks: [UUID: Task<Void, Never>] = [:]
    private var swarm: [String: (seeders: Int?, leechers: Int?)] = [:]
    private var dht: DHTLookup?
    private var lastDHTRestart = Date()
    private var timer: DispatchSourceTimer?
    private var tickCount = 0
    private var download = RateMeter()
    private var upload = RateMeter()
    private var hashFailures = 0
    private let announceKey = UInt32.random(in: 0...UInt32.max)

    struct StreamHead {
        var piece: Int
        var updated: Date
    }

    struct Candidate {
        var lastAttempt: Date?
        var failures = 0
    }

    public init(source: TorrentSource, configuration: TorrentConfiguration, peerID: [UInt8]) {
        infoHash = source.infoHash
        config = configuration
        self.peerID = peerID
        queue = DispatchQueue(label: "torrent.\(source.infoHashHex.prefix(8))", qos: .userInitiated)
        directory = SessionDirectory(cache: configuration.cacheDirectory, infoHash: source.infoHash)
        switch source {
        case .magnet(let m):
            isMagnet = true
            displayName = m.displayName
            trackerURLs = m.trackers
            webSeedURLs = m.webSeeds
            magnetPeers = m.peers
        case .metainfo(let m):
            isMagnet = false
            info = m.info
            displayName = m.info.name
            trackerURLs = m.trackers
            webSeedURLs = m.webSeeds
            magnetPeers = []
        }
    }

    // MARK: - Public API

    public func start() {
        queue.async { [self] in
            guard !stopped, timer == nil else { return }
            do { try directory.ensureExists() } catch {
                fail("cannot create cache folder: \(error.localizedDescription)")
                return
            }
            if info == nil, let cached = directory.loadInfo(expecting: infoHash) { info = cached }
            if let info { obtained(info) }

            startTrackers()
            if config.enableDHT && !(info?.isPrivate ?? false) {
                let lookup = DHTLookup(infoHash: infoHash, queue: queue) { [weak self] found in
                    self?.addCandidates(found)
                }
                dht = lookup
                lookup.start()
            }
            addCandidates(magnetPeers)

            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now() + 1, repeating: 1)
            t.setEventHandler { [weak self] in self?.tick() }
            t.resume()
            timer = t
        }
    }

    public func stop() {
        queue.async { [self] in
            guard !stopped else { return }
            stopped = true
            timer?.cancel()
            timer = nil
            dht?.stop()
            dht = nil
            trackerTasks.forEach { $0.cancel() }
            trackerTasks.removeAll()
            webSeedTasks.values.forEach { $0.cancel() }
            webSeedTasks.removeAll()
            for peer in peers.values {
                peer.connection.delegate = nil
                peer.connection.close(reason: "stopping")
            }
            peers.removeAll()
            peerByAddress.removeAll()
            for w in metadataWaiters { w.resume(throwing: TorrentError.stopped) }
            metadataWaiters.removeAll()
            for list in pieceWaiters.values { for w in list { w.continuation.resume(throwing: TorrentError.stopped) } }
            pieceWaiters.removeAll()
            if info != nil { directory.saveHave(have) }
            announceStopped()
        }
    }

    /// Resolves once the torrent's file list is known: at once for a .torrent,
    /// after the metadata exchange for a magnet.
    public func waitForMetadata() async throws -> TorrentInfo {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<TorrentInfo, Error>) in
            queue.async { [self] in
                if let info {
                    c.resume(returning: info)
                } else if stopped {
                    c.resume(throwing: TorrentError.stopped)
                } else if let failure {
                    c.resume(throwing: TorrentError.invalidMetainfo(failure))
                } else {
                    metadataWaiters.append(c)
                }
            }
        }
    }

    /// Downloads only this file (plus whatever its first and last pieces share).
    public func select(fileIndex: Int) {
        queue.async { [self] in
            selectedFiles = [fileIndex]
            applySelection()
        }
    }

    /// Downloads nothing more; the swarm stays connected.
    public func clearSelection() {
        queue.async { [self] in
            selectedFiles = []
            applySelection()
        }
    }

    /// Adds a file to what is downloaded, e.g. a subtitle next to the film.
    public func want(fileIndex: Int) {
        queue.async { [self] in
            selectedFiles.insert(fileIndex)
            applySelection()
        }
    }

    public func stats() async -> TorrentStats {
        await withCheckedContinuation { (c: CheckedContinuation<TorrentStats, Never>) in
            queue.async { [self] in c.resume(returning: makeStats()) }
        }
    }

    public func availability(of fileIndices: [Int]) async -> [Int: FileAvailability] {
        await withCheckedContinuation { (c: CheckedContinuation<[Int: FileAvailability], Never>) in
            queue.async { [self] in c.resume(returning: computeAvailability(fileIndices)) }
        }
    }

    private func computeAvailability(_ fileIndices: [Int]) -> [Int: FileAvailability] {
        guard let info else { return [:] }
        let webSeeded = webSeeds.contains { !$0.disabled }
        let connected = peers.values.filter { $0.handshaken && ($0.hasAll || ($0.have?.setCount ?? 0) > 0) }
        var out: [Int: FileAvailability] = [:]
        for f in fileIndices where info.files.indices.contains(f) {
            var a = FileAvailability()
            a.webSeeded = webSeeded
            guard let range = info.pieceRange(for: info.files[f]) else {
                out[f] = a
                continue
            }
            for peer in connected {
                if peer.hasAll || peer.have?.isComplete == true {
                    a.seeds += 1
                    continue
                }
                var any = false
                var all = true
                for i in range {
                    if peer.has(i) { any = true } else { all = false }
                    if any && !all { break }
                }
                if all { a.seeds += 1 } else if any { a.peers += 1 }
            }
            out[f] = a
        }
        return out
    }

    /// The parts of a file that are downloaded, as fractions of its length,
    /// in order and merged.
    public func downloadedRanges(of fileIndex: Int) async -> [ClosedRange<Double>] {
        await withCheckedContinuation { (c: CheckedContinuation<[ClosedRange<Double>], Never>) in
            queue.async { [self] in
                guard let info, info.files.indices.contains(fileIndex) else { return c.resume(returning: []) }
                let file = info.files[fileIndex]
                guard file.length > 0, let range = info.pieceRange(for: file) else { return c.resume(returning: []) }
                var out: [ClosedRange<Double>] = []
                var runStart: Int64?
                func close(at end: Int64) {
                    guard let start = runStart else { return }
                    let lo = Double(max(0, start - file.offset)) / Double(file.length)
                    let hi = Double(min(file.length, end - file.offset)) / Double(file.length)
                    if hi > lo { out.append(lo...hi) }
                    runStart = nil
                }
                for i in range {
                    let pieceStart = info.pieceOffset(i)
                    if have[i] {
                        if runStart == nil { runStart = pieceStart }
                    } else {
                        close(at: pieceStart)
                    }
                }
                close(at: file.offset + file.length)
                c.resume(returning: out)
            }
        }
    }

    /// Reads up to `maxLength` bytes of a file, waiting for the piece that
    /// holds `offset` and moving the stream's priority window there. Returns
    /// at most to the end of that piece.
    public func read(fileIndex: Int, offset: Int64, maxLength: Int, streamID: UUID) async throws -> Data {
        let plan: (piece: Int, start: Int64, length: Int) = try await onQueue { [self] in
            if stopped { throw TorrentError.stopped }
            guard let info else { throw TorrentError.noSuchFile }
            guard info.files.indices.contains(fileIndex) else { throw TorrentError.noSuchFile }
            let file = info.files[fileIndex]
            guard offset >= 0, offset < file.length else { throw TorrentError.noSuchFile }
            let start = file.offset + offset
            let piece = info.piece(containing: start)
            let pieceEnd = info.pieceOffset(piece) + Int64(info.pieceSize(piece))
            let length = Int(min(Int64(maxLength), file.length - offset, pieceEnd - start))
            setHead(streamID, piece: piece)
            if !have[piece] {
                if !selectedFiles.contains(fileIndex) {
                    selectedFiles.insert(fileIndex)
                    applySelection()
                } else {
                    kick()
                }
            }
            return (piece, start, length)
        }
        try await waitForPiece(plan.piece)
        return try await onQueue { [self] in
            guard let storage else { throw TorrentError.stopped }
            return Data(try storage.read(at: plan.start, length: plan.length))
        }
    }

    /// The whole of a (small) file, e.g. a subtitle.
    public func readFile(fileIndex: Int) async throws -> Data {
        let info = try await waitForMetadata()
        guard info.files.indices.contains(fileIndex) else { throw TorrentError.noSuchFile }
        let file = info.files[fileIndex]
        want(fileIndex: fileIndex)
        let id = UUID()
        defer { endStream(id) }
        var out = Data()
        var offset: Int64 = 0
        while offset < file.length {
            let chunk = try await read(fileIndex: fileIndex, offset: offset, maxLength: 1 << 20, streamID: id)
            out.append(chunk)
            offset += Int64(chunk.count)
        }
        return out
    }

    /// Ends a reader's claim on the priority window.
    public func endStream(_ streamID: UUID) {
        queue.async { [self] in
            if heads.removeValue(forKey: streamID) != nil { orderDirty = true }
        }
    }

    // MARK: - Metadata

    private func obtained(_ info: TorrentInfo) {
        self.info = info
        displayName = info.name
        directory.saveInfo(info)
        do {
            storage = try BlobStorage(url: directory.dataURL, length: info.totalLength)
        } catch {
            fail(error.localizedDescription)
            return
        }
        have = directory.loadHave(pieceCount: info.pieceCount) ?? Bitfield(count: info.pieceCount)
        wanted = [Bool](repeating: false, count: info.pieceCount)
        webSeeds = webSeedURLs.map { WebSeed(base: $0) }
        for peer in peers.values { resolveBitfield(peer) }
        for w in metadataWaiters { w.resume(returning: info) }
        metadataWaiters.removeAll()
        applySelection()
        for peer in peers.values where peer.handshaken {
            if have.setCount > 0 { peer.connection.send(.bitfield(have.bytes)) }
            updateInterest(peer)
        }
    }

    private func resolveBitfield(_ peer: Peer) {
        guard let info else { return }
        if let raw = peer.rawBitfield {
            peer.have = Bitfield(bytes: raw, count: info.pieceCount)
            peer.rawBitfield = nil
        }
        if peer.have == nil { peer.have = Bitfield(count: info.pieceCount) }
        for i in peer.earlyHaves where i < info.pieceCount { peer.have?[i] = true }
        peer.earlyHaves.removeAll()
    }

    private func requestMetadata(from peer: Peer) {
        guard info == nil, let theirID = peer.extensionIDs["ut_metadata"], let size = peer.metadataSize else { return }
        if metadataSize == nil {
            metadataSize = size
            metadataPieces = Array(repeating: nil, count: (size + Self.blockSize - 1) / Self.blockSize)
        }
        guard size == metadataSize else { return }
        let now = Date()
        var sent = 0
        for i in metadataPieces.indices where metadataPieces[i] == nil {
            if let t = peer.metadataRequests[i], now.timeIntervalSince(t) < 10 { continue }
            if let t = metadataRequestedAt[i], now.timeIntervalSince(t) < 4 { continue }
            let msg = Bencode.encode(.dict(["msg_type": .int(0), "piece": .int(Int64(i))]))
            peer.connection.send(.extended(id: theirID, payload: msg))
            peer.metadataRequests[i] = now
            metadataRequestedAt[i] = now
            sent += 1
            if sent >= 4 { break }
        }
    }

    private func handleMetadataMessage(_ peer: Peer, _ payload: [UInt8]) {
        guard let (dict, consumed) = try? Bencode.decodePrefix(payload),
              let type = dict["msg_type"]?.intValue,
              let pieceValue = dict["piece"]?.intValue, pieceValue >= 0
        else { return }
        let piece = Int(pieceValue)
        switch type {
        case 0:
            guard let theirID = peer.extensionIDs["ut_metadata"] else { return }
            if let info, piece * Self.blockSize < info.rawInfo.count {
                let start = piece * Self.blockSize
                let chunk = info.rawInfo[start..<min(start + Self.blockSize, info.rawInfo.count)]
                let header = Bencode.encode(.dict([
                    "msg_type": .int(1), "piece": .int(Int64(piece)), "total_size": .int(Int64(info.rawInfo.count)),
                ]))
                peer.connection.send(.extended(id: theirID, payload: header + chunk))
            } else {
                let reject = Bencode.encode(.dict(["msg_type": .int(2), "piece": .int(Int64(piece))]))
                peer.connection.send(.extended(id: theirID, payload: reject))
            }
        case 1:
            peer.metadataRequests[piece] = nil
            guard info == nil, let size = metadataSize, piece < metadataPieces.count, metadataPieces[piece] == nil else { return }
            let data = Array(payload[consumed...])
            let expected = piece == metadataPieces.count - 1 ? size - piece * Self.blockSize : Self.blockSize
            guard data.count == expected else { return }
            metadataPieces[piece] = data
            if metadataPieces.allSatisfy({ $0 != nil }) {
                let raw = metadataPieces.flatMap { $0! }
                if SHA1Digest.hash(raw) == infoHash, let parsed = try? TorrentInfo(rawInfo: raw) {
                    obtained(parsed)
                } else {
                    metadataPieces = Array(repeating: nil, count: metadataPieces.count)
                    metadataRequestedAt.removeAll()
                }
            } else {
                requestMetadata(from: peer)
            }
        case 2:
            peer.metadataRequests[piece] = nil
            metadataRequestedAt[piece] = nil
        default:
            break
        }
    }

    // MARK: - Selection and priorities

    private func applySelection() {
        guard let info, !stopped else { return }
        wanted = [Bool](repeating: false, count: info.pieceCount)
        pinned.removeAll()
        for f in selectedFiles where info.files.indices.contains(f) {
            let file = info.files[f]
            guard let range = info.pieceRange(for: file) else { continue }
            for i in range { wanted[i] = true }
            // The first piece and the last megabyte: players read a file's
            // header first, and an MP4 may keep its index at the very end.
            pinned.insert(range.lowerBound)
            let tailStart = info.piece(containing: file.offset + max(0, file.length - (1 << 20)))
            for i in tailStart...range.upperBound { pinned.insert(i) }
        }
        wantedTotal = wanted.lazy.filter { $0 }.count
        wantedRemaining = wanted.indices.lazy.filter { self.wanted[$0] && !self.have[$0] }.count
        orderDirty = true
        for peer in peers.values { updateInterest(peer) }
        kick()
    }

    private func setHead(_ id: UUID, piece: Int) {
        if heads[id]?.piece != piece { orderDirty = true }
        heads[id] = StreamHead(piece: piece, updated: Date())
        lastHeadPiece = piece
    }

    /// Pieces still wanted, most urgent first: each reader's window, then the
    /// pinned header/tail pieces, then everything else from the play position on.
    private func rebuildOrder() {
        orderDirty = false
        guard let info else { return }
        let n = info.pieceCount
        var mark = [Bool](repeating: false, count: n)
        var out: [Int] = []
        out.reserveCapacity(wantedRemaining)
        var crit = Set<Int>()
        func add(_ i: Int, critical c: Bool) {
            guard i >= 0, i < n, wanted[i], !have[i], !mark[i] else { return }
            mark[i] = true
            out.append(i)
            if c { crit.insert(i) }
        }
        let window = max(4, config.streamWindowBytes / info.pieceLength)
        let recent = heads.values.sorted { $0.updated > $1.updated }
        for head in recent {
            for i in head.piece..<min(n, head.piece + window) { add(i, critical: true) }
        }
        for p in pinned.sorted() { add(p, critical: true) }
        let start = recent.first?.piece ?? lastHeadPiece ?? 0
        for i in start..<n { add(i, critical: false) }
        for i in 0..<min(start, n) { add(i, critical: false) }
        order = out
        critical = crit
    }

    // MARK: - Requesting blocks

    private func requestTarget(_ peer: Peer) -> Int {
        let byRate = Int(peer.download.rate() * 3 / Double(Self.blockSize))
        return min(peer.maxRequests, max(16, min(500, byRate)))
    }

    private func fillRequests(_ peer: Peer) {
        guard let info, !stopped, peer.handshaken, !peer.peerChoking, peer.amInterested else { return }
        if orderDirty { rebuildOrder() }
        var budget = requestTarget(peer) - peer.outstanding.count
        guard budget > 0 else { return }
        let now = Date()
        var batch: [BlockRequest] = []
        for idx in order {
            if budget <= 0 { break }
            if have[idx] || !peer.has(idx) { continue }
            let isCritical = critical.contains(idx)
            let pp: PieceProgress
            if let existing = progress[idx] {
                pp = existing
                if pp.unassigned == 0 && !isCritical { continue }
                if pp.webSeedFetching && !isCritical { continue }
            } else {
                pp = PieceProgress(index: idx, size: info.pieceSize(idx))
                progress[idx] = pp
            }
            for b in 0..<pp.blocks.count {
                if budget <= 0 { break }
                let req = BlockRequest(piece: idx, begin: b * Self.blockSize, length: pp.blockLength(b))
                switch pp.blocks[b] {
                case .missing:
                    pp.blocks[b] = .requested(count: 1, since: now)
                    pp.unassigned -= 1
                case .requested(let count, let since):
                    // Near the play position, re-ask a second peer for a block
                    // the first is slow to send.
                    guard isCritical, count < 2, now.timeIntervalSince(since) > 2, peer.outstanding[req] == nil else { continue }
                    pp.blocks[b] = .requested(count: count + 1, since: since)
                case .received:
                    continue
                }
                peer.outstanding[req] = now
                batch.append(req)
                budget -= 1
            }
        }
        for r in batch { peer.connection.send(.request(r)) }
    }

    private func release(_ req: BlockRequest) {
        guard let pp = progress[req.piece] else { return }
        let b = req.begin / Self.blockSize
        guard b < pp.blocks.count, case .requested(let count, let since) = pp.blocks[b] else { return }
        if count <= 1 {
            pp.blocks[b] = .missing
            pp.unassigned += 1
        } else {
            pp.blocks[b] = .requested(count: count - 1, since: since)
        }
    }

    private func releaseAll(_ peer: Peer) {
        for r in peer.outstanding.keys { release(r) }
        peer.outstanding.removeAll()
    }

    private func handleBlock(_ peer: Peer, index: Int, begin: Int, data: [UInt8]) {
        guard let info, let storage, index >= 0, index < info.pieceCount else { return }
        let req = BlockRequest(piece: index, begin: begin, length: data.count)
        peer.outstanding.removeValue(forKey: req)
        peer.download.add(data.count)
        download.add(data.count)
        peer.lastBlockAt = Date()
        defer { fillRequests(peer) }
        guard !have[index], let pp = progress[index], begin % Self.blockSize == 0 else { return }
        let b = begin / Self.blockSize
        guard b < pp.blocks.count, data.count == pp.blockLength(b) else { return }
        switch pp.blocks[b] {
        case .received: return
        case .missing: pp.unassigned -= 1
        case .requested: break
        }
        do {
            try storage.write(data, at: info.pieceOffset(index) + Int64(begin))
        } catch {
            fail(error.localizedDescription)
            return
        }
        pp.blocks[b] = .received
        pp.received += 1
        pp.lastProgress = Date()
        pp.contributors.insert(ObjectIdentifier(peer.connection))
        for other in peers.values where other !== peer && other.outstanding.removeValue(forKey: req) != nil {
            other.connection.send(.cancel(req))
        }
        if pp.received == pp.blocks.count { verifyFromDisk(index) }
    }

    private func verifyFromDisk(_ index: Int) {
        guard let info, let storage, let pp = progress[index] else { return }
        let ok: Bool
        do {
            let data = try storage.read(at: info.pieceOffset(index), length: info.pieceSize(index))
            ok = SHA1Digest.hash(data) == info.pieceHashes[index]
        } catch {
            ok = false
        }
        if ok {
            pieceVerified(index)
        } else {
            hashFailures += 1
            for id in pp.contributors {
                if let peer = peers[id] {
                    peer.hashFailures += 1
                    if peer.hashFailures >= 3 { peer.connection.close(reason: "sent corrupt data") }
                }
            }
            progress[index] = PieceProgress(index: index, size: pp.size)
        }
    }

    private func pieceVerified(_ index: Int) {
        guard !have[index] else { return }
        have[index] = true
        haveDirty = true
        progress[index] = nil
        if wanted.indices.contains(index), wanted[index] { wantedRemaining -= 1 }
        for peer in peers.values where peer.handshaken {
            let stale = peer.outstanding.keys.filter { $0.piece == index }
            for r in stale {
                peer.outstanding[r] = nil
                peer.connection.send(.cancel(r))
            }
            if !peer.has(index) { peer.connection.send(.have(index)) }
        }
        if let waiters = pieceWaiters.removeValue(forKey: index) {
            for w in waiters { w.continuation.resume() }
        }
        if wantedRemaining == 0 {
            for peer in peers.values { updateInterest(peer) }
            directory.saveHave(have)
            haveDirty = false
        }
    }

    private func updateInterest(_ peer: Peer) {
        guard info != nil, peer.handshaken else { return }
        var interesting = false
        if wantedRemaining > 0 {
            if peer.hasAll {
                interesting = true
            } else if peer.have != nil {
                if orderDirty { rebuildOrder() }
                interesting = order.contains { !have[$0] && peer.has($0) }
            }
        }
        if interesting != peer.amInterested {
            peer.amInterested = interesting
            peer.connection.send(interesting ? .interested : .notInterested)
        }
        if interesting { fillRequests(peer) }
    }

    /// Something changed that may open new work: fill every pipe.
    private func kick() {
        for peer in peers.values { fillRequests(peer) }
        scheduleWebSeeds()
    }

    // MARK: - Web seeds

    private func scheduleWebSeeds() {
        guard let info, !stopped, wantedRemaining > 0 else { return }
        for ws in webSeeds where !ws.disabled {
            while ws.active < ws.maxConcurrent, let piece = pickWebSeedPiece() {
                startWebSeedFetch(ws, piece: piece, info: info)
            }
        }
    }

    private func pickWebSeedPiece() -> Int? {
        if orderDirty { rebuildOrder() }
        let now = Date()
        for idx in order where !have[idx] {
            guard let pp = progress[idx] else { return idx }
            if pp.webSeedFetching { continue }
            if pp.unassigned == pp.blocks.count && pp.received == 0 { return idx }
            // A piece the player needs now that peers are slow to finish.
            if critical.contains(idx) && now.timeIntervalSince(pp.lastProgress) > 4 { return idx }
        }
        return nil
    }

    private func startWebSeedFetch(_ ws: WebSeed, piece: Int, info: TorrentInfo) {
        let pp = progress[piece] ?? PieceProgress(index: piece, size: info.pieceSize(piece))
        progress[piece] = pp
        pp.webSeedFetching = true
        ws.active += 1
        let taskID = UUID()
        webSeedTasks[taskID] = Task { [weak self] in
            let result: Result<[UInt8], Error>
            do { result = .success(try await ws.fetch(piece: piece, info: info)) } catch { result = .failure(error) }
            self?.queue.async { self?.webSeedFinished(ws, piece: piece, taskID: taskID, result: result) }
        }
    }

    private func webSeedFinished(_ ws: WebSeed, piece: Int, taskID: UUID, result: Result<[UInt8], Error>) {
        webSeedTasks[taskID] = nil
        ws.active -= 1
        guard !stopped, let info, let storage else { return }
        progress[piece]?.webSeedFetching = false
        switch result {
        case .success(let data):
            download.add(data.count)
            ws.consecutiveFailures = 0
            if have[piece] { break }
            if SHA1Digest.hash(data) == info.pieceHashes[piece] {
                ws.successes += 1
                do { try storage.write(data, at: info.pieceOffset(piece)) } catch {
                    fail(error.localizedDescription)
                    return
                }
                pieceVerified(piece)
            } else {
                hashFailures += 1
                ws.hashFailures += 1
                // The files on the server no longer match the torrent.
                if ws.hashFailures >= 3 { ws.disabled = true }
            }
        case .failure:
            ws.consecutiveFailures += 1
            if ws.consecutiveFailures >= (ws.successes == 0 ? 3 : 8) { ws.disabled = true }
        }
        scheduleWebSeeds()
    }

    // MARK: - Reading

    private func onQueue<T>(_ body: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<T, Error>) in
            queue.async { c.resume(with: Result { try body() }) }
        }
    }

    private func waitForPiece(_ piece: Int) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                queue.async { [self] in
                    if cancelledWaits.remove(id) != nil {
                        c.resume(throwing: CancellationError())
                    } else if stopped {
                        c.resume(throwing: TorrentError.stopped)
                    } else if have.count > piece && have[piece] {
                        c.resume()
                    } else {
                        pieceWaiters[piece, default: []].append((id, c))
                    }
                }
            }
        } onCancel: {
            queue.async { [self] in
                if var list = pieceWaiters[piece], let i = list.firstIndex(where: { $0.id == id }) {
                    let w = list.remove(at: i)
                    pieceWaiters[piece] = list.isEmpty ? nil : list
                    w.continuation.resume(throwing: CancellationError())
                } else {
                    cancelledWaits.insert(id)
                }
            }
        }
    }

    // MARK: - Peers

    private func addCandidates(_ addresses: [PeerAddress]) {
        guard !stopped else { return }
        for a in addresses where candidates[a] == nil && peerByAddress[a] == nil {
            candidates[a] = Candidate()
        }
        connectMore()
    }

    private func connectMore() {
        guard !stopped, failure == nil else { return }
        let connecting = peers.values.filter { !$0.handshaken }.count
        let slots = min(config.maxPeers - peers.count, 20 - connecting)
        guard slots > 0 else { return }
        let now = Date()
        let eligible = candidates.filter { addr, c in
            guard peerByAddress[addr] == nil else { return false }
            guard let last = c.lastAttempt else { return true }
            let backoff = c.failures == 0 ? 30.0 : 60.0 * Double(1 << min(c.failures, 5))
            return now.timeIntervalSince(last) > backoff
        }
        .sorted { ($0.value.lastAttempt ?? .distantPast) < ($1.value.lastAttempt ?? .distantPast) }
        for (addr, _) in eligible.prefix(slots) { connect(addr) }
    }

    private func connect(_ addr: PeerAddress) {
        candidates[addr]?.lastAttempt = Date()
        let conn = PeerConnection(address: addr, infoHash: infoHash, peerID: peerID, queue: queue)
        let peer = Peer(connection: conn)
        conn.delegate = self
        peers[ObjectIdentifier(conn)] = peer
        peerByAddress[addr] = peer
        conn.start()
    }

    private func tick() {
        guard !stopped else { return }
        tickCount += 1
        let now = Date()

        for peer in Array(peers.values) {
            if !peer.handshaken {
                if now.timeIntervalSince(peer.createdAt) > 20 { peer.connection.close(reason: "handshake timeout") }
                continue
            }
            let expired = peer.outstanding.filter { now.timeIntervalSince($0.value) > 25 }.map(\.key)
            for r in expired {
                peer.outstanding[r] = nil
                release(r)
                peer.connection.send(.cancel(r))
            }
            if !peer.outstanding.isEmpty && now.timeIntervalSince(peer.lastBlockAt) > 45 {
                peer.connection.close(reason: "snubbed")
                continue
            }
            if now.timeIntervalSince(peer.connection.lastReceived) > 180 {
                peer.connection.close(reason: "idle")
                continue
            }
            if now.timeIntervalSince(peer.connection.lastSent) > 100 { peer.connection.send(.keepAlive) }
            if info == nil { requestMetadata(from: peer) }
        }

        // A reader that vanished without saying goodbye.
        for (id, head) in heads where now.timeIntervalSince(head.updated) > 300 {
            heads[id] = nil
            orderDirty = true
        }

        if tickCount % 10 == 0 {
            for peer in peers.values { updateInterest(peer) }
        }
        kick()
        connectMore()

        if let dht, dht.isIdle, peers.count < config.maxPeers / 2, now.timeIntervalSince(lastDHTRestart) > 120 {
            lastDHTRestart = now
            dht.restart()
        }
        if haveDirty, now.timeIntervalSince(lastHaveSave) > 10 {
            directory.saveHave(have)
            haveDirty = false
            lastHaveSave = now
        }
    }

    private func fail(_ message: String) {
        failure = message
        for w in metadataWaiters { w.resume(throwing: TorrentError.storage(message)) }
        metadataWaiters.removeAll()
        for list in pieceWaiters.values { for w in list { w.continuation.resume(throwing: TorrentError.storage(message)) } }
        pieceWaiters.removeAll()
    }

    // MARK: - Trackers

    private func startTrackers() {
        var urls = trackerURLs
        if isMagnet && config.usePublicTrackers && !(info?.isPrivate ?? false) {
            for t in defaultPublicTrackers where !urls.contains(t) { urls.append(t) }
        }
        for url in urls {
            guard let tracker = makeTracker(url) else { continue }
            trackerTasks.append(Task { [weak self] in await self?.runTracker(tracker) })
        }
    }

    private func announceRequest(_ event: AnnounceEvent) -> AnnounceRequest {
        var left: Int64 = 16 * 1024 * 1024
        if let info {
            left = max(0, info.totalLength - Int64(have.setCount) * Int64(info.pieceLength))
        }
        return AnnounceRequest(
            infoHash: infoHash, peerID: peerID, port: config.announcePort,
            uploaded: upload.total, downloaded: download.total, left: left,
            event: event, key: announceKey
        )
    }

    private func runTracker(_ tracker: Tracker) async {
        var event = AnnounceEvent.started
        var failures = 0
        while !Task.isCancelled {
            guard let request = try? await onQueue({ [self] in announceRequest(event) }) else { return }
            var wait: Int
            do {
                let response = try await tracker.announce(request)
                failures = 0
                event = .none
                let peerCount = (try? await onQueue { [self] () -> Int in
                    swarm[tracker.url] = (response.seeders, response.leechers)
                    addCandidates(response.peers)
                    return peers.count
                }) ?? 0
                wait = max(60, peerCount < 10 ? min(response.interval, 120) : min(response.interval, 1800))
            } catch {
                failures += 1
                wait = min(1800, 15 * (1 << min(failures, 7)))
            }
            try? await Task.sleep(nanoseconds: UInt64(wait) * 1_000_000_000)
        }
    }

    private func announceStopped() {
        let request = announceRequest(.stopped)
        let urls = Array(swarm.keys)
        Task.detached {
            for url in urls {
                guard let tracker = makeTracker(url) else { continue }
                _ = try? await tracker.announce(request)
            }
        }
    }

    // MARK: - Stats

    private func makeStats() -> TorrentStats {
        var s = TorrentStats()
        if stopped {
            s.phase = .stopped
        } else if let failure {
            s.phase = .failed(failure)
        } else if info == nil {
            s.phase = .fetchingMetadata
        } else if wantedTotal > 0 && wantedRemaining == 0 {
            s.phase = .complete
        } else {
            s.phase = .downloading
        }
        s.name = displayName
        s.downloadRate = download.rate()
        s.uploadRate = upload.rate()
        s.downloaded = download.total
        s.uploaded = upload.total
        s.connectedPeers = peers.values.filter(\.handshaken).count
        s.activePeers = peers.values.filter { $0.handshaken && !$0.peerChoking && $0.download.rate() > 0 }.count
        s.knownPeers = candidates.count
        let seeders = swarm.values.compactMap(\.seeders)
        let leechers = swarm.values.compactMap(\.leechers)
        s.seeders = seeders.max()
        s.leechers = leechers.max()
        s.activeWebSeeds = webSeeds.filter { !$0.disabled }.count
        s.hashFailures = hashFailures
        if let info {
            s.piecesHave = have.setCount
            s.piecesTotal = info.pieceCount
            if wantedTotal > 0 { s.selectedProgress = Double(wantedTotal - wantedRemaining) / Double(wantedTotal) }
            let start = heads.values.max { $0.updated < $1.updated }?.piece ?? lastHeadPiece ?? firstSelectedPiece() ?? 0
            var i = start
            var bytes: Int64 = 0
            while i < info.pieceCount && have[i] && (wanted.indices.contains(i) && wanted[i]) {
                bytes += Int64(info.pieceSize(i))
                i += 1
            }
            s.bufferedAhead = bytes
        }
        return s
    }

    private func firstSelectedPiece() -> Int? {
        guard let info else { return nil }
        return selectedFiles.compactMap { info.files.indices.contains($0) ? info.pieceRange(for: info.files[$0])?.lowerBound : nil }.min()
    }
}

// MARK: - Peer events

extension TorrentSession: PeerConnectionDelegate {
    func peerConnectionDidConnect(_ connection: PeerConnection) {}

    func peerConnection(_ connection: PeerConnection, didHandshake remoteID: [UInt8], reserved: [UInt8]) {
        guard let peer = peers[ObjectIdentifier(connection)] else { return }
        if remoteID == peerID {
            connection.close(reason: "connected to self")
            return
        }
        peer.handshaken = true
        peer.supportsExtensions = reserved[5] & 0x10 != 0
        candidates[connection.address]?.failures = 0
        if info != nil {
            if have.setCount > 0 { connection.send(.bitfield(have.bytes)) }
            resolveBitfield(peer)
        }
        if peer.supportsExtensions {
            var d: [String: BValue] = [
                "m": .dict(["ut_metadata": .int(Int64(Self.utMetadataID))]),
                "v": .string("Bobcorn 1.0"),
                "reqq": .int(500),
            ]
            if let info { d["metadata_size"] = .int(Int64(info.rawInfo.count)) }
            connection.send(.extended(id: 0, payload: Bencode.encode(.dict(d))))
        } else if info == nil {
            connection.close(reason: "cannot send metadata")
        }
    }

    func peerConnection(_ connection: PeerConnection, didReceive message: PeerMessage) {
        guard let peer = peers[ObjectIdentifier(connection)], !stopped else { return }
        switch message {
        case .keepAlive, .port, .unknown:
            break
        case .choke:
            peer.peerChoking = true
            releaseAll(peer)
        case .unchoke:
            peer.peerChoking = false
            fillRequests(peer)
        case .interested:
            peer.peerInterested = true
            let unchoked = peers.values.filter { !$0.amChoking }.count
            if info != nil && peer.amChoking && unchoked < 6 {
                peer.amChoking = false
                connection.send(.unchoke)
            }
        case .notInterested:
            peer.peerInterested = false
            if !peer.amChoking {
                peer.amChoking = true
                connection.send(.choke)
            }
        case .have(let i):
            if let info {
                guard i < info.pieceCount else { return }
                peer.have?[i] = true
                if !peer.amInterested && wanted[i] && !have[i] {
                    updateInterest(peer)
                } else if peer.amInterested {
                    fillRequests(peer)
                }
            } else {
                peer.earlyHaves.append(i)
            }
        case .bitfield(let bits):
            peer.rawBitfield = bits
            if info != nil {
                resolveBitfield(peer)
                updateInterest(peer)
            }
        case .haveAll:
            peer.hasAll = true
            updateInterest(peer)
        case .haveNone:
            break
        case .request(let r):
            serve(r, to: peer)
        case .piece(let index, let begin, let data):
            handleBlock(peer, index: index, begin: begin, data: data)
        case .cancel:
            break
        case .reject(let r):
            if peer.outstanding.removeValue(forKey: r) != nil { release(r) }
        case .extended(let id, let payload):
            if id == 0 {
                handleExtendedHandshake(peer, payload)
            } else if id == Self.utMetadataID {
                handleMetadataMessage(peer, payload)
            }
        }
    }

    func peerConnectionDidClose(_ connection: PeerConnection, reason: String) {
        guard let peer = peers.removeValue(forKey: ObjectIdentifier(connection)) else { return }
        peerByAddress[connection.address] = nil
        releaseAll(peer)
        for i in peer.metadataRequests.keys { metadataRequestedAt[i] = nil }
        if !peer.handshaken {
            candidates[connection.address]?.failures += 1
            if (candidates[connection.address]?.failures ?? 0) >= 4 { candidates[connection.address] = nil }
        }
        connectMore()
    }

    private func handleExtendedHandshake(_ peer: Peer, _ payload: [UInt8]) {
        guard let (d, _) = try? Bencode.decodePrefix(payload) else { return }
        if let m = d["m"]?.dictValue {
            for (name, value) in m {
                guard let id = value.intValue else { continue }
                if id > 0 && id < 256 {
                    peer.extensionIDs[name] = UInt8(id)
                } else {
                    peer.extensionIDs[name] = nil
                }
            }
        }
        if let size = d["metadata_size"]?.intValue, size > 0, size < 32 * 1024 * 1024 {
            peer.metadataSize = Int(size)
        }
        if let q = d["reqq"]?.intValue, q > 0 { peer.maxRequests = min(Int(q), 500) }
        peer.clientName = d["v"]?.stringValue
        if info == nil { requestMetadata(from: peer) }
    }

    private func serve(_ r: BlockRequest, to peer: Peer) {
        guard let info, let storage, !peer.amChoking,
              r.piece >= 0, r.piece < info.pieceCount, have[r.piece],
              r.length > 0, r.length <= 32 * 1024, r.begin >= 0,
              r.begin + r.length <= info.pieceSize(r.piece),
              let data = try? storage.read(at: info.pieceOffset(r.piece) + Int64(r.begin), length: r.length)
        else { return }
        peer.connection.send(.piece(index: r.piece, begin: r.begin, data: data))
        peer.upload.add(data.count)
        upload.add(data.count)
    }
}

// MARK: - Bookkeeping types

final class Peer {
    let connection: PeerConnection
    let createdAt = Date()
    var handshaken = false
    var supportsExtensions = false
    var extensionIDs: [String: UInt8] = [:]
    var metadataSize: Int?
    var clientName: String?
    var maxRequests = 250

    var peerChoking = true
    var peerInterested = false
    var amChoking = true
    var amInterested = false

    var have: Bitfield?
    var rawBitfield: [UInt8]?
    var earlyHaves: [Int] = []
    var hasAll = false

    var outstanding: [BlockRequest: Date] = [:]
    var download = RateMeter()
    var upload = RateMeter()
    var lastBlockAt = Date()
    var metadataRequests: [Int: Date] = [:]
    var hashFailures = 0

    init(connection: PeerConnection) {
        self.connection = connection
    }

    func has(_ piece: Int) -> Bool {
        if hasAll { return true }
        guard let have, piece < have.count else { return false }
        return have[piece]
    }
}

final class PieceProgress {
    enum BlockState {
        case missing
        case requested(count: Int, since: Date)
        case received
    }

    let index: Int
    let size: Int
    var blocks: [BlockState]
    var unassigned: Int
    var received = 0
    var webSeedFetching = false
    var lastProgress = Date()
    var contributors: Set<ObjectIdentifier> = []

    init(index: Int, size: Int) {
        self.index = index
        self.size = size
        let count = (size + TorrentSession.blockSize - 1) / TorrentSession.blockSize
        blocks = Array(repeating: .missing, count: count)
        unassigned = count
    }

    func blockLength(_ b: Int) -> Int {
        min(TorrentSession.blockSize, size - b * TorrentSession.blockSize)
    }
}
