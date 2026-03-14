import SwiftUI
import CoreLocation

struct ContentView: View {
    @EnvironmentObject var mesh: BluetoothMeshService
    
    var body: some View {
        VStack(spacing: 0) {
            MeshStatusBar()
            
            TabView {
                AlertsFeedView()
                    .tabItem { Label("Alerts", systemImage: "exclamationmark.triangle") }
                    .badge(shouldShowAlertBadge ? "!" : nil)
                
                ChatView()
                    .tabItem { Label("Chat", systemImage: "bubble.left.and.bubble.right") }
                    .badge(mesh.contactUnreadTotal > 0 ? "\(mesh.contactUnreadTotal)" : nil)
                
                MapTabView()
                    .tabItem { Label("Map", systemImage: "map") }
                
                NetworkView()
                    .tabItem { Label("Network", systemImage: "person.2") }
                
                ProfileView()
                    .tabItem { Label("Profile", systemImage: "person.circle") }
            }
        }
        .onAppear {
            mesh.syncScanTimingFromUI()
        }
    }
    
    private var shouldShowAlertBadge: Bool {
        // Active high-confidence (>70%) map labels within 5km
        let highConfidenceLabels = mesh.mapLabels.values.filter { payload in
            let votes = mesh.labelVotes[payload.id] ?? [:]
            let upVotes = votes.values.filter { $0 == 1 }.count
            let downVotes = votes.values.filter { $0 == -1 }.count
            let total = upVotes + downVotes
            let score = total > 0 ? Double(upVotes) / Double(total) : 0.5
            
            if score <= 0.7 { return false }
            
            // Check expiry
            let date = Date(timeIntervalSince1970: Double(payload.timestamp) / 1000)
            if Date().timeIntervalSince(date) > MapLabelRecord.eventExpirationInterval { return false }
            
            // Check distance
            if let myLoc = mesh.lastKnownLocation {
                let dist = BluetoothMeshService.haversineMeters(lat1: myLoc.lat, lon1: myLoc.lon, lat2: payload.lat, lon2: payload.lon)
                if dist > 5000 { return false }
            }
            
            return true
        }
        
        return !highConfidenceLabels.isEmpty || mesh.contactUnreadTotal > 0
    }
}

#Preview {
    ContentView()
        .environmentObject(BluetoothMeshService())
}
