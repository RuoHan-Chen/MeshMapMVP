import Foundation
import GRDB

/// GRDB contact row (distinct from UI `Contact` in AppModels).
struct MeshContact: Codable, FetchableRecord, PersistableRecord, Identifiable {
    static let databaseTableName = "contacts"

    var id: String          // deviceID (UUID string)
    var nickname: String
    var relationship: Relationship
    var firstSeen: Int64    // unix timestamp
    var lastSeen: Int64
    var publicKey: Data?    // reserved for future signed messages

    enum Relationship: String, Codable {
        case associate  // heard from on mesh; low trust
        case friend     // mutually vouched; high trust
    }
}
