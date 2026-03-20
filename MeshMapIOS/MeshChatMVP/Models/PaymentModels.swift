import Foundation
import GRDB

// MARK: - Domain models (for UI + transport)

enum PaymentAssetType: String, Codable {
    case nativeSol
}

struct PaymentAsset: Codable, Equatable {
    var assetId: String
    var symbol: String
    var displayName: String
    var decimals: Int
    var assetType: PaymentAssetType

    static let sol: PaymentAsset = PaymentAsset(
        assetId: "native_sol",
        symbol: "SOL",
        displayName: "Solana (SOL)",
        decimals: 9,
        assetType: .nativeSol
    )

    // TODO: SPL token support (including Token2022), escrow/program integration, and richer asset metadata.
}

enum PaymentPhase: String, Codable, CaseIterable {
    case queuedOutbound
    case sentOverMesh
    // Local receipt: receiver stored claim as pending (eligible for backend submission).
    case receivedPending
    // Canonical pending state used for settlement sync lifecycle.
    case pending
    // Canonical submission state returned by backend (accepted / awaiting finalization).
    case submitted
    case settled

    // Backend canonical outcomes.
    case duplicate
    case conflict
    case failed

    // Permanent validation errors.
    case invalid
    // Kept for forward-compat with older wave statuses.
    case rejected
    case expired

    // Legacy / placeholder; not used yet in this wave.
    case settlementPending
}

enum PaymentDirection: String, Codable {
    case inbound
    case outbound
}

/// Draft composed by the sender in the offline mesh payment flow.
struct OfflinePaymentDraft: Codable, Identifiable, Equatable {
    var id: String
    var recipientDeviceID: String
    var recipientNickname: String
    var amountLamports: Int64
    var asset: PaymentAsset
    var memo: String?
    var createdAt: Int64

    /// Local expiry for settlement submission. Backend may also enforce its own window.
    var expiresAt: Int64?
}

/// Locally persisted pending payment (sender: outbound; receiver: inbound).
struct PendingPayment: Codable, Identifiable, Equatable {
    var id: String
    var direction: PaymentDirection

    var senderDeviceID: String
    var senderName: String

    var recipientDeviceID: String
    var recipientName: String

    var amountLamports: Int64
    var asset: PaymentAsset

    var createdAt: Int64
    var receivedAt: Int64?

    var status: PaymentPhase

    var paymentPayloadVersion: Int
    var paymentSignature: Data
    var paymentPublicKey: Data

    var memo: String?
    var meshEnvelopeID: String?
    var settlementReference: String?

    /// When set and in the past, this payment must not be submitted.
    var expiresAt: Int64?

    /// Backend settlement receipt metadata.
    var backendReceiptID: String?
    var transactionSignature: String?
    var settledAt: Int64?
    var failureReason: String?
    var conflictReason: String?
    var canonicalSequence: Int64?

    /// Retry / backoff metadata (used only for settlement sync).
    var lastSubmissionAttemptAt: Int64?
    var attemptCount: Int?
    var nextRetryAt: Int64?
    var lastErrorSummary: String?
}

struct SettlementRecord: Codable, Identifiable, Equatable {
    var id: String
    var pendingPaymentID: String
    var createdAt: Int64
    var statusBefore: PaymentPhase
    var statusAfter: PaymentPhase
    var notes: String
    var txSignature: String?

    /// Backend settlement receipt id (if any).
    var backendReceiptID: String?
    var failureReason: String?
    var conflictReason: String?
    var rawBackendResponse: String?
}

/// Convenience UI aggregation model for displaying payment history rows.
/// For now, offline mesh payments never reach on-chain settlement.
/// TODO: real settlement, anti-fraud/reconciliation, escrow / smart wallet / program integration, staking/yield support.
struct PaymentStatus: Codable, Identifiable, Equatable {
    var id: String { draft.id }
    var draft: OfflinePaymentDraft
    var direction: PaymentDirection

    var pending: Bool
    var submitting: Bool
    var queuedOutbound: Bool
    var sentOverMesh: Bool
    var receivedPending: Bool
    var settlementPending: Bool

    var settled: Bool
    var duplicate: Bool
    var conflict: Bool
    var failed: Bool
    var invalid: Bool
    var rejected: Bool
    var expired: Bool
}

// MARK: - GRDB row models (wallet cache + payment persistence)

struct PendingOutboundPaymentRow: Codable, FetchableRecord, PersistableRecord, Identifiable, Equatable {
    static let databaseTableName = "pending_outbound_payments"
    var id: String

    var senderDeviceID: String
    var senderName: String

    var recipientDeviceID: String
    var recipientName: String

    var amountLamports: Int64

    var assetId: String
    var assetSymbol: String
    var assetDisplayName: String
    var assetDecimals: Int
    var assetType: PaymentAssetType

