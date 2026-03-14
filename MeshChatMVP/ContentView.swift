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
}

#Preview {
    ContentView()
        .environmentObject(BluetoothMeshService())
}
