import Foundation

/// Wire payload for a `.alert` envelope.
struct AlertPayload: Codable {
    var alertID: String
    var type: Alert.AlertType
    var severity: Int
    var lat: Double
    var lon: Double
    var description: String
    var createdAt: Int64    // unix timestamp (seconds)
    var expiresAt: Int64    // unix timestamp (seconds)
}
