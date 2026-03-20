import Foundation
import Combine

@MainActor
final class SettlementSyncService: ObservableObject {
    @Published private(set) var isOnline: Bool = false
    @Published private(set) var syncInProgress: Bool = false
    @Published private(set) var syncRevision: Int = 0
    @Published private(set) var lastSyncError: String?
    @Published private(set) var lastSyncAt: Date?

    private let internetAvailability = InternetAvailability()
    private let apiClient: SettlementAPIClient
    private let solanaWallet = SolanaWalletService()

    private var cancellables: Set<AnyCancellable> = []
    private var inFlightPaymentIDs: Set<String> = []

    private let maxAttempts = 8
    private let baseBackoffSeconds: Double = 10
    private let maxBackoffSeconds: Double = 10 * 60

    enum SyncReason {
        case appLaunch
        case reconnect
        case manual
    }

    init(apiClient: SettlementAPIClient = .shared) {
        self.apiClient = apiClient
    }

    func start() {
        // Observe connectivity changes.
        isOnline = internetAvailability.isAvailable
        internetAvailability.$isAvailable
            .receive(on: DispatchQueue.main)
            .sink { [weak self] available in
                guard let self else { return }
                self.isOnline = available
                if available {
                    Task { await self.syncNow(reason: .reconnect) }
                }
            }
            .store(in: &cancellables)
    }

    func syncNow(reason: SyncReason = .manual) async {
        guard !syncInProgress else { return }
        guard isOnline else {
            // Cached UI is always fine; syncing stays off when offline.
            return
        }

        syncInProgress = true
        lastSyncError = nil
        defer {
            syncInProgress = false
        }

        let nowSeconds = Int64(Date().timeIntervalSince1970)
        let processedAny: Bool
        do {
            let eligible = try DatabaseManager.shared.fetchPaymentsEligibleForSettlementSync(nowSeconds: nowSeconds, limit: 30)
            if eligible.isEmpty {
                processedAny = false
            } else {
                processedAny = true
                lastSyncAt = Date()

                // Ensure we have a sender wallet address (used when known).
                do {
                    try await solanaWallet.createWalletIfNeeded()
                } catch {
                    lastSyncError = "Wallet missing/failed to create: \(error.localizedDescription)"
                    // Without a sender wallet we can’t submit settlement; fail gracefully.
                    return
                }

                for p in eligible {
                    await submitSinglePayment(p, nowSeconds: nowSeconds)
                }
            }
        } catch {
            lastSyncError = error.localizedDescription
            processedAny = false
        }

        if processedAny {
            syncRevision += 1
        }
    }

    private func backoffSeconds(attemptCount: Int) -> Int64 {
        let exp = pow(2.0, Double(max(0, attemptCount - 1)))
        let raw = baseBackoffSeconds * exp
        return Int64(min(raw, maxBackoffSeconds))
    }