    var createdAt: Int64
    var receivedAt: Int64?

    var status: PaymentPhase

    var paymentPayloadVersion: Int
    var paymentSignature: Data
    var paymentPublicKey: Data

    var memo: String?
    var meshEnvelopeID: String?
    var settlementReference: String?

    var expiresAt: Int64?

    var backendReceiptID: String?
    var transactionSignature: String?
    var settledAt: Int64?
    var failureReason: String?
    var conflictReason: String?
    var canonicalSequence: Int64?

    var lastSubmissionAttemptAt: Int64?
    var attemptCount: Int?
    var nextRetryAt: Int64?
    var lastErrorSummary: String?

    init(
        id: String,
        senderDeviceID: String,
        senderName: String,
        recipientDeviceID: String,
        recipientName: String,
        amountLamports: Int64,
        asset: PaymentAsset,
        createdAt: Int64,
        receivedAt: Int64?,
        status: PaymentPhase,
        paymentPayloadVersion: Int,
        paymentSignature: Data,
        paymentPublicKey: Data,
        memo: String?,
        meshEnvelopeID: String?,
        settlementReference: String?,
        expiresAt: Int64?,
        backendReceiptID: String?,
        transactionSignature: String?,
        settledAt: Int64?,
        failureReason: String?,
        conflictReason: String?,
        canonicalSequence: Int64?,
        lastSubmissionAttemptAt: Int64?,
        attemptCount: Int?,
        nextRetryAt: Int64?,
        lastErrorSummary: String?
    ) {
        self.id = id
        self.senderDeviceID = senderDeviceID
        self.senderName = senderName
        self.recipientDeviceID = recipientDeviceID
        self.recipientName = recipientName
        self.amountLamports = amountLamports
        self.assetId = asset.assetId
        self.assetSymbol = asset.symbol
        self.assetDisplayName = asset.displayName
        self.assetDecimals = asset.decimals
        self.assetType = asset.assetType
        self.createdAt = createdAt
        self.receivedAt = receivedAt
        self.status = status
        self.paymentPayloadVersion = paymentPayloadVersion
        self.paymentSignature = paymentSignature
        self.paymentPublicKey = paymentPublicKey
        self.memo = memo
        self.meshEnvelopeID = meshEnvelopeID
        self.settlementReference = settlementReference
        self.expiresAt = expiresAt
        self.backendReceiptID = backendReceiptID
        self.transactionSignature = transactionSignature
        self.settledAt = settledAt
        self.failureReason = failureReason
        self.conflictReason = conflictReason
        self.canonicalSequence = canonicalSequence
        self.lastSubmissionAttemptAt = lastSubmissionAttemptAt
        self.attemptCount = attemptCount
        self.nextRetryAt = nextRetryAt
        self.lastErrorSummary = lastErrorSummary
    }

    func toDomain() -> PendingPayment {
        PendingPayment(
            id: id,
            direction: .outbound,
            senderDeviceID: senderDeviceID,
            senderName: senderName,
            recipientDeviceID: recipientDeviceID,
            recipientName: recipientName,
            amountLamports: amountLamports,
            asset: PaymentAsset(
                assetId: assetId,
                symbol: assetSymbol,
                displayName: assetDisplayName,
                decimals: assetDecimals,
                assetType: assetType
            ),
            createdAt: createdAt,
            receivedAt: receivedAt,
            status: status,
            paymentPayloadVersion: paymentPayloadVersion,
            paymentSignature: paymentSignature,
            paymentPublicKey: paymentPublicKey,
            memo: memo,
            meshEnvelopeID: meshEnvelopeID,
            settlementReference: settlementReference,
            expiresAt: expiresAt,
            backendReceiptID: backendReceiptID,
            transactionSignature: transactionSignature,
            settledAt: settledAt,
            failureReason: failureReason,
            conflictReason: conflictReason,
            canonicalSequence: canonicalSequence,
            lastSubmissionAttemptAt: lastSubmissionAttemptAt,
            attemptCount: attemptCount,
            nextRetryAt: nextRetryAt,
            lastErrorSummary: lastErrorSummary
        )
    }
}

struct PendingInboundPaymentRow: Codable, FetchableRecord, PersistableRecord, Identifiable, Equatable {
    static let databaseTableName = "pending_inbound_payments"
    var id: String

    var senderDeviceID: String
    var senderName: String

    var recipientDeviceID: String
    var recipientName: String

    var amountLamports: Int64

    var assetId: String
    var assetSymbol: String
    var assetDisplayName: String
    var assetDecimals: Int
    var assetType: PaymentAssetType

    var createdAt: Int64
    var receivedAt: Int64?

    var status: PaymentPhase

    var paymentPayloadVersion: Int
    var paymentSignature: Data
    var paymentPublicKey: Data

