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

        migrator.registerMigration("v2") { db in
            try db.alter(table: "messages") { t in
                t.add(column: "imageBase64", .text)
            }
        }

        migrator.registerMigration("v3_saved_contacts") { db in
            guard try !db.tableExists(SavedContact.databaseTableName) else { return }
            try db.create(table: SavedContact.databaseTableName) { t in
                t.primaryKey("id", .text)
                t.column("nickname", .text).notNull()
                t.column("relationship", .text).notNull().defaults(to: SavedContact.associate)
                t.column("firstSeen", .integer).notNull()
                t.column("lastSeen", .integer).notNull()
                t.column("publicKey", .blob).notNull()
            }
        }

        migrator.registerMigration("v4_wallet_and_offline_payments") { db in
            try db.create(table: PendingOutboundPaymentRow.databaseTableName) { t in
                t.primaryKey("id", .text)

                t.column("senderDeviceID", .text).notNull()
                t.column("senderName", .text).notNull()
                t.column("recipientDeviceID", .text).notNull()
                t.column("recipientName", .text).notNull()

                t.column("amountLamports", .integer).notNull()

                t.column("assetId", .text).notNull()
                t.column("assetSymbol", .text).notNull()
                t.column("assetDisplayName", .text).notNull()
                t.column("assetDecimals", .integer).notNull()
                t.column("assetType", .text).notNull()

                t.column("createdAt", .integer).notNull()
                t.column("receivedAt", .integer)

                t.column("status", .text).notNull()
                t.column("paymentPayloadVersion", .integer).notNull()

                // Payload signature + key for app-level claim verification.
                t.column("paymentSignature", .blob).notNull()
                t.column("paymentPublicKey", .blob).notNull()

                t.column("memo", .text)
                t.column("meshEnvelopeID", .text)
                t.column("settlementReference", .text)
            }

            try db.create(table: PendingInboundPaymentRow.databaseTableName) { t in
                t.primaryKey("id", .text)

                t.column("senderDeviceID", .text).notNull()
                t.column("senderName", .text).notNull()
                t.column("recipientDeviceID", .text).notNull()
                t.column("recipientName", .text).notNull()

                t.column("amountLamports", .integer).notNull()

                t.column("assetId", .text).notNull()
                t.column("assetSymbol", .text).notNull()
                t.column("assetDisplayName", .text).notNull()
                t.column("assetDecimals", .integer).notNull()
                t.column("assetType", .text).notNull()

                t.column("createdAt", .integer).notNull()
                t.column("receivedAt", .integer)

                t.column("status", .text).notNull()
                t.column("paymentPayloadVersion", .integer).notNull()

                t.column("paymentSignature", .blob).notNull()
                t.column("paymentPublicKey", .blob).notNull()

                t.column("memo", .text)
                t.column("meshEnvelopeID", .text)
                t.column("settlementReference", .text)
            }

            try db.create(table: SettlementEventRow.databaseTableName) { t in
                t.primaryKey("id", .text)
                t.column("pendingPaymentID", .text).notNull()
                t.column("createdAt", .integer).notNull()
                t.column("statusBefore", .text).notNull()
                t.column("statusAfter", .text).notNull()
                t.column("notes", .text).notNull()
                t.column("txSignature", .text)
            }

            try db.create(table: WalletStateCache.databaseTableName) { t in
                // Upsert by network so we can expand to other clusters later.
                t.primaryKey("network", .text)
                t.column("walletAddress", .text).notNull()
                t.column("lastKnownBalanceLamports", .integer).notNull()
                t.column("lastRefreshedAt", .integer).notNull()
                t.column("lastAirdropAttemptAt", .integer)
            }
        }

        migrator.registerMigration("v5_settlement_sync") { db in
            // pending_outbound_payments
            if try db.tableExists(PendingOutboundPaymentRow.databaseTableName) {
                try db.alter(table: PendingOutboundPaymentRow.databaseTableName) { t in
                    t.add(column: "expiresAt", .integer)
                    t.add(column: "backendReceiptID", .text)
                    t.add(column: "transactionSignature", .text)
                    t.add(column: "settledAt", .integer)
                    t.add(column: "failureReason", .text)
                    t.add(column: "conflictReason", .text)
                    t.add(column: "canonicalSequence", .integer)
                    t.add(column: "lastSubmissionAttemptAt", .integer)
                    t.add(column: "attemptCount", .integer)
                    t.add(column: "nextRetryAt", .integer)
                    t.add(column: "lastErrorSummary", .text)
                }
            }

            // pending_inbound_payments
            if try db.tableExists(PendingInboundPaymentRow.databaseTableName) {
                try db.alter(table: PendingInboundPaymentRow.databaseTableName) { t in
                    t.add(column: "expiresAt", .integer)
                    t.add(column: "backendReceiptID", .text)
                    t.add(column: "transactionSignature", .text)
                    t.add(column: "settledAt", .integer)
                    t.add(column: "failureReason", .text)
                    t.add(column: "conflictReason", .text)
                    t.add(column: "canonicalSequence", .integer)
                    t.add(column: "lastSubmissionAttemptAt", .integer)
                    t.add(column: "attemptCount", .integer)
                    t.add(column: "nextRetryAt", .integer)
                    t.add(column: "lastErrorSummary", .text)
                }
            }

            // settlement_events
            if try db.tableExists(SettlementEventRow.databaseTableName) {
                try db.alter(table: SettlementEventRow.databaseTableName) { t in
                    t.add(column: "backendReceiptID", .text)
                    t.add(column: "failureReason", .text)
                    t.add(column: "conflictReason", .text)
                    t.add(column: "rawBackendResponse", .text)
                }
            }
        }

        try migrator.migrate(dbQueue)
    }
}

