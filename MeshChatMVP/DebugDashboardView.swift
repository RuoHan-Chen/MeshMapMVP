import SwiftUI
import CoreBluetooth

/// BLE + mesh diagnostics; peers show **public-key identity** and tap → add/edit contact.
struct DebugDashboardView: View {
    @EnvironmentObject var mesh: BluetoothMeshService
    @State private var editorPeer: DiscoveredPeer?

    var body: some View {
        NavigationStack {
            List {
                Section("Bluetooth") {
                    LabeledContent("Central / peripheral") {
                        Text(stateLabel(mesh.bluetoothState))
                            .foregroundStyle(mesh.bluetoothState == .poweredOn ? .green : .orange)
                    }
                    LabeledContent("Subscribers (others linked to you)") {
                        Text("\(mesh.subscribedCentralCount)")
                    }
                    LabeledContent("Outbound links ready") {
                        Text("\(mesh.readyRemoteCount) / \(mesh.connectedPeerNames.count)")
                    }
                }

                Section("Scan cycle (saves battery)") {
                    Toggle("Auto-connect when a peer is seen", isOn: $mesh.autoConnectEnabled)
                    Toggle("Auto-reconnect after drop (off = calmer)", isOn: $mesh.autoReconnectEnabled)
                    HStack {
                        Text("Scan ON")
                        Slider(value: $mesh.scanWindowSeconds, in: 4...30, step: 1)
                        Text("\(Int(mesh.scanWindowSeconds))s")
                            .monospacedDigit()
                            .frame(width: 36, alignment: .trailing)
                    }
                    HStack {
                        Text("Scan OFF")
                        Slider(value: $mesh.scanIdleSeconds, in: 15...120, step: 5)
                        Text("\(Int(mesh.scanIdleSeconds))s")
                            .monospacedDigit()
                            .frame(width: 36, alignment: .trailing)
                    }
                    Button("Apply timing (next cycle)") { mesh.syncScanTimingFromUI() }
                    LabeledContent("Status") {
                        HStack {
                            Circle()
                                .fill(mesh.isScanning ? Color.green : Color.orange)
                                .frame(width: 10, height: 10)
                            Text(mesh.isScanning ? "Scanning" : "Idle")
                        }
                    }
                    if !mesh.isScanning, mesh.secondsUntilNextScan > 0 {
                        LabeledContent("Next scan in") {
                            Text("\(Int(mesh.secondsUntilNextScan))s")
                        }
                    }
                    Button("Scan now") { mesh.scanNow() }
                }

                Section("Peers (tap fingerprint to save contact)") {
                    if mesh.discoveredPeers.isEmpty {
                        Text("No peers — both apps open, wait for scan.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(mesh.discoveredPeers) { p in
                            peerRow(p)
                        }
                    }
                }

                Section("Connected (you are central)") {
                    ForEach(mesh.debugConnectionRows) { row in
                        VStack(alignment: .leading) {
                            Text(row.name)
                            Text(row.state).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if mesh.debugConnectionRows.isEmpty {
                        Text("None — auto-connect runs during scan; check log for Fail connect.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Maintenance (local only)") {
                    Button("Clear chat messages", role: .destructive) {
                        mesh.clearChatMessages()
                    }
                    Button("Clear map events", role: .destructive) {
                        mesh.clearLocalEvents()
                    }
                    Button("Clear log", role: .destructive) {
                        mesh.clearDebugLog()
                    }
                }

                Section("Log") {
                    Text(mesh.debugLines.joined(separator: "\n"))
                        .font(.system(size: 10, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
            .navigationTitle("Dashboard")
            .sheet(item: $editorPeer) { peer in
                let pk = peer.publicKey!
                let pid = DatabaseManager.canonicalSenderID(publicKey: pk)
                ContactEditorView(
                    publicKey: pk,
                    existing: try? DatabaseManager.shared.findContactByPublicKey(pk),
                    onSave: { mesh.contactsVersion = UUID() },
                    onDelete: {
                        mesh.removeContactActivity(peerID: pid)
                    }
                )
            }
        }
    }

    @ViewBuilder
    private func peerRow(_ p: DiscoveredPeer) -> some View {
        let pk = p.publicKey
        let saved = pk.flatMap { try? DatabaseManager.shared.findContactByPublicKey($0) }
        let displayName = saved?.nickname
            ?? p.nickname
            ?? (pk.map { KeyManager.fingerprint($0, length: 8) } ?? p.name)
        let fingerprint = pk.map { KeyManager.fingerprint($0, length: 8) } ?? "—"
        let centralState = mesh.debugConnectionRows.first(where: { $0.id == p.id })?.state

        Button {
            if pk != nil { editorPeer = p }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(displayName)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    if let rel = saved?.relationship {
                        Text(rel)
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.secondary.opacity(0.2)))
                    }
                }
                Text(String(format: String(localized: "RSSI %lld · %@"), Int64(p.rssi), p.linkState + (centralState.map { " · \($0)" } ?? "")))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Text(fingerprint)
                        .font(.caption.monospaced())
                        .foregroundStyle(pk == nil ? Color.secondary : Color.accentColor)
                    if pk != nil {
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                Text(pk == nil ? "Connect to receive public key (announce)" : "Tap to add or edit contact")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
        .disabled(pk == nil)
    }

    private func stateLabel(_ s: CBManagerState) -> String {
        switch s {
        case .poweredOn: return String(localized: "On")
        case .poweredOff: return String(localized: "Off")
        case .unauthorized: return String(localized: "Denied")
        case .unsupported: return String(localized: "Unsupported")
        case .resetting: return String(localized: "Resetting")
        default: return "…"
        }
    }
}

#Preview {
    DebugDashboardView()
        .environmentObject(BluetoothMeshService())
}
