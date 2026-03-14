import Foundation

/// Wire message kinds.
enum MessageType: UInt8, Codable, CaseIterable {
    case announce = 1
    case message  = 2
    case alert    = 3   // node broadcasting an alert
    case vouch    = 4   // node confirming/denying an alert
}
