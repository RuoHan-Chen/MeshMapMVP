import SwiftUI

@main
struct MeshChatApp: App {
    @StateObject private var mesh = BluetoothMeshService()
    @StateObject private var settlementSync = SettlementSyncService()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(mesh)
                .environmentObject(settlementSync)
                .onAppear {
                    mesh.start()
                    settlementSync.start()
                }
        }
    }
}