// MARK: - Saved contacts (publicKey identity)

extension DatabaseManager {
    func createContact(_ c: SavedContact) throws {
        try dbQueue.write { db in try c.insert(db) }
    }

    func updateContact(_ c: SavedContact) throws {
        try dbQueue.write { db in try c.update(db) }
    }

    func findContactByPublicKey(_ key: Data) throws -> SavedContact? {
        try dbQueue.read { db in
            try SavedContact.filter(Column("publicKey") == key).fetchOne(db)
        }
    }

    /// URL-safe base64 public key — same string as mesh `senderID` / `deviceID`.
    static func canonicalSenderID(publicKey: Data) -> String {
        publicKey.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Saved-contact nickname for this mesh sender (public key id), if any.
    func savedNickname(forSenderID senderID: String) -> String? {
        let sid = senderID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sid.isEmpty else { return nil }
        if let pk = KeyManager.decodePublicKeyBase64(sid),
           let c = try? findContactByPublicKey(pk) {
            return c.nickname
        }
        guard let all = try? listContacts() else { return nil }
        for c in all where Self.canonicalSenderID(publicKey: c.publicKey) == sid {
            return c.nickname
        }
        return nil
    }

    func listContacts() throws -> [SavedContact] {
        try dbQueue.read { db in
            try SavedContact.order(Column("lastSeen").desc).fetchAll(db)
        }
    }

    func updateLastSeenForPublicKey(_ key: Data) throws {
        let now = Int64(Date().timeIntervalSince1970)
        try dbQueue.write { db in
            guard var c = try SavedContact.filter(Column("publicKey") == key).fetchOne(db) else { return }
            c.lastSeen = now
            try c.update(db)
        }
    }

    func deleteContact(_ c: SavedContact) throws {
        try dbQueue.write { db in try c.delete(db) }
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

    /// Remove DM rows older than `maxAgeSeconds` (channel prefix `dm:`).
    func pruneDMMessages(olderThanSeconds maxAgeSeconds: Int64) throws {
        let cutoff = Int64(Date().timeIntervalSince1970) - maxAgeSeconds
        try dbQueue.write { db in
            try db.execute(
                sql: "DELETE FROM messages WHERE channel LIKE ? AND receivedAt < ?",
                arguments: ["dm:%", cutoff]
            )
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

    /// Returns all non-expired alerts paired with their vouches in a single read transaction.
    /// Used by the trust engine to avoid N+1 queries.
    func alertsWithVouches() throws -> [(alert: Alert, vouches: [Vouch])] {
        let now = Int64(Date().timeIntervalSince1970)
        return try dbQueue.read { db in
            let alerts = try Alert.filter(Column("expiresAt") > now).fetchAll(db)
            return try alerts.map { alert in
                let vouches = try Vouch.filter(Column("alertID") == alert.id).fetchAll(db)
                return (alert, vouches)
            }
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

// MARK: - Wallet cache + offline payments

extension DatabaseManager {
    func insertOutboundPendingPayment(_ payment: PendingPayment) throws {
        let asset = payment.asset
        let row = PendingOutboundPaymentRow(
            id: payment.id,
            senderDeviceID: payment.senderDeviceID,
            senderName: payment.senderName,
            recipientDeviceID: payment.recipientDeviceID,
            recipientName: payment.recipientName,
            amountLamports: payment.amountLamports,
            asset: asset,
            createdAt: payment.createdAt,
            receivedAt: payment.receivedAt,
            status: payment.status,
            paymentPayloadVersion: payment.paymentPayloadVersion,
            paymentSignature: payment.paymentSignature,
            paymentPublicKey: payment.paymentPublicKey,
            memo: payment.memo,
            meshEnvelopeID: payment.meshEnvelopeID,
            settlementReference: payment.settlementReference,
            expiresAt: payment.expiresAt,
            backendReceiptID: payment.backendReceiptID,
            transactionSignature: payment.transactionSignature,
            settledAt: payment.settledAt,
            failureReason: payment.failureReason,
            conflictReason: payment.conflictReason,
            canonicalSequence: payment.canonicalSequence,
            lastSubmissionAttemptAt: payment.lastSubmissionAttemptAt,
            attemptCount: payment.attemptCount,
            nextRetryAt: payment.nextRetryAt,
            lastErrorSummary: payment.lastErrorSummary
        )

        try dbQueue.write { db in
            try row.insert(db, onConflict: .replace)
        }
    }

    /// Receiver-side idempotency: inserting the same payment twice must result in exactly one persisted row.
    /// - Returns: `true` if inserted, `false` if already existed.
    func insertInboundPendingPaymentIfNew(_ payment: PendingPayment) throws -> Bool {
        let asset = payment.asset
        let row = PendingInboundPaymentRow(
            id: payment.id,
            senderDeviceID: payment.senderDeviceID,
            senderName: payment.senderName,
            recipientDeviceID: payment.recipientDeviceID,
            recipientName: payment.recipientName,
            amountLamports: payment.amountLamports,
            asset: asset,
            createdAt: payment.createdAt,
            receivedAt: payment.receivedAt,
            status: payment.status,
            paymentPayloadVersion: payment.paymentPayloadVersion,
            paymentSignature: payment.paymentSignature,
            paymentPublicKey: payment.paymentPublicKey,
            memo: payment.memo,
            meshEnvelopeID: payment.meshEnvelopeID,
            settlementReference: payment.settlementReference,
            expiresAt: payment.expiresAt,
            backendReceiptID: payment.backendReceiptID,
            transactionSignature: payment.transactionSignature,
            settledAt: payment.settledAt,
            failureReason: payment.failureReason,
            conflictReason: payment.conflictReason,
            canonicalSequence: payment.canonicalSequence,
            lastSubmissionAttemptAt: payment.lastSubmissionAttemptAt,
            attemptCount: payment.attemptCount,
            nextRetryAt: payment.nextRetryAt,
            lastErrorSummary: payment.lastErrorSummary
        )

        return try dbQueue.write { db in
            // Receiver idempotency: insert at most once per paymentID.
            // Even if two writes race, the PRIMARY KEY keeps only one stored row.
            let exists = (try PendingInboundPaymentRow.fetchOne(db, key: row.id)) != nil
            if exists { return false }
            try row.insert(db, onConflict: .ignore)
            return true
        }
    }

    /// Returns recent offline mesh payment statuses merged for UI.
    func fetchRecentPaymentsMerged(forDeviceID deviceID: String, limit: Int = 20) throws -> [PaymentStatus] {
        try dbQueue.read { db in
            let outbound = try PendingOutboundPaymentRow
                .filter(Column("senderDeviceID") == deviceID)
                .order(Column("createdAt").desc)
                .limit(limit)
                .fetchAll(db)

            let inbound = try PendingInboundPaymentRow
                .filter(Column("recipientDeviceID") == deviceID)
                .order(Column("createdAt").desc)
                .limit(limit)
                .fetchAll(db)

            var outByID: [String: PendingOutboundPaymentRow] = [:]
            for o in outbound { outByID[o.id] = o }
            var inByID: [String: PendingInboundPaymentRow] = [:]
            for i in inbound { inByID[i.id] = i }

            let ids = Array(Set(outByID.keys).union(inByID.keys))

            func asset(from row: PendingOutboundPaymentRow) -> PaymentAsset {
                PaymentAsset(
                    assetId: row.assetId,
                    symbol: row.assetSymbol,
                    displayName: row.assetDisplayName,
                    decimals: row.assetDecimals,
                    assetType: row.assetType
                )
            }
            func asset(from row: PendingInboundPaymentRow) -> PaymentAsset {
                PaymentAsset(
                    assetId: row.assetId,
                    symbol: row.assetSymbol,
                    displayName: row.assetDisplayName,
                    decimals: row.assetDecimals,
                    assetType: row.assetType
                )
            }

            let merged: [PaymentStatus] = ids.compactMap { pid in
                let out = outByID[pid]
                let inn = inByID[pid]

                let draft: OfflinePaymentDraft
                if let out {
                    draft = OfflinePaymentDraft(
                        id: out.id,
                        recipientDeviceID: out.recipientDeviceID,
                        recipientNickname: out.recipientName,
                        amountLamports: out.amountLamports,
                        asset: asset(from: out),
                        memo: out.memo,
                        createdAt: out.createdAt,
                        expiresAt: out.expiresAt
                    )
                } else if let inn {
                    draft = OfflinePaymentDraft(
                        id: inn.id,
                        recipientDeviceID: inn.recipientDeviceID,
                        recipientNickname: inn.recipientName,
                        amountLamports: inn.amountLamports,
                        asset: asset(from: inn),
                        memo: inn.memo,
                        createdAt: inn.createdAt,
                        expiresAt: inn.expiresAt
                    )
                } else {
                    return nil
                }

                let phase = out?.status ?? inn?.status ?? .expired
                let direction: PaymentDirection = out != nil ? .outbound : .inbound

                func phaseIs(_ p: PaymentPhase) -> Bool { phase == p }
                func phaseIn(_ allowed: [PaymentPhase]) -> Bool { allowed.contains(phase) }

                // Settlement sync treats multiple local phases as “pending”.
                let isPending = phaseIn([.pending, .receivedPending, .sentOverMesh, .queuedOutbound, .settlementPending])
                let isSubmitting = phaseIs(.submitted)

                return PaymentStatus(
                    draft: draft,
                    direction: direction,
                    pending: isPending,
                    submitting: isSubmitting,
                    queuedOutbound: phaseIs(.queuedOutbound),
                    sentOverMesh: phaseIs(.sentOverMesh),
                    receivedPending: phaseIs(.receivedPending),
                    settlementPending: phaseIs(.settlementPending),
                    settled: phaseIs(.settled),
                    duplicate: phaseIs(.duplicate),
                    conflict: phaseIs(.conflict),
                    failed: phaseIs(.failed),
                    invalid: phaseIs(.invalid),
                    rejected: phaseIs(.rejected),
                    expired: phaseIs(.expired)
                )
            }

            // Sort by the newest of outbound/inbound createdAt.
            let sorted = merged.sorted { a, b in
                let aOut = outByID[a.id]?.createdAt ?? 0
                let aIn = inByID[a.id]?.createdAt ?? 0
                let bOut = outByID[b.id]?.createdAt ?? 0
                let bIn = inByID[b.id]?.createdAt ?? 0
                return max(aOut, aIn) > max(bOut, bIn)
            }

            return Array(sorted.prefix(limit))
        }
    }

    func updatePaymentStatus(paymentID: String, direction: PaymentDirection, to status: PaymentPhase) throws {
        switch direction {
        case .outbound:
            try dbQueue.write { db in
                guard var row = try PendingOutboundPaymentRow.fetchOne(db, key: paymentID) else { return }
                row.status = status
                try row.update(db)
            }
        case .inbound:
            try dbQueue.write { db in
                guard var row = try PendingInboundPaymentRow.fetchOne(db, key: paymentID) else { return }
                row.status = status
                try row.update(db)
            }
        }
    }

    func insertSettlementEvent(_ record: SettlementRecord) throws {
        let row = SettlementEventRow(
            id: record.id,
            pendingPaymentID: record.pendingPaymentID,
            createdAt: record.createdAt,
            statusBefore: record.statusBefore,
            statusAfter: record.statusAfter,
            notes: record.notes,
            txSignature: record.txSignature,
            backendReceiptID: record.backendReceiptID,
            failureReason: record.failureReason,
            conflictReason: record.conflictReason,
            rawBackendResponse: record.rawBackendResponse
        )
        try dbQueue.write { db in
            try row.insert(db, onConflict: .replace)
        }
    }

    func upsertWalletStateCache(_ cache: WalletStateCache) throws {
        try dbQueue.write { db in
            try cache.insert(db, onConflict: .replace)
        }
    }

    func fetchWalletStateCache(network: String) throws -> WalletStateCache? {
        try dbQueue.read { db in
            try WalletStateCache.filter(Column("network") == network).fetchOne(db)
        }
    }

    // MARK: - Settlement sync (Wave 2)

    func fetchPaymentsEligibleForSettlementSync(nowSeconds: Int64, limit: Int = 20) throws -> [PendingPayment] {
        let eligiblePhases: [PaymentPhase] = [
            .queuedOutbound,
            .sentOverMesh,
            .receivedPending,
            .pending,
            .submitted
        ]
        let eligibleRaw = eligiblePhases.map(\.rawValue)

        return try dbQueue.read { db in
            let placeholders = eligibleRaw.map { _ in "?" }.joined(separator: ",")
            let statusInSQL = "status IN (\(placeholders))"

            let outboundRows = try PendingOutboundPaymentRow
                .filter(sql: statusInSQL, arguments: StatementArguments(eligibleRaw))
                .order(Column("createdAt").desc)
                .limit(limit * 2)
                .fetchAll(db)

            let inboundRows = try PendingInboundPaymentRow
                .filter(sql: statusInSQL, arguments: StatementArguments(eligibleRaw))
                .order(Column("createdAt").desc)
                .limit(limit * 2)
                .fetchAll(db)

            let candidates: [PendingPayment] = outboundRows.map { $0.toDomain() } + inboundRows.map { $0.toDomain() }

            let filtered = candidates.filter { p in
                if let exp = p.expiresAt, exp <= nowSeconds { return false }
                if let next = p.nextRetryAt, next > nowSeconds { return false }
                if let attemptCount = p.attemptCount, attemptCount >= 8 { return false }
                return true
            }

            // Sort: earliest next retry first.
            let sorted = filtered.sorted {
                let aNext = $0.nextRetryAt ?? 0
                let bNext = $1.nextRetryAt ?? 0
                if aNext != bNext { return aNext < bNext }
                return $0.createdAt > $1.createdAt
            }
            return Array(sorted.prefix(limit))
        }
    }

    func fetchPendingPayment(paymentID: String, direction: PaymentDirection) throws -> PendingPayment? {
        try dbQueue.read { db in
            switch direction {
            case .outbound:
                guard let row = try PendingOutboundPaymentRow.fetchOne(db, key: paymentID) else { return nil }
                return row.toDomain()
            case .inbound:
                guard let row = try PendingInboundPaymentRow.fetchOne(db, key: paymentID) else { return nil }
                return row.toDomain()
            }
        }
    }

    func fetchSettlementEvents(for paymentID: String, limit: Int = 20) throws -> [SettlementEventRow] {
        try dbQueue.read { db in
            try SettlementEventRow
                .filter(Column("pendingPaymentID") == paymentID)
                .order(Column("createdAt").desc)
                .limit(limit)
                .fetchAll(db)
        }
    }

    func markPaymentExpired(paymentID: String, direction: PaymentDirection, nowSeconds: Int64, reason: String) throws {
        switch direction {
        case .outbound:
            try dbQueue.write { db in
                guard var row = try PendingOutboundPaymentRow.fetchOne(db, key: paymentID) else { return }
                row.status = .expired
                row.lastSubmissionAttemptAt = nowSeconds
                row.attemptCount = (row.attemptCount ?? 0)
                row.nextRetryAt = nil
                row.lastErrorSummary = reason
                try row.update(db)
            }
        case .inbound:
            try dbQueue.write { db in
                guard var row = try PendingInboundPaymentRow.fetchOne(db, key: paymentID) else { return }
                row.status = .expired
                row.lastSubmissionAttemptAt = nowSeconds
                row.attemptCount = (row.attemptCount ?? 0)
                row.nextRetryAt = nil
                row.lastErrorSummary = reason
                try row.update(db)
            }
        }
    }

    func applySettlementOutcome(
        paymentID: String,
        direction: PaymentDirection,
        newStatus: PaymentPhase,
        nowSeconds: Int64,
        backendReceiptID: String?,
        transactionSignature: String?,
        settledAt: Int64?,
        failureReason: String?,
        conflictReason: String?,
        canonicalSequence: Int64?,
        attemptCount: Int?,
        rawBackendResponse: String?
    ) throws {
        let updatedLastError: String? = nil

        switch direction {
        case .outbound:
            try dbQueue.write { db in
                guard var row = try PendingOutboundPaymentRow.fetchOne(db, key: paymentID) else { return }
                let before = row.status
                row.status = newStatus
                row.backendReceiptID = backendReceiptID
                row.transactionSignature = transactionSignature
                row.settledAt = settledAt
                row.failureReason = failureReason
                row.conflictReason = conflictReason
                row.canonicalSequence = canonicalSequence
                row.lastSubmissionAttemptAt = nowSeconds
                row.attemptCount = attemptCount ?? row.attemptCount
                row.nextRetryAt = nil
                row.lastErrorSummary = updatedLastError
                try row.update(db)

                // Persist audit event.
                let record = SettlementRecord(
                    id: UUID().uuidString,
                    pendingPaymentID: paymentID,
                    createdAt: nowSeconds,
                    statusBefore: before,
                    statusAfter: newStatus,
                    notes: "Backend outcome: \(newStatus.rawValue)",
                    txSignature: transactionSignature,
                    backendReceiptID: backendReceiptID,
                    failureReason: failureReason,
                    conflictReason: conflictReason,
                    rawBackendResponse: rawBackendResponse
                )
                let event = SettlementEventRow(
                    id: record.id,
                    pendingPaymentID: record.pendingPaymentID,
                    createdAt: record.createdAt,
                    statusBefore: record.statusBefore,
                    statusAfter: record.statusAfter,
                    notes: record.notes,
                    txSignature: record.txSignature,
                    backendReceiptID: record.backendReceiptID,
                    failureReason: record.failureReason,
                    conflictReason: record.conflictReason,
                    rawBackendResponse: record.rawBackendResponse
                )
                try event.insert(db, onConflict: .replace)
            }
        case .inbound:
            try dbQueue.write { db in
                guard var row = try PendingInboundPaymentRow.fetchOne(db, key: paymentID) else { return }
                let before = row.status
                row.status = newStatus
                row.backendReceiptID = backendReceiptID
                row.transactionSignature = transactionSignature
                row.settledAt = settledAt
                row.failureReason = failureReason
                row.conflictReason = conflictReason
                row.canonicalSequence = canonicalSequence
                row.lastSubmissionAttemptAt = nowSeconds
                row.attemptCount = attemptCount ?? row.attemptCount
                row.nextRetryAt = nil
                row.lastErrorSummary = updatedLastError
                try row.update(db)

                let record = SettlementRecord(
                    id: UUID().uuidString,
                    pendingPaymentID: paymentID,
                    createdAt: nowSeconds,
                    statusBefore: before,
                    statusAfter: newStatus,
                    notes: "Backend outcome: \(newStatus.rawValue)",
                    txSignature: transactionSignature,
                    backendReceiptID: backendReceiptID,
                    failureReason: failureReason,
                    conflictReason: conflictReason,
                    rawBackendResponse: rawBackendResponse
                )
                let event = SettlementEventRow(
                    id: record.id,
                    pendingPaymentID: record.pendingPaymentID,
                    createdAt: record.createdAt,
                    statusBefore: record.statusBefore,
                    statusAfter: record.statusAfter,
                    notes: record.notes,
                    txSignature: record.txSignature,
                    backendReceiptID: record.backendReceiptID,
                    failureReason: record.failureReason,
                    conflictReason: record.conflictReason,
                    rawBackendResponse: record.rawBackendResponse
                )
                try event.insert(db, onConflict: .replace)
            }
        }
    }

    func applySettlementTransientError(
        paymentID: String,
        direction: PaymentDirection,
        nowSeconds: Int64,
        attemptCount: Int,
        nextRetryAt: Int64,
        lastErrorSummary: String,
        rawBackendResponse: String? = nil
    ) throws {
        switch direction {
        case .outbound:
            try dbQueue.write { db in
                guard var row = try PendingOutboundPaymentRow.fetchOne(db, key: paymentID) else { return }
                let before = row.status
                row.lastSubmissionAttemptAt = nowSeconds
                row.attemptCount = attemptCount
                row.nextRetryAt = nextRetryAt
                row.lastErrorSummary = lastErrorSummary
                try row.update(db)

                let record = SettlementRecord(
                    id: UUID().uuidString,
                    pendingPaymentID: paymentID,
                    createdAt: nowSeconds,
                    statusBefore: before,
                    statusAfter: before,
                    notes: "Transient settlement error: \(lastErrorSummary)",
                    txSignature: row.transactionSignature,
                    backendReceiptID: row.backendReceiptID,
                    failureReason: nil,
                    conflictReason: nil,
                    rawBackendResponse: rawBackendResponse
                )
                let event = SettlementEventRow(
                    id: record.id,
                    pendingPaymentID: record.pendingPaymentID,
                    createdAt: record.createdAt,
                    statusBefore: record.statusBefore,
                    statusAfter: record.statusAfter,
                    notes: record.notes,
                    txSignature: record.txSignature,
                    backendReceiptID: record.backendReceiptID,
                    failureReason: record.failureReason,
                    conflictReason: record.conflictReason,
                    rawBackendResponse: record.rawBackendResponse
                )
                try event.insert(db, onConflict: .replace)
            }
        case .inbound:
            try dbQueue.write { db in
                guard var row = try PendingInboundPaymentRow.fetchOne(db, key: paymentID) else { return }
                let before = row.status
                row.lastSubmissionAttemptAt = nowSeconds
                row.attemptCount = attemptCount
                row.nextRetryAt = nextRetryAt
                row.lastErrorSummary = lastErrorSummary
                try row.update(db)

                let record = SettlementRecord(
                    id: UUID().uuidString,
                    pendingPaymentID: paymentID,
                    createdAt: nowSeconds,
                    statusBefore: before,
                    statusAfter: before,
                    notes: "Transient settlement error: \(lastErrorSummary)",
                    txSignature: row.transactionSignature,
                    backendReceiptID: row.backendReceiptID,
                    failureReason: nil,
                    conflictReason: nil,
                    rawBackendResponse: rawBackendResponse
                )
                let event = SettlementEventRow(
                    id: record.id,
                    pendingPaymentID: record.pendingPaymentID,
                    createdAt: record.createdAt,
                    statusBefore: record.statusBefore,
                    statusAfter: record.statusAfter,
                    notes: record.notes,
                    txSignature: record.txSignature,
                    backendReceiptID: record.backendReceiptID,
                    failureReason: record.failureReason,
                    conflictReason: record.conflictReason,
                    rawBackendResponse: record.rawBackendResponse
                )
                try event.insert(db, onConflict: .replace)
            }
        }
    }

    func applySettlementPermanentFailure(
        paymentID: String,
        direction: PaymentDirection,
        nowSeconds: Int64,
        attemptCount: Int,
        lastErrorSummary: String,
        rawBackendResponse: String? = nil
    ) throws {
        // Permanent failures end the retry loop.
        let newStatus: PaymentPhase = .invalid

        switch direction {
        case .outbound:
            try dbQueue.write { db in
                guard var row = try PendingOutboundPaymentRow.fetchOne(db, key: paymentID) else { return }
                let before = row.status
                row.status = newStatus
                row.lastSubmissionAttemptAt = nowSeconds
                row.attemptCount = attemptCount
                row.nextRetryAt = nil
                row.lastErrorSummary = lastErrorSummary
                row.failureReason = lastErrorSummary
                try row.update(db)

                let record = SettlementRecord(
                    id: UUID().uuidString,
                    pendingPaymentID: paymentID,
                    createdAt: nowSeconds,
                    statusBefore: before,
                    statusAfter: newStatus,
                    notes: "Permanent settlement failure: \(lastErrorSummary)",
                    txSignature: row.transactionSignature,
                    backendReceiptID: row.backendReceiptID,
                    failureReason: lastErrorSummary,
                    conflictReason: nil,
                    rawBackendResponse: rawBackendResponse
                )
                let event = SettlementEventRow(
                    id: record.id,
                    pendingPaymentID: record.pendingPaymentID,
                    createdAt: record.createdAt,
                    statusBefore: record.statusBefore,
                    statusAfter: record.statusAfter,
                    notes: record.notes,
                    txSignature: record.txSignature,
                    backendReceiptID: record.backendReceiptID,
                    failureReason: record.failureReason,
                    conflictReason: record.conflictReason,
                    rawBackendResponse: record.rawBackendResponse
                )
                try event.insert(db, onConflict: .replace)
            }
        case .inbound:
            try dbQueue.write { db in
                guard var row = try PendingInboundPaymentRow.fetchOne(db, key: paymentID) else { return }
                let before = row.status
                row.status = newStatus
                row.lastSubmissionAttemptAt = nowSeconds
                row.attemptCount = attemptCount
                row.nextRetryAt = nil
                row.lastErrorSummary = lastErrorSummary
                row.failureReason = lastErrorSummary
                try row.update(db)

                let record = SettlementRecord(
                    id: UUID().uuidString,
                    pendingPaymentID: paymentID,
                    createdAt: nowSeconds,
                    statusBefore: before,
                    statusAfter: newStatus,
                    notes: "Permanent settlement failure: \(lastErrorSummary)",
                    txSignature: row.transactionSignature,
                    backendReceiptID: row.backendReceiptID,
                    failureReason: lastErrorSummary,
                    conflictReason: nil,
                    rawBackendResponse: rawBackendResponse
                )
                let event = SettlementEventRow(
                    id: record.id,
                    pendingPaymentID: record.pendingPaymentID,
                    createdAt: record.createdAt,
                    statusBefore: record.statusBefore,
                    statusAfter: record.statusAfter,
                    notes: record.notes,
                    txSignature: record.txSignature,
                    backendReceiptID: record.backendReceiptID,
                    failureReason: record.failureReason,
                    conflictReason: record.conflictReason,
                    rawBackendResponse: record.rawBackendResponse
                )
                try event.insert(db, onConflict: .replace)
            }
        }
    }
}
