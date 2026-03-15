import Foundation
import GRDB

/// User-saved contact; **publicKey** is canonical match key. **id** is app-generated row id.
struct SavedContact: Codable, FetchableRecord, PersistableRecord, Identifiable, Equatable {
    static let databaseTableName = "saved_contacts"

    var id: String
    var nickname: String
    var relationship: String
    var firstSeen: Int64
    var lastSeen: Int64
    var publicKey: Data

    static let associate = "associate"
    static let friend = "friend"
}
