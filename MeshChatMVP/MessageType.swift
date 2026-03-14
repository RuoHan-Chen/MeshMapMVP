import Foundation

/// Wire message kinds — aligned with BitChat-style announce + chat only (MVP).
enum MessageType: UInt8, Codable, CaseIterable {
    case announce = 1
    case message = 2
    /// Chunked JPEG over mesh (each chunk is its own envelope ≤512 B; same transferId).
    case imageChunk = 3
}
