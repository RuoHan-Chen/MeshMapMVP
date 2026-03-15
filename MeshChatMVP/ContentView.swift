import SwiftUI

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

            DebugDashboardView()
                .tabItem { Label("Dashboard", systemImage: "square.grid.2x2") }

            ContactsListView()
                .environmentObject(mesh)
                .tabItem { Label("Contacts", systemImage: "person.2") }

            ProfileView()
                .tabItem { Label("You", systemImage: "person.circle") }
        }
        .onAppear {
            nicknameEditor = mesh.identity.nickname
            mesh.syncScanTimingFromUI()
        }
    }
}

private struct ProfileView: View {
    @EnvironmentObject var mesh: BluetoothMeshService
    @StateObject private var wifiMonitor = WiFiMonitor()
    @State private var nicknameEditor = ""
    @State private var publishInProgress = false
    @State private var publishMessage: String? = nil
    @State private var publishSuccess = false

    var body: some View {
        NavigationStack {
            Form {
                if wifiMonitor.isOnWifi {
                    Section {
                        Text("Upload current map labels and photos to MeshNews so they can appear as local stories.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Button {
                            Task { await publishToMeshNews() }
                        } label: {
                            HStack {
                                Label("Upload and publish map data", systemImage: "square.and.arrow.up")
                                if publishInProgress {
                                    Spacer()
                                    ProgressView()
                                }
                            }
                        }
                        .disabled(publishInProgress)
                        if let msg = publishMessage {
                            Text(msg)
                                .font(.caption)
                                .foregroundStyle(publishSuccess ? Color.secondary : Color.red)
                        }
                    } header: {
                        Text("Publish to MeshNews")
                    }
                }
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
                Section("Tips") {
                    Text("Open Chat on both phones. Dashboard shows scan windows and auto-connect. Keep apps in foreground for best results.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("You")
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

#Preview {
    ContentView()
        .environmentObject(BluetoothMeshService())
}
