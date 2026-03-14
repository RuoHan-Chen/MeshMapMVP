import SwiftUI

@main
struct MeshChatApp: App {
    @StateObject private var mesh = BluetoothMeshService()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(mesh)
                .onAppear { mesh.start() }
        }
    }
}