    private func submitSinglePayment(_ payment: PendingPayment, nowSeconds: Int64) async {
        if inFlightPaymentIDs.contains(payment.id) { return }
        inFlightPaymentIDs.insert(payment.id)
        defer { inFlightPaymentIDs.remove(payment.id) }

        let effectiveExpiresAt: Int64 = {
            if let exp = payment.expiresAt { return exp }
            // Receiver-side expiresAt is not known in this wave. Use a conservative local expiry window.
            // TODO: align expiry policy with backend enforcement.
            return payment.createdAt + (7 * 24 * 3600)
        }()

        if effectiveExpiresAt <= nowSeconds {
            try? DatabaseManager.shared.markPaymentExpired(
                paymentID: payment.id,
                direction: payment.direction,
                nowSeconds: nowSeconds,
                reason: "Local expiry window reached"
            )
            return
        }

        let attemptCount = (payment.attemptCount ?? 0) + 1
        if attemptCount > maxAttempts {
            try? DatabaseManager.shared.applySettlementPermanentFailure(
                paymentID: payment.id,
                direction: payment.direction,
                nowSeconds: nowSeconds,
                attemptCount: attemptCount,
                lastErrorSummary: "Max retry attempts reached"
            )
            return
        }

        let submittedByDeviceID = DeviceIdentity.load().deviceID
        let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let schemaVersion = 1

        let rawPayload: OfflinePaymentPayload = OfflinePaymentPayload(
            paymentID: payment.id,
            senderDeviceID: payment.senderDeviceID,
            senderName: payment.senderName,
            recipientDeviceID: payment.recipientDeviceID,
            recipientName: payment.recipientName,
            amountLamports: payment.amountLamports,
            assetSymbol: payment.asset.symbol,
            createdAt: payment.createdAt,
            memo: payment.memo,
            paymentPublicKeyBase64: payment.paymentPublicKey.base64EncodedString(),
            paymentSignatureBase64: payment.paymentSignature.base64EncodedString(),
            payloadVersion: payment.paymentPayloadVersion
        )

        let rawPayloadJson: String = (try? JSONEncoder().encode(rawPayload))
            .flatMap { String(data: $0, encoding: .utf8) }
            ?? "{}"
        let senderSignatureB64 = payment.paymentSignature.base64EncodedString()

        let request = SettlementSubmitRequest(
            payment_id: payment.id,
            sender_device_id: payment.senderDeviceID,
            recipient_device_id: payment.recipientDeviceID,
            amount_minor: payment.amountLamports,
            asset_code: payment.asset.symbol,
            memo: payment.memo,
            created_at: payment.createdAt,
            expires_at: payment.expiresAt ?? effectiveExpiresAt,
            local_sequence: 0,
            sender_signature: senderSignatureB64,
            raw_payload_json: rawPayloadJson,
            sender_wallet_address: solanaWallet.walletAddress,
            recipient_wallet_address: nil,
            submitted_by_device_id: submittedByDeviceID,
            app_version: appVersion,
            schema_version: schemaVersion
        )

        do {
            let (resp, raw) = try await apiClient.submitPayment(request)
            let nextStatus: PaymentPhase = mapCanonical(resp.canonical_status)

            try DatabaseManager.shared.applySettlementOutcome(
                paymentID: payment.id,
                direction: payment.direction,
                newStatus: nextStatus,
                nowSeconds: nowSeconds,
                backendReceiptID: resp.backend_receipt_id,
                transactionSignature: resp.transaction_signature,
                settledAt: resp.settled_at,
                failureReason: resp.failure_reason,
                conflictReason: resp.conflict_reason,
                canonicalSequence: resp.canonical_sequence,
                attemptCount: attemptCount,
                rawBackendResponse: raw
            )
        } catch let apiErr as SettlementAPIError {
            switch apiErr {
            case .transient(let msg):
                let nextRetry = nowSeconds + backoffSeconds(attemptCount: attemptCount)
                try? DatabaseManager.shared.applySettlementTransientError(
                    paymentID: payment.id,
                    direction: payment.direction,
                    nowSeconds: nowSeconds,
                    attemptCount: attemptCount,
                    nextRetryAt: nextRetry,
                    lastErrorSummary: msg
                )
            case .permanent(let msg):
                try? DatabaseManager.shared.applySettlementPermanentFailure(
                    paymentID: payment.id,
                    direction: payment.direction,
                    nowSeconds: nowSeconds,
                    attemptCount: attemptCount,
                    lastErrorSummary: msg
                )
            }
        } catch {
            // Unknown errors: treat as transient.
            let nextRetry = nowSeconds + backoffSeconds(attemptCount: attemptCount)
            try? DatabaseManager.shared.applySettlementTransientError(
                paymentID: payment.id,
                direction: payment.direction,
                nowSeconds: nowSeconds,
                attemptCount: attemptCount,
                nextRetryAt: nextRetry,
                lastErrorSummary: error.localizedDescription
            )
        }
    }

    private func mapCanonical(_ status: SettlementCanonicalStatus) -> PaymentPhase {
        switch status {
        case .settled:
            return .settled
        case .submitted:
            return .submitted
        case .duplicate:
            return .duplicate
        case .conflict:
            return .conflict
        case .failed:
            return .failed
        case .expired:
            return .expired
        case .invalid:
            return .invalid
        }
    }
}

