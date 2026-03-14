import Foundation

/// Wire payload for a `.vouch` envelope.
struct VouchPayload: Codable {
    var alertID: String
    var value: Int  // 1 = confirms, -1 = denies
}
