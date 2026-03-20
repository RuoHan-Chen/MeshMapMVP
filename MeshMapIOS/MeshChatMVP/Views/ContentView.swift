import SwiftUI
import CoreBluetooth
import MapKit

struct ContentView: View {
    @EnvironmentObject var mesh: BluetoothMeshService
    @State private var nicknameEditor = ""
    @AppStorage("accessibilityMode") private var accessibilityMode = false
    @AppStorage("accessibilitySpeakAlerts") private var accessibilitySpeakAlerts = true
    @AppStorage("accessibilityLargeText") private var accessibilityLargeText = true

    // Lifted map state so Settings can access it (e.g. for offline caching)
    @State private var mapRegion = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: -33.8688, longitude: 151.2093),
        span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
    )
    @State private var isCachingMap = false
    @State private var selectedTab: Int = 2 // Default to Alerts for testing or 0? User didn't specify. Let's stick to 0 or whatever default.
    // Actually, usually 0 (Chat).

    var body: some View {
        TabView(selection: $selectedTab) {
            ChatView()
                .tabItem { Label("Chat", systemImage: "bubble.left.and.bubble.right") }
                .tag(0)

            MapTabView(region: $mapRegion)
                .tabItem { Label("Map", systemImage: "map") }
                .tag(1)

            AlertFeedView(selectedTab: $selectedTab, mapRegion: $mapRegion)
                .tabItem { Label("Alerts", systemImage: "exclamationmark.triangle") }
                .tag(2)

            ContactsListView()
                .environmentObject(mesh)
                .tabItem { Label("Contacts", systemImage: "person.2") }
                .tag(3)

            WalletTabView()
                .tabItem { Label("Wallet", systemImage: "wallet.pass") }
                .tag(5)

            ProfileView(mapRegion: $mapRegion, isCachingMap: $isCachingMap)
                .tabItem { Label("Account", systemImage: "person.circle") }
                .tag(4)
        }
        .dynamicTypeSize(accessibilityMode && accessibilityLargeText ? .large ... .accessibility5 : .xSmall ... .xxxLarge)
        .onAppear {
            nicknameEditor = mesh.identity.nickname
            mesh.syncScanTimingFromUI()
        }
        .onChange(of: mesh.pendingSOSAlert?.labelId.uuidString ?? "") { newId in
            if !newId.isEmpty, let sos = mesh.pendingSOSAlert, accessibilityMode, accessibilitySpeakAlerts {
                SpeechManager.shared.speak("Emergency alert nearby. Assistance requested from \(sos.senderName). Tap View on Map to see location.")
            }
        }
        .alert("SOS / Emergency", isPresented: Binding(
            get: { mesh.pendingSOSAlert != nil },
            set: { if !$0 { mesh.pendingSOSAlert = nil } }
        )) {
            Button("View on Map") {
                if let sos = mesh.pendingSOSAlert {
                    mapRegion.center = CLLocationCoordinate2D(latitude: sos.lat, longitude: sos.lon)
                    mapRegion.span = MKCoordinateSpan(latitudeDelta: 0.002, longitudeDelta: 0.002)
                    selectedTab = 1
                }
                mesh.pendingSOSAlert = nil
            }
            .accessibilityHint("Opens map at emergency location")
            Button("Dismiss", role: .cancel) {
                mesh.pendingSOSAlert = nil
            }
        } message: {
            Text("Emergency assistance requested from \(mesh.pendingSOSAlert?.senderName ?? "someone"). Tap View to see on map.")
        }
        .accessibilityLabel("Emergency alert")
    }
}

private struct ProfileView: View {
    @EnvironmentObject var mesh: BluetoothMeshService
    @AppStorage("accessibilityMode") private var accessibilityMode = false
    @AppStorage("accessibilityLargeText") private var accessibilityLargeText = true
    @StateObject private var wifiMonitor = WiFiMonitor()
    @State private var nicknameEditor = ""
    @Binding var mapRegion: MKCoordinateRegion
    @Binding var isCachingMap: Bool
    @State private var publishInProgress = false
    @State private var publishMessage: String? = nil
    @State private var publishSuccess = false

