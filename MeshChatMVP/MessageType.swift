import Foundation

/// Wire message kinds (merged: map + mesh + alerts). Alert/vouch use 7/8 so 3–6 stay map + image.
enum MessageType: UInt8, Codable, CaseIterable {
    case announce = 1
    case message = 2
    case mapLabel = 3
    case mapLabelVote = 4
    case requestMapLabels = 5
    case imageChunk = 6
    case alert = 7
    case vouch = 8
}
