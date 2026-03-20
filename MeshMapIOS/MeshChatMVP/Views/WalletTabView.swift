import SwiftUI

struct WalletTabView: View {
    @EnvironmentObject var mesh: BluetoothMeshService
    @EnvironmentObject var settlementSync: SettlementSyncService
    @StateObject private var solana = SolanaWalletService()
    @StateObject private var internet = InternetAvailability()

    @State private var contacts: [SavedContact] = []
    @State private var paymentStatuses: [PaymentStatus] = []
    @State private var lastActionMessage: String?
    @State private var receiptSelection: ReceiptSelection?

    // Offline mesh payment composer
    @State private var offlineRecipientID: String?
    @State private var offlineAmountSOL: String = ""
    @State private var offlineMemo: String = ""
    @State private var offlineSending = false

    // Online direct SOL transfer composer
    @State private var onlineRecipientAddress: String = ""
    @State private var onlineAmountSOL: String = ""
    @State private var onlineSending = false
    @State private var onlineTxSignature: String?

    var body: some View {
        NavigationStack {
            List {
                walletOverviewSection
                offlineComposerSection
                onlineTransferSection
                paymentActivitySection
            }
            .navigationTitle("Wallet")
            .onAppear {
                Task { await loadContactsAndPayments() }
            }
            .onChange(of: mesh.paymentActivityRevision) { _ in
                Task { await loadRecentPayments() }
            }
            .onChange(of: settlementSync.syncRevision) { _ in
                Task { await loadRecentPayments() }
            }
            .alert("Payment status", isPresented: Binding(
                get: { lastActionMessage != nil },
                set: { if !$0 { lastActionMessage = nil } }
            )) {
                Button("OK") { lastActionMessage = nil }
            } message: {
                Text(lastActionMessage ?? "")
            }
            .sheet(item: $receiptSelection) { sel in
                PaymentReceiptView(
                    paymentID: sel.paymentID,
                    direction: sel.direction,
                    settlementSync: settlementSync
                )
            }
        }
    }
}

// MARK: - Sections

private extension WalletTabView {
    var walletOverviewSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Devnet")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(Color.accentColor.opacity(0.2)))

