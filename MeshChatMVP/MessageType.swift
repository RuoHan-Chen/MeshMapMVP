import Foundation

/// Wire message kinds.
enum MessageType: UInt8, Codable, CaseIterable {
    case announce      = 1
    case message       = 2
    case alert         = 3
    case vouch         = 4
    case mapLabel      = 5
    case mapLabelVote  = 6
}
