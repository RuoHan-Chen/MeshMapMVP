import SwiftUI
import CoreBluetooth

/// BLE + mesh diagnostics: scan cycle, peers, log (separate from chat UX).
struct DebugDashboardView: View {
    @EnvironmentObject var mesh: BluetoothMeshService

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
                    Button("Apply timing (next cycle)") {
                        mesh.syncScanTimingFromUI()
                    }
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
                    Text("Disconnect loop fix: GATT is published once — repeated setup no longer kicks subscribers off.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Section("Peers (discovery + auto-connect)") {
                    if mesh.discoveredPeers.isEmpty {
                        Text("No peers in this scan window — both apps must be open; wait for next scan or tap Scan now.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(mesh.discoveredPeers) { p in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(p.name).font(.headline)
                                Text("RSSI \(p.rssi) · \(p.linkState)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(p.id.uuidString)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                            }
                            .padding(.vertical, 4)
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
        }
    }

    private func stateLabel(_ s: CBManagerState) -> String {
        switch s {
        case .poweredOn: return "On"
        case .poweredOff: return "Off"
        case .unauthorized: return "Denied"
        case .unsupported: return "Unsupported"
        case .resetting: return "Resetting"
        default: return "…"
        }
    }
}

#Preview {
    DebugDashboardView()
        .environmentObject(BluetoothMeshService())
}
