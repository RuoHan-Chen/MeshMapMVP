import Foundation

/// Wire message kinds — aligned with BitChat-style announce + chat only (MVP).
enum MessageType: UInt8, Codable, CaseIterable {
    case announce = 1
    case message = 2
    case mapLabel = 3
    case mapLabelVote = 4
    /// Ask peers to flood their map labels (map branch wire value).
    case requestMapLabels = 5
    /// Chunked JPEG over mesh (raw 6 — does not clash with requestMapLabels).
    case imageChunk = 6
}
