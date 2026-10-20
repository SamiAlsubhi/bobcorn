import Foundation
import Remux
import TorrentKit

/// A torrent's file as the remuxer reads it: a read waits for its piece, and
/// each reader's stream moves the download window to where it reads.
struct TorrentByteSource: ByteSource {
    let session: TorrentSession
    let file: TorrentFile

    var length: Int64 { file.length }

    func read(at offset: Int64, count: Int, stream: UUID) async throws -> Data {
        guard offset < file.length else { return Data() }
        return try await session.read(fileIndex: file.index, offset: offset, maxLength: count, streamID: stream)
    }

    func finish(stream: UUID) {
        session.endStream(stream)
    }
}

extension TorrentFile {
    /// Plays in Bobcorn's own player: as it is, or remuxed from Matroska.
    var playsInApp: Bool { isNativelyPlayable || HLSRemuxer.fileExtensions.contains(fileExtension) }
}
