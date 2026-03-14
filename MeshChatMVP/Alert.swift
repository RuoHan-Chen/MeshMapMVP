import Foundation
import GRDB

struct Alert: Codable, FetchableRecord, PersistableRecord, Identifiable {
    static let databaseTableName = "alerts"

    var id: String
    var authorID: String    // FK → contacts.id
    var type: AlertType
    var severity: Int       // 1 = low, 2 = medium, 3 = high
    var lat: Double
    var lon: Double
    var description: String
    var createdAt: Int64    // unix timestamp (seconds)
    var expiresAt: Int64    // unix timestamp (seconds)
    var trustScore: Double  // 0.0–1.0, computed and cached

    enum AlertType: String, Codable {
        case hazard  // negative — danger, threat
        case aid     // positive — help, resources
        case other   // neutral — info
    }

    var isExpired: Bool {
        Int64(Date().timeIntervalSince1970) > expiresAt
    }

    /// Default expiry offset in seconds based on alert type.
    static func defaultExpiresAt(for type: AlertType) -> Int64 {
        let offset: Int64
        switch type {
        case .hazard: offset = 6 * 3600    // 6 hours
        case .aid:    offset = 24 * 3600   // 24 hours
        case .other:  offset = 12 * 3600   // 12 hours
        }
        return Int64(Date().timeIntervalSince1970) + offset
    }
}
