import Foundation
import GRDB

/// A node's vote on an alert's validity.
/// Composite primary key: (alertID, voucherID) — one vouch per node per alert.
struct Vouch: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "vouches"

    var alertID: String     // FK → alerts.id
    var voucherID: String   // FK → contacts.id
    var value: Int          // 1 = confirms, -1 = denies
    var timestamp: Int64    // unix timestamp (seconds)
}
