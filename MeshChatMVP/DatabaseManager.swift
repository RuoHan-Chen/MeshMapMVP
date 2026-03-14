import Foundation
import GRDB

/// Manages the SQLite database via GRDB. Thread-safe via DatabaseQueue.
final class DatabaseManager {
    static let shared = DatabaseManager()

    private let dbQueue: DatabaseQueue

    private init() {
        let url = try! FileManager.default
            .url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("mesh.sqlite")
        dbQueue = try! DatabaseQueue(path: url.path)
        try! runMigrations()
    }

    private func runMigrations() throws {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1") { db in
            try db.create(table: "contacts") { t in
                t.primaryKey("id", .text)
                t.column("nickname", .text).notNull()
                t.column("relationship", .text).notNull().defaults(to: "associate")
                t.column("firstSeen", .integer).notNull()
                t.column("lastSeen", .integer).notNull()
                t.column("publicKey", .blob)
            }

            try db.create(table: "messages") { t in
                t.primaryKey("id", .text)
                t.column("senderID", .text).notNull()
                t.column("senderName", .text).notNull()
                t.column("text", .text).notNull()
                t.column("timestamp", .integer).notNull()
                t.column("channel", .text).notNull().defaults(to: "broadcast")
                t.column("receivedAt", .integer).notNull()
            }

            try db.create(table: "alerts") { t in
                t.primaryKey("id", .text)
                t.column("authorID", .text).notNull()
                t.column("type", .text).notNull()
                t.column("severity", .integer).notNull()
                t.column("lat", .double).notNull()
                t.column("lon", .double).notNull()
                t.column("description", .text).notNull()
                t.column("createdAt", .integer).notNull()
                t.column("expiresAt", .integer).notNull()
                t.column("trustScore", .double).notNull().defaults(to: 0.0)
            }

            try db.create(table: "vouches") { t in
                t.column("alertID", .text).notNull()
                t.column("voucherID", .text).notNull()
                t.column("value", .integer).notNull()
                t.column("timestamp", .integer).notNull()
                t.primaryKey(["alertID", "voucherID"])
            }

            try db.create(table: "nodeSightings") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("nodeID", .text).notNull()
                t.column("lat", .double).notNull()
                t.column("lon", .double).notNull()
                t.column("timestamp", .integer).notNull()
                t.column("rssi", .integer).notNull()
            }
        }

        try migrator.migrate(dbQueue)
    }
}

// MARK: - Contacts (GRDB MeshContact)

extension DatabaseManager {
    /// Insert or update a contact. Preserves existing relationship level on update.
    func upsertContact(id: String, nickname: String, defaultRelationship: MeshContact.Relationship = .associate) throws {
        try dbQueue.write { db in
            let now = Int64(Date().timeIntervalSince1970)
            if var existing = try MeshContact.fetchOne(db, key: id) {
                existing.nickname = nickname
                existing.lastSeen = now
                try existing.update(db)
            } else {
                try MeshContact(id: id, nickname: nickname, relationship: defaultRelationship,
                            firstSeen: now, lastSeen: now, publicKey: nil).insert(db)
            }
        }
    }

    func setRelationship(_ relationship: MeshContact.Relationship, for contactID: String) throws {
        try dbQueue.write { db in
            if var contact = try MeshContact.fetchOne(db, key: contactID) {
                contact.relationship = relationship
                try contact.update(db)
            }
        }
    }

    func allContacts() throws -> [MeshContact] {
        try dbQueue.read { db in
            try MeshContact.order(Column("lastSeen").desc).fetchAll(db)
        }
    }

    func contact(id: String) throws -> MeshContact? {
        try dbQueue.read { db in
            try MeshContact.fetchOne(db, key: id)
        }
    }
}

// MARK: - Messages

extension DatabaseManager {
    func saveMessage(_ msg: PersistedMessage) throws {
        try dbQueue.write { db in
            try msg.insert(db, onConflict: .ignore)
        }
    }

    /// Returns messages ordered oldest → newest for display.
    func messages(channel: String = "broadcast", limit: Int = 200) throws -> [PersistedMessage] {
        try dbQueue.read { db in
            try PersistedMessage
                .filter(Column("channel") == channel)
                .order(Column("timestamp").asc)
                .limit(limit)
                .fetchAll(db)
        }
    }
}

// MARK: - Alerts

extension DatabaseManager {
    func saveAlert(_ alert: Alert) throws {
        try dbQueue.write { db in
            try alert.insert(db, onConflict: .replace)
        }
    }

    func activeAlerts() throws -> [Alert] {
        let now = Int64(Date().timeIntervalSince1970)
        return try dbQueue.read { db in
            try Alert
                .filter(Column("expiresAt") > now)
                .order(Column("createdAt").desc)
                .fetchAll(db)
        }
    }

    func alert(id: String) throws -> Alert? {
        try dbQueue.read { db in
            try Alert.fetchOne(db, key: id)
        }
    }

    /// Recomputes and persists the trust score for an alert based on its vouches.
    /// Each vouch is weighted equally for now; friends-of-friends weighting added in Phase 3.
    func recomputeTrustScore(alertID: String) throws {
        try dbQueue.write { db in
            guard var alert = try Alert.fetchOne(db, key: alertID) else { return }
            let vouches = try Vouch.filter(Column("alertID") == alertID).fetchAll(db)
            // Weight: each vouch ±0.2, clamped to [0, 1]
            let raw = vouches.reduce(0.0) { acc, v in acc + Double(v.value) * 0.2 }
            alert.trustScore = min(1.0, max(0.0, raw))
            try alert.update(db)
        }
    }
}

// MARK: - Vouches

extension DatabaseManager {
    func saveVouch(_ vouch: Vouch) throws {
        try dbQueue.write { db in
            try vouch.insert(db, onConflict: .replace)
        }
    }

    func vouches(for alertID: String) throws -> [Vouch] {
        try dbQueue.read { db in
            try Vouch.filter(Column("alertID") == alertID).fetchAll(db)
        }
    }
}

// MARK: - Node Sightings

extension DatabaseManager {
    func recordSighting(nodeID: String, lat: Double, lon: Double, rssi: Int) throws {
        var sighting = NodeSighting(
            id: nil,
            nodeID: nodeID,
            lat: lat,
            lon: lon,
            timestamp: Int64(Date().timeIntervalSince1970),
            rssi: rssi
        )
        try dbQueue.write { db in
            try sighting.insert(db)
        }
    }

    func recentSightings(for nodeID: String, limit: Int = 10) throws -> [NodeSighting] {
        try dbQueue.read { db in
            try NodeSighting
                .filter(Column("nodeID") == nodeID)
                .order(Column("timestamp").desc)
                .limit(limit)
                .fetchAll(db)
        }
    }
}
