import Foundation

/// One fragment of a JPEG sent over BLE (envelope size cap requires chunking).
struct ImageChunkPayload: Codable, Equatable {
    /// Same UUID for all chunks of one image.
    var transferId: UUID
    var chunkIndex: UInt16
    var totalChunks: UInt16
    var data: Data
}
