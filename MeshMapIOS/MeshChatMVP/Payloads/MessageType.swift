import Foundation

/// Wire message kinds: map + chat image + alerts. Map label thumbnails use 9 (chat JPEG chunks stay 6).
enum MessageType: UInt8, Codable, CaseIterable {
    case announce = 1
    case message = 2
    case mapLabel = 3
    case mapLabelVote = 4
    case requestMapLabels = 5
    case imageChunk = 6
    case alert = 7
    case vouch = 8
    /// Thumbnail chunks for map labels (distinct from chat imageChunk).
    case mapLabelImageChunk = 9
    /// Signed offline payment transport payload (app-level signing). No chain settlement yet.
    case offlinePayment = 10
}
