import Foundation
import GRDB

/// Records when and where a node was observed. Used for proximity-based trust.
struct NodeSighting: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "nodeSightings"

    var id: Int64?          // auto-increment rowid
    var nodeID: String      // FK → contacts.id
    var lat: Double
    var lon: Double
    var timestamp: Int64    // unix timestamp (seconds)
    var rssi: Int

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