                        Text("Solana address")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        if let addr = solana.walletAddress, !addr.isEmpty {
                            Text(addr)
                                .font(.system(.body, design: .monospaced))
                                .foregroundStyle(.primary)
                                .textSelection(.enabled)
                                .lineLimit(3)
                        } else {
                            Text("No wallet yet. Create one to enable balance + transfers.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if let addr = solana.walletAddress, !addr.isEmpty {
                        Button {
                            UIPasteboard.general.string = addr
                        } label: {
                            Label("Copy", systemImage: "doc.on.doc")
                        }
                        .buttonStyle(.bordered)
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Last-known balance")
                        if let lamports = solana.lastKnownBalanceLamports {
                            Text(formatLamports(lamports))
                                .font(.subheadline.weight(.semibold))
                        } else {
                            Text("—")
                                .font(.subheadline.weight(.semibold))
                        }
                    }

                    if let date = solana.lastRefreshedAt {
                        Text("Last refreshed: \(date.formatted(date: .numeric, time: .shortened))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Refresh to fetch balance (cached locally for offline viewing).")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                HStack(spacing: 12) {
                    if solana.walletAddress == nil || solana.walletAddress?.isEmpty == true {
                        Button {
                            Task {
                                do {
                                    try await solana.createWalletIfNeeded()
                                    lastActionMessage = "Wallet created. Now refresh balance."
                                } catch {
                                    lastActionMessage = "Wallet create failed: \(error.localizedDescription)"
                                }
                            }
                        } label: {
                            Label("Create Devnet Wallet", systemImage: "wallet.pass")
                        }
                        .buttonStyle(.borderedProminent)
                    } else {
                        Button {
                            Task {
                                await refreshBalance()
                            }
                        } label: {
                            if solana.isRefreshing {
                                ProgressView()
                                    .progressViewStyle(.circular)
                            } else {
                                Label("Refresh", systemImage: "arrow.clockwise")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(solana.isRefreshing || internet.isAvailable == false)
                    }
                }

                if internet.isAvailable == false {
                    Text("Offline: showing cached wallet state.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Text("Devnet faucet tip: if your SOL balance is 0, use Solana devnet airdrop/faucet from a browser or `solana airdrop` in your terminal, then return to Wallet → Refresh.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .accessibilityLabel("Wallet overview")
        }
    }

    var offlineComposerSection: some View {
        Section("Offline mesh payment") {
            VStack(alignment: .leading, spacing: 10) {
                if contacts.isEmpty {
                    Text("No saved contacts yet. Add contacts from the Dashboard or Chat so you can send offline payments.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    Picker("Recipient", selection: $offlineRecipientID) {
                        Text("Select…").tag(Optional<String>.none)
                        ForEach(contacts, id: \.id) { c in
                            Text(c.nickname).tag(Optional(c.id))
                        }
                    }

                    TextField("Amount (SOL)", text: $offlineAmountSOL)
                        .keyboardType(.decimalPad)
                        .accessibilityLabel("Offline amount in SOL")

                    TextField("Memo (optional)", text: $offlineMemo)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityLabel("Offline memo")

                    Button {
                        Task {
                            await sendOfflinePayment()
                        }
                    } label: {
                        if offlineSending {
                            ProgressView()
                                .progressViewStyle(.circular)
                        } else {
                            Label("Send offline payment over mesh", systemImage: "paperplane")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(offlineSending || offlineRecipientID == nil || offlineAmountSOL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    var onlineTransferSection: some View {
        Section("Online direct transfer") {
            VStack(alignment: .leading, spacing: 10) {
                Text("Send plain devnet SOL to a Solana address when internet is available. This is independent from offline mesh payment pending records.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                TextField("Recipient Solana address (base58)", text: $onlineRecipientAddress)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .accessibilityLabel("Recipient Solana address")

                TextField("Amount (SOL)", text: $onlineAmountSOL)
                    .keyboardType(.decimalPad)
                    .accessibilityLabel("Online transfer amount in SOL")

                Button {
                    Task {
                        await sendOnlineSOL()
                    }
                } label: {
                    if onlineSending {
                        ProgressView()
                            .progressViewStyle(.circular)
                    } else {
                        Label("Send devnet SOL", systemImage: "arrow.up.right.square")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(onlineSending || internet.isAvailable == false || onlineRecipientAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                if let sig = onlineTxSignature {
                    Text("Tx signature: \(sig)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
    }

    var paymentActivitySection: some View {
        Section("Payment activity") {
            VStack(alignment: .leading, spacing: 10) {
                if paymentStatuses.isEmpty {
                    Text("No pending offline mesh payments yet.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(paymentStatuses) { st in
                        VStack(alignment: .leading, spacing: 6) {
                            Button {
                                receiptSelection = ReceiptSelection(paymentID: st.id, direction: st.direction)
                            } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("\(formatLamports(st.draft.amountLamports)) · \(st.draft.asset.symbol)")
                                        .font(.headline)

                                    HStack(spacing: 6) {
                                        if st.queuedOutbound { StatusChip(label: "Queued", color: .orange) }
                                        if st.sentOverMesh { StatusChip(label: "Sent over mesh", color: .blue) }

                                        // Canonical settlement lifecycle.
                                        if st.pending { StatusChip(label: "Pending (not submitted)", color: .green) }
                                        if st.submitting { StatusChip(label: "Submitting", color: .yellow) }
                                        if st.settled { StatusChip(label: "Settled", color: .green) }
                                        if st.duplicate { StatusChip(label: "Duplicate", color: .secondary) }
                                        if st.conflict { StatusChip(label: "Conflict", color: .red) }
                                        if st.failed { StatusChip(label: "Failed", color: .red) }
                                        if st.invalid { StatusChip(label: "Invalid", color: .red) }
                                        if st.rejected { StatusChip(label: "Rejected", color: .red) }
                                        if st.expired { StatusChip(label: "Expired", color: .secondary) }
                                    }

                                    if let memo = st.draft.memo, !memo.isEmpty {
                                        Text("Memo: \(memo)")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(2)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.vertical, 6)
                    }
                }

                Divider()

                HStack {
                    Text("Settlement sync")
                        .font(.headline)
                    Spacer()
                    if settlementSync.syncInProgress {
                        ProgressView()
                    } else {
                        Text(settlementSync.isOnline ? "Online" : "Offline")
                            .font(.caption)
                            .foregroundStyle(settlementSync.isOnline ? .green : .secondary)
                    }
                }

                Button {
                    Task { await settlementSync.syncNow(reason: .manual) }
                } label: {
                    Label("Sync now", systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!settlementSync.isOnline || settlementSync.syncInProgress)

                if let err = settlementSync.lastSyncError, !err.isEmpty {
                    Text("Sync error: \(err)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }

#if DEBUG
                VStack(alignment: .leading, spacing: 6) {
                    Text("Debug settlement")
                        .font(.headline)
                    Button {
                        SettlementAPIClient.shared.setDebugMode(.transientFailureOnce)
                        Task { await settlementSync.syncNow(reason: .manual) }
                    } label: {
                        Label("Simulate transient backend failure", systemImage: "timer")
                    }
                    .buttonStyle(.bordered)
                    .disabled(!settlementSync.isOnline)

                    Button {
                        SettlementAPIClient.shared.setDebugMode(.duplicateOnce)
                        Task { await settlementSync.syncNow(reason: .manual) }
                    } label: {
                        Label("Simulate duplicate outcome", systemImage: "repeat")
                    }
                    .buttonStyle(.bordered)
                    .disabled(!settlementSync.isOnline)
                }
#endif
            }
        }
    }
}

// MARK: - Helpers

private extension WalletTabView {
    func formatLamports(_ lamports: Int64) -> String {
        let sol = Decimal(lamports) / Decimal(1_000_000_000)
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 9
        return "\(formatter.string(from: sol as NSDecimalNumber) ?? "\(sol)") SOL"
    }

    func parseSOLToLamports(_ solString: String) -> Int64? {
        let trimmed = solString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let dec = Decimal(string: trimmed) else { return nil }
        let lamports = dec * Decimal(1_000_000_000)
        return NSDecimalNumber(decimal: lamports).int64Value
    }

    @MainActor
    private func refreshBalance() async {
        solana.lastError = nil
        solana.isRefreshing = true
        defer { solana.isRefreshing = false }
        do {
            _ = try await solana.fetchBalance()
        } catch {
            solana.lastError = error.localizedDescription
            lastActionMessage = "Balance refresh failed: \(error.localizedDescription)"
        }
    }

    @MainActor
    private func loadRecentPayments() async {
        do {
            paymentStatuses = try DatabaseManager.shared.fetchRecentPaymentsMerged(forDeviceID: mesh.identity.deviceID, limit: 20)
        } catch {
            paymentStatuses = []
        }
    }

    @MainActor
    private func loadContactsAndPayments() async {
        do {
            contacts = try DatabaseManager.shared.listContacts()
        } catch {
            contacts = []
        }
        await loadRecentPayments()
    }

    private func meshPeerID(for c: SavedContact) -> String {
        DatabaseManager.canonicalSenderID(publicKey: c.publicKey)
    }

    @MainActor
    private func sendOfflinePayment() async {
        guard let rid = offlineRecipientID,
              let recipient = contacts.first(where: { $0.id == rid }) else { return }
        guard let lamports = parseSOLToLamports(offlineAmountSOL), lamports > 0 else {
            lastActionMessage = "Enter a valid amount in SOL (> 0)."
            return
        }

        let memoTrim = offlineMemo.trimmingCharacters(in: .whitespacesAndNewlines)
        let memo = memoTrim.isEmpty ? nil : memoTrim

        offlineSending = true
        defer { offlineSending = false }

        let draft = OfflinePaymentDraft(
            id: UUID().uuidString,
            recipientDeviceID: meshPeerID(for: recipient),
            recipientNickname: recipient.nickname,
            amountLamports: lamports,
            asset: .sol,
            memo: memo,
            createdAt: Int64(Date().timeIntervalSince1970),
            expiresAt: Int64(Date().timeIntervalSince1970) + 7 * 24 * 3600
        )

        do {
            try await mesh.sendOfflinePayment(draft: draft)
            lastActionMessage = "Offline payment sent. Receiver will show 'Pending (not submitted)'."
            offlineAmountSOL = ""
            offlineMemo = ""
        } catch {
            lastActionMessage = "Offline payment failed: \(error.localizedDescription)"
        }
    }

    @MainActor
    private func sendOnlineSOL() async {
        guard let lamports = parseSOLToLamports(onlineAmountSOL), lamports > 0 else {
            lastActionMessage = "Enter a valid amount in SOL (> 0)."
            return
        }
        let to = onlineRecipientAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !to.isEmpty else { return }

        onlineSending = true
        defer { onlineSending = false }

        do {
            let signature = try await solana.sendSOL(to: to, amountLamports: lamports)
            onlineTxSignature = signature
            lastActionMessage = "Online devnet transfer sent."
            // Refresh cached balance to reflect the transaction (best-effort).
            try? await solana.fetchBalance()
        } catch {
            lastActionMessage = "Online transfer failed: \(error.localizedDescription)"
        }
    }
}

private struct StatusChip: View {
    let label: String
    let color: Color

    var body: some View {
        Text(label)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Capsule().fill(color.opacity(0.2)))
            .foregroundStyle(color)
    }
}

private struct ReceiptSelection: Identifiable, Equatable {
    let paymentID: String
    let direction: PaymentDirection
    var id: String { "\(direction.rawValue):\(paymentID)" }
}

private struct PaymentReceiptView: View {
    let paymentID: String
    let direction: PaymentDirection
    let settlementSync: SettlementSyncService

    @State private var payment: PendingPayment?
    @State private var events: [SettlementEventRow] = []
    @State private var loadError: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                if let p = payment {
                    Section("Overview") {
                        LabeledContent("Amount") {
                            Text("\(formatLamports(p.amountLamports)) \(p.asset.symbol)")
                        }
                        LabeledContent("From") {
                            Text(p.senderName)
                                .lineLimit(2)
                        }
                        LabeledContent("To") {
                            Text(p.recipientName)
                                .lineLimit(2)
                        }
                        LabeledContent("Created") {
                            Text(Date(timeIntervalSince1970: TimeInterval(p.createdAt)).formatted(date: .numeric, time: .shortened))
                        }
                        if let exp = p.expiresAt {
                            LabeledContent("Expires") {
                                Text(Date(timeIntervalSince1970: TimeInterval(exp)).formatted(date: .numeric, time: .shortened))
                            }
                        }
                    }

                    Section("Settlement") {
                        LabeledContent("Status") {
                            Text(friendlyStatus(for: p.status))
                        }
                        if let receipt = p.backendReceiptID {
                            LabeledContent("Backend receipt") {
                                Text(receipt).textSelection(.enabled)
                            }
                        }
                        if let sig = p.transactionSignature {
                            LabeledContent("Tx signature") {
                                Text(sig).textSelection(.enabled)
                            }
                        }
                        if let settledAt = p.settledAt {
                            LabeledContent("Settled at") {
                                Text(Date(timeIntervalSince1970: TimeInterval(settledAt)).formatted(date: .numeric, time: .shortened))
                            }
                        }
                        if let reason = p.failureReason {
                            LabeledContent("Failure reason") {
                                Text(reason).foregroundStyle(.red)
                            }
                        }
                        if let reason = p.conflictReason {
                            LabeledContent("Conflict reason") {
                                Text(reason).foregroundStyle(.red)
                            }
                        }
                    }

                    Section("Retry metadata") {
                        if let last = p.lastSubmissionAttemptAt {
                            LabeledContent("Last attempt") {
                                Text(Date(timeIntervalSince1970: TimeInterval(last)).formatted(date: .numeric, time: .shortened))
                            }
                        }
                        if let a = p.attemptCount {
                            LabeledContent("Attempt count") { Text("\(a)") }
                        }
                        if let next = p.nextRetryAt {
                            LabeledContent("Next retry") {
                                Text(Date(timeIntervalSince1970: TimeInterval(next)).formatted(date: .numeric, time: .shortened))
                            }
                        }
                        if let err = p.lastErrorSummary {
                            LabeledContent("Last error") {
                                Text(err).foregroundStyle(.secondary)
                            }
                        }
                    }

                    if !events.isEmpty {
                        Section("History") {
                            ForEach(events) { ev in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(ev.statusAfter.rawValue)
                                        .font(.subheadline.weight(.semibold))
                                    Text(ev.notes)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(3)
                                }
                                .padding(.vertical, 6)
                            }
                        }
                    }
                } else if let err = loadError {
                    Text(err)
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, minHeight: 120)
                }
            }
            .navigationTitle("Receipt")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Retry sync") {
                        Task { await settlementSync.syncNow(reason: .manual) }
                    }
                    .disabled(!settlementSync.isOnline || settlementSync.syncInProgress)
                }
            }
            .task {
                await load()
            }
        }
    }

    private func load() async {
        do {
            payment = try DatabaseManager.shared.fetchPendingPayment(paymentID: paymentID, direction: direction)
            events = try DatabaseManager.shared.fetchSettlementEvents(for: paymentID, limit: 10)
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func formatLamports(_ lamports: Int64) -> String {
        let sol = Decimal(lamports) / Decimal(1_000_000_000)
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 9
        return "\(formatter.string(from: sol as NSDecimalNumber) ?? "\(sol)")"
    }

    private func friendlyStatus(for phase: PaymentPhase) -> String {
        switch phase {
        case .pending, .receivedPending, .queuedOutbound, .sentOverMesh, .settlementPending:
            return "Pending (not submitted)"
        case .submitted:
            return "Submitting"
        case .settled:
            return "Settled"
        case .failed:
            return "Failed"
        case .duplicate:
            return "Duplicate"
        case .conflict:
            return "Conflict"
        case .invalid:
            return "Invalid"
        case .expired:
            return "Expired"
        case .rejected:
            return "Rejected"
        }
    }
}

#Preview {
    WalletTabView()
        .environmentObject(BluetoothMeshService())
        .environmentObject(SettlementSyncService())
}

