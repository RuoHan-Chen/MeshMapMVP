import Foundation

/// Wire message kinds — aligned with BitChat-style announce + chat only (MVP).
enum MessageType: UInt8, Codable, CaseIterable {
    case announce = 1
    case message = 2
    case mapLabel = 3
    case mapLabelVote = 4
    /// Chunked JPEG over mesh (envelope ≤512 B; same transferId). Raw 5 so it does not clash with map on wire.
    case imageChunk = 5
}
