import SwiftUI
import CoreBluetooth

/// Network diagnostics panel.
struct DebugDashboardView: View {
    @EnvironmentObject var mesh: BluetoothMeshService

    var body: some View {
        NavigationStack {
            List {
                Section {
                    connectionRow
                    LabeledContent("Subscribers") {
                        Text("\(mesh.subscribedCentralCount)").foregroundStyle(.secondary)
                    }
                    LabeledContent("Outbound Links") {
                        Text("\(mesh.readyRemoteCount) / \(mesh.connectedPeerNames.count)").foregroundStyle(.secondary)
                    }
                } header: {
                    Label("Bluetooth", systemImage: "bolt").font(.footnote.weight(.medium)).textCase(nil)
                }

                Section {
                    Toggle("Auto-Connect", isOn: $mesh.autoConnectEnabled).tint(.primary)
                    Toggle("Auto-Reconnect", isOn: $mesh.autoReconnectEnabled).tint(.primary)
                    sliderRow(label: "Scan On", value: $mesh.scanWindowSeconds, range: 4...30, step: 1)
                    sliderRow(label: "Scan Off", value: $mesh.scanIdleSeconds, range: 15...120, step: 5)
                    Button { mesh.syncScanTimingFromUI() } label: {
                        Label("Apply Timing", systemImage: "checkmark.circle").foregroundStyle(.primary)
                    }
                    LabeledContent("Status") {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(mesh.isScanning ? Color.green : Color(.systemGray4))
                                .frame(width: 7, height: 7)
                            Text(mesh.isScanning ? "Scanning" : "Idle")
                                .foregroundStyle(.secondary)
                        }
                    }
                    if !mesh.isScanning, mesh.secondsUntilNextScan > 0 {
                        LabeledContent("Next Scan") {
                            Text("\(Int(mesh.secondsUntilNextScan))s").monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                    Button { mesh.scanNow() } label: {
                        Label("Scan Now", systemImage: "antenna.radiowaves.left.and.right").foregroundStyle(.primary)
                    }
                } header: {
                    Label("Scan Cycle", systemImage: "timer").font(.footnote.weight(.medium)).textCase(nil)
                } footer: {
                    Text("Shorter scan windows save battery. Tap Scan Now to connect immediately.")
                }

                Section {
                    if mesh.discoveredPeers.isEmpty {
                        Text("No peers visible in the current scan window. Keep both apps open and wait for the next cycle.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    } else {
                        ForEach(mesh.discoveredPeers) { p in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(p.name).font(.subheadline.weight(.semibold))
                                let state = mesh.debugConnectionRows.first(where: { $0.id == p.id })?.state
                                Text("RSSI \(p.rssi)  ·  \(p.linkState)" + (state.map { "  ·  \($0)" } ?? ""))
                                    .font(.caption).foregroundStyle(.secondary)
                                Text(p.id.uuidString)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.tertiary).lineLimit(1)
                            }
                            .padding(.vertical, 3)
                        }
                    }
                } header: {
                    Label("Peers", systemImage: "person.2").font(.footnote.weight(.medium)).textCase(nil)
                }

                Section {
                    Button("Clear Log", role: .destructive) { mesh.clearDebugLog() }
                }

                Section {
                    Text(mesh.debugLines.joined(separator: "\n"))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                } header: {
                    Label("Log", systemImage: "doc.text").font(.footnote.weight(.medium)).textCase(nil)
                }
            }
            .navigationTitle("Network")
        }
    }

    private var connectionRow: some View {
        HStack {
            Text("Bluetooth")
            Spacer()
            HStack(spacing: 6) {
                Circle()
                    .fill(mesh.bluetoothState == .poweredOn ? Color.green : Color.orange)
                    .frame(width: 7, height: 7)
                Text(stateLabel(mesh.bluetoothState))
                    .foregroundStyle(mesh.bluetoothState == .poweredOn ? .primary : .orange)
            }
        }
    }

    @ViewBuilder
    private func sliderRow(label: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(label).font(.subheadline)
                Spacer()
                Text("\(Int(value.wrappedValue))s")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 36, alignment: .trailing)
            }
            Slider(value: value, in: range, step: step).tint(.primary)
        }
        .padding(.vertical, 4)
    }

    private func stateLabel(_ s: CBManagerState) -> String {
        switch s {
        case .poweredOn: return "On"
        case .poweredOff: return "Off"
        case .unauthorized: return "Denied"
        case .unsupported: return "Unsupported"
        case .resetting: return "Resetting"
        default: return "Unknown"
        }
    }
}

#Preview {
    DebugDashboardView().environmentObject(BluetoothMeshService())
}