    var memo: String?
    var meshEnvelopeID: String?
    var settlementReference: String?

    var expiresAt: Int64?

    var backendReceiptID: String?
    var transactionSignature: String?
    var settledAt: Int64?
    var failureReason: String?
    var conflictReason: String?
    var canonicalSequence: Int64?

    var lastSubmissionAttemptAt: Int64?
    var attemptCount: Int?
    var nextRetryAt: Int64?
    var lastErrorSummary: String?

    init(
        id: String,
        senderDeviceID: String,
        senderName: String,
        recipientDeviceID: String,
        recipientName: String,
        amountLamports: Int64,
        asset: PaymentAsset,
        createdAt: Int64,
        receivedAt: Int64?,
        status: PaymentPhase,
        paymentPayloadVersion: Int,
        paymentSignature: Data,
        paymentPublicKey: Data,
        memo: String?,
        meshEnvelopeID: String?,
        settlementReference: String?,
        expiresAt: Int64?,
        backendReceiptID: String?,
        transactionSignature: String?,
        settledAt: Int64?,
        failureReason: String?,
        conflictReason: String?,
        canonicalSequence: Int64?,
        lastSubmissionAttemptAt: Int64?,
        attemptCount: Int?,
        nextRetryAt: Int64?,
        lastErrorSummary: String?
    ) {
        self.id = id
        self.senderDeviceID = senderDeviceID
        self.senderName = senderName
        self.recipientDeviceID = recipientDeviceID
        self.recipientName = recipientName
        self.amountLamports = amountLamports
        self.assetId = asset.assetId
        self.assetSymbol = asset.symbol
        self.assetDisplayName = asset.displayName
        self.assetDecimals = asset.decimals
        self.assetType = asset.assetType
        self.createdAt = createdAt
        self.receivedAt = receivedAt
        self.status = status
        self.paymentPayloadVersion = paymentPayloadVersion
        self.paymentSignature = paymentSignature
        self.paymentPublicKey = paymentPublicKey
        self.memo = memo
        self.meshEnvelopeID = meshEnvelopeID
        self.settlementReference = settlementReference
        self.expiresAt = expiresAt
        self.backendReceiptID = backendReceiptID
        self.transactionSignature = transactionSignature
        self.settledAt = settledAt
        self.failureReason = failureReason
        self.conflictReason = conflictReason
        self.canonicalSequence = canonicalSequence
        self.lastSubmissionAttemptAt = lastSubmissionAttemptAt
        self.attemptCount = attemptCount
        self.nextRetryAt = nextRetryAt
        self.lastErrorSummary = lastErrorSummary
    }

    func toDomain() -> PendingPayment {
        PendingPayment(
            id: id,
            direction: .inbound,
            senderDeviceID: senderDeviceID,
            senderName: senderName,
            recipientDeviceID: recipientDeviceID,
            recipientName: recipientName,
            amountLamports: amountLamports,
            asset: PaymentAsset(
                assetId: assetId,
                symbol: assetSymbol,
                displayName: assetDisplayName,
                decimals: assetDecimals,
                assetType: assetType
            ),
            createdAt: createdAt,
            receivedAt: receivedAt,
            status: status,
            paymentPayloadVersion: paymentPayloadVersion,
            paymentSignature: paymentSignature,
            paymentPublicKey: paymentPublicKey,
            memo: memo,
            meshEnvelopeID: meshEnvelopeID,
            settlementReference: settlementReference,
            expiresAt: expiresAt,
            backendReceiptID: backendReceiptID,
            transactionSignature: transactionSignature,
            settledAt: settledAt,
            failureReason: failureReason,
            conflictReason: conflictReason,
            canonicalSequence: canonicalSequence,
            lastSubmissionAttemptAt: lastSubmissionAttemptAt,
            attemptCount: attemptCount,
            nextRetryAt: nextRetryAt,
            lastErrorSummary: lastErrorSummary
        )
    }
}

struct SettlementEventRow: Codable, FetchableRecord, PersistableRecord, Identifiable, Equatable {
    static let databaseTableName = "settlement_events"

    var id: String
    var pendingPaymentID: String
    var createdAt: Int64

    var statusBefore: PaymentPhase
    var statusAfter: PaymentPhase
    var notes: String
    var txSignature: String?

    var backendReceiptID: String?
    var failureReason: String?
    var conflictReason: String?
    var rawBackendResponse: String?
}

struct WalletStateCache: Codable, FetchableRecord, PersistableRecord, Equatable {
    static let databaseTableName = "wallet_state_cache"

    var network: String // "devnet"
    var walletAddress: String
    var lastKnownBalanceLamports: Int64
    var lastRefreshedAt: Int64
    var lastAirdropAttemptAt: Int64?

    var id: String { network }
}

