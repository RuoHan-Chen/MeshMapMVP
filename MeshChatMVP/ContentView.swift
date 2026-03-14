import SwiftUI

struct ContentView: View {
    @EnvironmentObject var mesh: BluetoothMeshService
    @State private var nicknameEditor = ""

    var body: some View {
        TabView {
            ChatView()
                .tabItem { Label("Chat", systemImage: "bubble.left.and.bubble.right") }

            DebugDashboardView()
                .tabItem { Label("Dashboard", systemImage: "square.grid.2x2") }

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
                    LabeledContent("Device ID") {
                        Text(mesh.identity.deviceID)
                            .font(.caption)
                            .textSelection(.enabled)
                    }
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