    var body: some View {
        NavigationStack {
            Form {
                if wifiMonitor.isOnWifi {
                    Section {
                        Text("Upload current map labels and photos to MeshNews so they can appear as local stories.")
                            .font(accessibilityMode && accessibilityLargeText ? .body : .subheadline)
                            .foregroundStyle(accessibilityMode ? .primary : .secondary)
                        Button {
                            Task { await publishToMeshNews() }
                        } label: {
                            HStack {
                                Label("Upload and publish map data", systemImage: "square.and.arrow.up")
                                    .font(accessibilityMode && accessibilityLargeText ? .body : nil)
                                if publishInProgress {
                                    Spacer()
                                    ProgressView()
                                }
                            }
                            .frame(minHeight: accessibilityMode ? 44 : nil)
                        }
                        .disabled(publishInProgress)
                        .accessibilityLabel("Upload and publish map data")
                        .accessibilityHint("Publishes map labels and photos to MeshNews")
                        if let msg = publishMessage {
                            Text(msg)
                                .font(accessibilityMode && accessibilityLargeText ? .body : .caption)
                                .foregroundStyle(publishSuccess ? (accessibilityMode ? Color.primary : Color.secondary) : Color.red)
                        }
                    } header: {
                        Text("Publish to MeshNews")
                    }
                }
                Section("Identity") {
                    TextField("Nickname", text: $nicknameEditor)
                        .font(accessibilityMode && accessibilityLargeText ? .body : nil)
                    Button("Save nickname") {
                        var id = mesh.identity
                        id.nickname = nicknameEditor.isEmpty ? id.nickname : nicknameEditor
                        mesh.updateIdentity(id)
                    }
                    .font(accessibilityMode && accessibilityLargeText ? .body : nil)
                    .frame(minHeight: accessibilityMode ? 44 : nil)
                    .accessibilityLabel("Save nickname")
                    .accessibilityHint("Saves your display name on the mesh")
                    LabeledContent("Public key (mesh id)") {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(KeyManager.fingerprint(KeyManager.publicKeyData, length: 12))
                                .font(accessibilityMode && accessibilityLargeText ? .subheadline.monospaced() : .caption.monospaced())
                            Text(mesh.identity.deviceID)
                                .font(accessibilityMode && accessibilityLargeText ? .caption : .caption2)
                                .textSelection(.enabled)
                                .foregroundStyle(accessibilityMode ? .primary : .secondary)
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
                        .font(accessibilityMode && accessibilityLargeText ? .body : .caption)
                        .foregroundStyle(accessibilityMode ? .primary : .secondary)
                }

                Section {
                    NavigationLink("Settings") {
                        SettingsView(mapRegion: $mapRegion, isCachingMap: $isCachingMap)
                    }
                    .frame(minHeight: accessibilityMode ? 44 : nil)
                    .accessibilityLabel("Settings")
                    .accessibilityHint("Tap to open accessibility and data settings")
                }

                Section("Tips") {
                    Text("Open Chat on both phones. Dashboard shows scan windows and auto-connect. Keep apps in foreground for best results.")
                        .font(accessibilityMode && accessibilityLargeText ? .body : .caption)
                        .foregroundStyle(accessibilityMode ? .primary : .secondary)
                }
            }
            .navigationTitle("Account")
            .onAppear { nicknameEditor = mesh.identity.nickname }
        }
    }

    private func publishToMeshNews() async {
        publishInProgress = true
        publishMessage = nil
        let result = await publishMapDataToMeshNews(mapLabels: mesh.mapLabels, thumbnails: mesh.thumbnails, userLocation: mesh.lastKnownLocation)
        await MainActor.run {
            publishInProgress = false
            switch result {
            case .success:
                publishSuccess = true
                publishMessage = "Published to MeshNews."
            case .failure(let error):
                publishSuccess = false
                publishMessage = error.localizedDescription
            }
        }
    }
}

private struct SettingsView: View {
    @EnvironmentObject var mesh: BluetoothMeshService
    @Binding var mapRegion: MKCoordinateRegion
    @Binding var isCachingMap: Bool
    @State private var showOfflineSheet = false
    @AppStorage("accessibilityMode") private var accessibilityMode = false
    @AppStorage("accessibilitySpeakAlerts") private var accessibilitySpeakAlerts = true
    @AppStorage("accessibilityLargeText") private var accessibilityLargeText = true

    var body: some View {
        Form {
            Section {
                Toggle("Accessibility Mode", isOn: $accessibilityMode)
                if accessibilityMode {
                    Toggle("Speak Alerts", isOn: $accessibilitySpeakAlerts)
                    Toggle("Large Text", isOn: $accessibilityLargeText)
                }
            } header: {
                Text("Accessibility")
            } footer: {
                Text("When on: larger text and buttons, high contrast, and optional spoken alerts for emergencies. Works fully offline.")
            }

            Section("Data & Storage") {
                Button("Offline Maps") {
                    showOfflineSheet = true
                }
                .frame(minHeight: accessibilityMode ? 44 : nil)
                .accessibilityLabel("Offline Maps")
                .accessibilityHint("Tap to cache map areas for offline use")
                Button("Clear chat messages", role: .destructive) {
                    mesh.clearChatMessages()
                }
                .frame(minHeight: accessibilityMode ? 44 : nil)
                Button("Clear map events", role: .destructive) {
                    mesh.clearLocalEvents()
                }
                .frame(minHeight: accessibilityMode ? 44 : nil)
                Button("Clear log", role: .destructive) {
                    mesh.clearDebugLog()
                }
                .frame(minHeight: accessibilityMode ? 44 : nil)
            }

            Section {
                NavigationLink("Advanced Settings") {
                    AdvancedSettingsView()
                }
                .frame(minHeight: accessibilityMode ? 44 : nil)
            }
        }
        .navigationTitle("Settings")
        .sheet(isPresented: $showOfflineSheet) {
            OfflineMapSheet(isCaching: $isCachingMap, region: mapRegion, onCache: cacheCurrentRegion)
        }
    }
    
    /// Preload/cache current map region for better offline use (MapKit caches tiles when rendered).
    private func cacheCurrentRegion() {
        guard !isCachingMap else { return }
        isCachingMap = true
        let options = MKMapSnapshotter.Options()
        options.region = mapRegion
        options.size = CGSize(width: 512, height: 512)
        let snapshotter = MKMapSnapshotter(options: options)
        snapshotter.start { _, _ in
            DispatchQueue.main.async { isCachingMap = false }
        }
    }
}

private struct OfflineMapSheet: View {
    @Binding var isCaching: Bool
    let region: MKCoordinateRegion
    let onCache: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Map tiles are cached as you pan and zoom. To preload the current area, tap below. For full offline use, download regions in the Apple Maps app: Settings → Maps → turn on Offline, or open Maps and download areas before going offline.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Section("This area") {
                    Button {
                        onCache()
                    } label: {
                        HStack {
                            Label("Cache current map area", systemImage: "square.and.arrow.down")
                            if isCaching {
                                Spacer()
                                ProgressView()
                            }
                        }
                    }
                    .disabled(isCaching)
                }
            }
            .navigationTitle("Offline maps")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
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