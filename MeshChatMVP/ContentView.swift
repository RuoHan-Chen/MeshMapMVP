import SwiftUI
import CoreBluetooth

struct ContentView: View {
    @EnvironmentObject var mesh: BluetoothMeshService
    @State private var nicknameEditor = ""

    var body: some View {
        TabView {
            ChatView()
                .tabItem { Label("Chat", systemImage: "bubble.left.and.bubble.right") }

            MapTabView()
                .tabItem { Label("Map", systemImage: "map") }

            AlertFeedView()
                .tabItem { Label("Alerts", systemImage: "exclamationmark.triangle") }

            ContactsListView()
                .environmentObject(mesh)
                .tabItem { Label("Contacts", systemImage: "person.2") }

            ProfileView()
                .tabItem { Label("Account", systemImage: "person.circle") }
        }
        .onAppear {
            nicknameEditor = mesh.identity.nickname
            mesh.syncScanTimingFromUI()
        }
    }
}

private struct ProfileView: View {
    @EnvironmentObject var mesh: BluetoothMeshService
    @State private var nicknameEditor = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Identity") {
                    TextField("Nickname", text: $nicknameEditor)
                    Button("Save nickname") {
                        var id = mesh.identity
                        id.nickname = nicknameEditor.isEmpty ? id.nickname : nicknameEditor
                        mesh.updateIdentity(id)
                    }
                    LabeledContent("Public key (mesh id)") {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(KeyManager.fingerprint(KeyManager.publicKeyData, length: 12))
                                .font(.caption.monospaced())
                            Text(mesh.identity.deviceID)
                                .font(.caption2)
                                .textSelection(.enabled)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Section("Privacy") {
                    Toggle("Share my location with peers", isOn: Binding(
                        get: { mesh.identity.shareLocation },
                        set: { newValue in
                            var id = mesh.identity
                            id.shareLocation = newValue
                            mesh.updateIdentity(id)
                        }
                    ))
                    Text("When on, your coordinates are included in messages so others can see approximate distance. You can turn this off anytime.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                
                Section {
                    NavigationLink("Settings") {
                        SettingsView()
                    }
                }
                
                Section("Tips") {
                    Text("Open Chat on both phones. Dashboard shows scan windows and auto-connect. Keep apps in foreground for best results.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Account")
            .onAppear { nicknameEditor = mesh.identity.nickname }
        }
    }
}

private struct SettingsView: View {
    @EnvironmentObject var mesh: BluetoothMeshService
    
    var body: some View {
        Form {
            Section("Data & Storage") {
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
            
            Section {
                NavigationLink("Advanced Settings") {
                    AdvancedSettingsView()
                }
            }
        }
        .navigationTitle("Settings")
    }
}

private struct AdvancedSettingsView: View {
    @EnvironmentObject var mesh: BluetoothMeshService
    @State private var editorPeer: DiscoveredPeer?

    var body: some View {
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

            Section("Log") {
                Text(mesh.debugLines.joined(separator: "\n"))
                    .font(.system(size: 10, design: .monospaced))
                    .textSelection(.enabled)
            }
        }
        .navigationTitle("Advanced Settings")
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
                Text("RSSI \(p.rssi) · \(p.linkState)" + (centralState.map { " · \($0)" } ?? ""))
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
    ContentView()
        .environmentObject(BluetoothMeshService())
}