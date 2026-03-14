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
import SwiftUI

// MARK: - Colour Palette

extension Color {
    static let meshAccent   = Color(red: 0.91, green: 0.35, blue: 0.24) // #E8593C — primary action / hazard
    static let meshSuccess  = Color(red: 0.11, green: 0.62, blue: 0.46) // #1D9E75 — linked / safe / medical
    static let meshWarn     = Color(red: 0.73, green: 0.46, blue: 0.09) // #BA7517 — caution / checkpoint
    static let meshInfo     = Color(red: 0.09, green: 0.37, blue: 0.65) // #185FA5 — peers / info
    static let mapBackground = Color(red: 0.10, green: 0.14, blue: 0.19) // dark map canvas
}

// MARK: - Shared Badges

struct MeshBadge: View {
    enum Style { case success, warn, danger, info, neutral }
    let text: String
    let style: Style
    
    var body: some View {
        Text(text)
            .font(.caption.monospaced())
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(backgroundColor)
            .foregroundColor(.white)
            .cornerRadius(8)
    }
    
    private var backgroundColor: Color {
        switch style {
        case .success: return .meshSuccess
        case .warn:    return .meshWarn
        case .danger:  return .meshAccent
        case .info:    return .meshInfo
        case .neutral: return .gray
        }
    }
}

struct TrustBadge: View {
    let score: Double // 0.0–1.0
    
    var body: some View {
        Text("TRUST \(Int(score * 100))%")
            .font(.caption.monospaced())
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(backgroundColor)
            .foregroundColor(.white)
            .cornerRadius(8)
    }
    
    private var backgroundColor: Color {
        if score >= 0.80 { return .meshSuccess }
        if score >= 0.55 { return .meshWarn }
        return .meshAccent
    }
}

struct TTLBadge: View {
    let expiresAt: Date
    
    var body: some View {
        let remaining = expiresAt.timeIntervalSince(Date())
        let minutes = max(0, Int(remaining / 60))
        
        Text("\(minutes)m TTL")
            .font(.caption.monospaced())
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(minutes < 5 ? Color.meshAccent : Color.gray.opacity(0.5))
            .foregroundColor(.white)
            .cornerRadius(8)
    }
}

struct HopIndicator: View {
    let hops: Int      // 1–5
    let maxHops: Int   // typically 5
    
    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<maxHops, id: \.self) { i in
                Circle()
                    .fill(i < hops ? Color.meshInfo : Color.gray.opacity(0.3))
                    .frame(width: 6, height: 6)
            }
        }
    }
}
import SwiftUI

struct MeshStatusBar: View {
    @EnvironmentObject var mesh: BluetoothMeshService
    @State private var pulseScale: CGFloat = 1.0
    @State private var pulseOpacity: Double = 1.0

    var body: some View {
        HStack {
            // Left side: animated pulse dot + peer count + link state text
            HStack(spacing: 6) {
                if mesh.isScanning && mesh.readyRemoteCount == 0 {
                    Circle()
                        .fill(Color.meshWarn)
                        .frame(width: 8, height: 8)
                        .scaleEffect(pulseScale)
                        .opacity(pulseOpacity)
                        .onAppear {
                            withAnimation(Animation.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                                pulseScale = 1.5
                                pulseOpacity = 0.5
                            }
                        }
                    Text("SCANNING...")
                        .font(.caption.monospaced())
                        .foregroundColor(.meshWarn)
                } else if mesh.readyRemoteCount > 0 {
                    Circle()
                        .fill(Color.meshSuccess)
                        .frame(width: 8, height: 8)
                    Text("\(mesh.readyRemoteCount) PEERS LINKED")
                        .font(.caption.monospaced())
                        .foregroundColor(.meshSuccess)
                } else {
                    Circle()
                        .fill(Color.gray)
                        .frame(width: 8, height: 8)
                    Text("NO PEERS")
                        .font(.caption.monospaced())
                        .foregroundColor(.secondary)
                }
            }
            
            Spacer()
            
            // Centre: app name "MESHMAP"
            Text("MESHMAP")
                .font(.caption.monospaced())
                .fontWeight(.bold)
                .foregroundColor(.secondary)
            
            Spacer()
            
            // Right side: "BT ON" / "BT OFF"
            Text(mesh.bluetoothState == .poweredOn ? "BT ON" : "BT OFF")
                .font(.caption.monospaced())
                .foregroundColor(mesh.bluetoothState == .poweredOn ? .secondary : .meshAccent)
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
        .background(Color(UIColor.systemBackground))
        .overlay(
            Rectangle()
                .frame(height: 0.5)
                .foregroundColor(Color.gray.opacity(0.3)),
            alignment: .bottom
        )
    }
}
import SwiftUI
import CoreLocation

struct AlertsFeedView: View {
    @EnvironmentObject var mesh: BluetoothMeshService
    @State private var recentAnnouncements: [AnnouncementItem] = []
    @State private var selectedLabel: MapLabelRecord?
    
    // MARK: - Models
    
    struct AnnouncementItem: Identifiable {
        let id = UUID()
        let icon: String
        let title: String
        let subtitle: String
        let date: Date
    }
    
    // MARK: - Computeds
    
    private var activeLabels: [MapLabelRecord] {
        let now = Date()
        guard let myLoc = mesh.lastKnownLocation else { return [] }
        
        return mesh.mapLabels.values.compactMap { payload in
            let votes = mesh.labelVotes[payload.id] ?? [:]
            let upVotes = votes.values.filter { $0 == 1 }.count
            let downVotes = votes.values.filter { $0 == -1 }.count
            let category = LabelCategory(rawValue: payload.category) ?? .other
            
            let record = MapLabelRecord(
                id: payload.id,
                category: category,
                latitude: payload.lat,
                longitude: payload.lon,
                senderID: payload.senderID,
                senderName: payload.senderName,
                date: Date(timeIntervalSince1970: Double(payload.timestamp) / 1000),
                upVotes: upVotes,
                downVotes: downVotes,
                customLabelName: payload.customLabelName,
                customDescription: payload.customDescription,
                customSystemImage: payload.customSystemImage
            )
            
            // Filter: not expired, within 5km
            guard !record.isExpired else { return nil }
            let dist = BluetoothMeshService.haversineMeters(lat1: myLoc.lat, lon1: myLoc.lon, lat2: payload.lat, lon2: payload.lon)
            guard dist <= 5000 else { return nil }
            
            return record
        }
        .sorted { $0.confidenceScore > $1.confidenceScore }
    }
    
    private var activeIncident: MapLabelRecord? {
        activeLabels.first { $0.confidenceScore > 0.7 }
    }
    
    private var prioritySegments: (red: Double, amber: Double, green: Double)? {
        let total = Double(activeLabels.count)
        guard total > 0 else { return nil }
        
        var red = 0.0
        var amber = 0.0
        var green = 0.0
        
        for label in activeLabels {
            switch label.category {
            case .hazard, .armedConflict, .explosion, .drone:
                red += 1
            case .checkpoint, .militaryMovement, .policeCrackdown, .arrests:
                amber += 1
            case .help, .other:
                green += 1
            }
        }
        
        return (red / total, amber / total, green / total)
    }
    
    // MARK: - Body
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    // 4a. Active incident banner
                    if let incident = activeIncident {
                        IncidentBanner(record: incident)
                            .onTapGesture {
                                // Navigate to map and focus (handled by parent/tab switch usually, but here we might need a binding or notification)
                                // For MVP, we'll just open the vote sheet as a detail view
                                selectedLabel = incident
                            }
                    }
                    
                    // 4b. Priority-segmented header bar
                    if let segments = prioritySegments {
                        HStack(spacing: 0) {
                            if segments.red > 0 {
                                Rectangle().fill(Color.meshAccent).frame(width: UIScreen.main.bounds.width * segments.red)
                            }
                            if segments.amber > 0 {
                                Rectangle().fill(Color.meshWarn).frame(width: UIScreen.main.bounds.width * segments.amber)
                            }
                            if segments.green > 0 {
                                Rectangle().fill(Color.meshSuccess).frame(width: UIScreen.main.bounds.width * segments.green)
                            }
                        }
                        .frame(height: 3)
                        .padding(.horizontal, 12)
                    }
                    
                    // 4c. Active events list
                    LazyVStack(spacing: 8) {
                        ForEach(activeLabels) { label in
                            EventRow(record: label)
                                .onTapGesture {
                                    selectedLabel = label
                                }
                        }
                    }
                    .padding(.horizontal, 12)
                    
                    // 4d. Mesh announcements section
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Mesh announcements")
                            .font(.headline)
                            .padding(.horizontal, 12)
                        
                        ForEach(recentAnnouncements) { item in
                            HStack(spacing: 12) {
                                Image(systemName: item.icon)
                                    .font(.system(size: 16))
                                    .frame(width: 32, height: 32)
                                    .background(Color.gray.opacity(0.2))
                                    .cornerRadius(8)
                                    .foregroundColor(.secondary)
                                
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.title)
                                        .font(.body)
                                    Text(item.subtitle)
                                        .font(.caption.monospaced())
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                            }
                            .padding(.horizontal, 12)
                        }
                        
                        if recentAnnouncements.isEmpty {
                            Text("No recent announcements")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .padding(.horizontal, 12)
                        }
                    }
                    .padding(.top, 12)
                }
                .padding(.vertical, 12)
            }
            .navigationTitle("Alerts")
            .sheet(item: $selectedLabel) { record in
                LabelVoteSheet(
                    record: record,
                    myVote: mesh.labelVotes[record.id]?[mesh.identity.deviceID],
                    canDelete: record.senderID == mesh.identity.deviceID,
                    onVote: { up in
                        mesh.voteForLabel(labelId: record.id, up: up)
                    },
                    onDelete: {
                        mesh.removeMapLabel(id: record.id)
                        selectedLabel = nil
                    },
                    selectedLabel: $selectedLabel
                )
            }
        }
        .onAppear {
            // Initial population if needed
        }
        .onChange(of: mesh.discoveredPeers) { newPeers in
            updateAnnouncements(peers: newPeers)
        }
    }
    
    private func updateAnnouncements(peers: [DiscoveredPeer]) {
        // Simple diff logic: if count increased, add "New peer"
        // Ideally we'd track IDs, but for MVP we'll just look for new ones if we had state.
        // Since we don't have previous state easily here without more complex logic,
        // we will just check for "newly discovered" based on lastSeen if it's very recent.
        // Actually, the prompt says "from mesh.discoveredPeers changes".
        // Let's just grab the most recent one if it was seen in the last 10 seconds.
        
        let now = Date().timeIntervalSince1970
        let recent = peers.filter { now - Double($0.lastSeen) < 10 }
        
        for peer in recent {
            // Check if we already have an announcement for this peer in the last minute
            if !recentAnnouncements.contains(where: { $0.title.contains(peer.name) && Date().timeIntervalSince($0.date) < 60 }) {
                let item = AnnouncementItem(
                    icon: "person.wave.2.fill",
                    title: "New peer discovered",
                    subtitle: "\(peer.name) · \(peer.rssi) dBm",
                    date: Date()
                )
                withAnimation {
                    recentAnnouncements.insert(item, at: 0)
                    if recentAnnouncements.count > 10 {
                        recentAnnouncements.removeLast()
                    }
                }
            }
        }
    }
}

// MARK: - Subviews

struct IncidentBanner: View {
    let record: MapLabelRecord
    @EnvironmentObject var mesh: BluetoothMeshService
    
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: record.systemImage)
                .font(.title)
                .foregroundColor(.white)
            
            VStack(alignment: .leading, spacing: 4) {
                Text(record.displayName)
                    .font(.headline)
                    .foregroundColor(.white)
                
                HStack(spacing: 6) {
                    if let myLoc = mesh.lastKnownLocation {
                        let dist = BluetoothMeshService.haversineMeters(lat1: myLoc.lat, lon1: myLoc.lon, lat2: record.latitude, lon2: record.longitude)
                        Text(String(format: "%.0fm away", dist))
                    }
                    Text("·")
                    Text("\(record.upVotes + record.downVotes) votes")
                    Text("·")
                    Text(relativeTime(record.date))
                }
                .font(.caption.monospaced())
                .foregroundColor(.white.opacity(0.9))
            }
            Spacer()
            Image(systemName: "chevron.right")
                .foregroundColor(.white.opacity(0.7))
        }
        .padding()
        .background(Color.meshAccent)
        .cornerRadius(0) // Full width strip? Prompt says "banner", usually implies full width or card. "prominent banner... strip"
    }
    
    private func relativeTime(_ date: Date) -> String {
        let s = Date().timeIntervalSince(date)
        if s < 60 { return "now" }
        if s < 3600 { return "\(Int(s / 60))m ago" }
        return "\(Int(s / 3600))h ago"
    }
}

struct EventRow: View {
    let record: MapLabelRecord
    @EnvironmentObject var mesh: BluetoothMeshService
    
    var body: some View {
        HStack(spacing: 12) {
            // Left: coloured icon square
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(severityColor)
                    .frame(width: 48, height: 48)
                Image(systemName: record.systemImage)
                    .font(.title3)
                    .foregroundColor(.white)
            }
            
            // Middle: label details
            VStack(alignment: .leading, spacing: 4) {
                Text(record.displayName)
                    .font(.headline)
                
                HStack(spacing: 6) {
                    Text(record.senderName)
                        .font(.caption.monospaced())
                    if let myLoc = mesh.lastKnownLocation {
                        let dist = BluetoothMeshService.haversineMeters(lat1: myLoc.lat, lon1: myLoc.lon, lat2: record.latitude, lon2: record.longitude)
                        Text("· \(Int(dist))m")
                            .font(.caption)
                    }
                    Text("· \(record.category.displayName)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .foregroundColor(.secondary)
            }
            
            Spacer()
            
            // Right: time + hop indicator
            VStack(alignment: .trailing, spacing: 4) {
                Text(relativeTime(record.date))
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                // Hop indicator stub (we don't track hops for map labels in MapLabelRecord, assume 1 for now or random for UI demo)
                HopIndicator(hops: 1, maxHops: 5)
            }
        }
        .padding(10)
        .background(Color(UIColor.secondarySystemBackground))
        .cornerRadius(12)
    }
    
    private var severityColor: Color {
        switch record.category {
        case .hazard, .armedConflict, .explosion, .drone:
            return .meshAccent
        case .checkpoint, .militaryMovement, .policeCrackdown, .arrests:
            return .meshWarn
        case .help, .other:
            return .meshSuccess
        }
    }
    
    private func relativeTime(_ date: Date) -> String {
        let s = Date().timeIntervalSince(date)
        if s < 60 { return "now" }
        if s < 3600 { return "\(Int(s / 60))m ago" }
        return "\(Int(s / 3600))h ago"
    }
}
import SwiftUI

struct ProfileView: View {
    @EnvironmentObject var mesh: BluetoothMeshService
    @State private var showCopiedAlert = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    // Header section
                    VStack(spacing: 12) {
                        Circle()
                            .fill(Color.blue)
                            .frame(width: 64, height: 64)
                            .overlay(
                                Text(initials(for: mesh.identity.nickname))
                                    .font(.title)
                                    .fontWeight(.bold)
                                    .foregroundColor(.white)
                            )
                        
                        Text(mesh.identity.nickname)
                            .font(.title2)
                            .fontWeight(.bold)
                        
                        Button {
                            UIPasteboard.general.string = KeyManager.fingerprint(KeyManager.publicKeyData, length: 20)
                            showCopiedAlert = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                showCopiedAlert = false
                            }
                        } label: {
                            HStack {
                                Text(KeyManager.fingerprint(KeyManager.publicKeyData, length: 20))
                                    .font(.caption.monospaced())
                                if showCopiedAlert {
                                    Image(systemName: "checkmark")
                                        .font(.caption)
                                } else {
                                    Image(systemName: "doc.on.doc")
                                        .font(.caption)
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Color(UIColor.secondarySystemBackground))
                            .cornerRadius(8)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.top, 20)
                    
                    // Identity section
                    VStack(alignment: .leading, spacing: 0) {
                        Toggle("Share location with peers", isOn: Binding(
                            get: { mesh.identity.shareLocation },
                            set: { newValue in
                                var id = mesh.identity
                                id.shareLocation = newValue
                                mesh.updateIdentity(id)
                            }
                        ))
                        .padding()
                        
                        Divider()
                        
                        Toggle("Auto-reconnect on drop", isOn: $mesh.autoReconnectEnabled)
                            .padding()
                    }
                    .background(Color(UIColor.secondarySystemBackground))
                    .cornerRadius(12)
                    .padding(.horizontal, 12)
                    
                    // Message expiry section
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Message expiry (TTL)")
                            .font(.headline)
                            .padding(.horizontal, 12)
                        
                        VStack(spacing: 0) {
                            ExpiryRow(label: "Group broadcast", duration: ChatMessage.expirationInterval)
                            Divider()
                            ExpiryRow(label: "Direct messages", duration: BluetoothMeshService.dmDataTTLSeconds)
                            Divider()
                            ExpiryRow(label: "Map labels", duration: MapLabelRecord.eventExpirationInterval, suffix: "· voteable")
                        }
                        .background(Color(UIColor.secondarySystemBackground))
                        .cornerRadius(12)
                        .padding(.horizontal, 12)
                    }
                    
                    // Stored data section
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Stored data")
                            .font(.headline)
                            .padding(.horizontal, 12)
                        
                        VStack(spacing: 0) {
                            Button {
                                mesh.clearChatMessages()
                            } label: {
                                HStack {
                                    Text("Clear chat messages")
                                    Spacer()
                                    Image(systemName: "trash")
                                }
                                .foregroundColor(.meshAccent)
                                .padding()
                            }
                            
                            Divider()
                            
                            Button {
                                mesh.clearLocalEvents()
                            } label: {
                                HStack {
                                    Text("Clear map events")
                                    Spacer()
                                    Image(systemName: "trash")
                                }
                                .foregroundColor(.meshAccent)
                                .padding()
                            }
                        }
                        .background(Color(UIColor.secondarySystemBackground))
                        .cornerRadius(12)
                        .padding(.horizontal, 12)
                    }
                }
                .padding(.bottom, 20)
            }
            .navigationTitle("Profile")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
    
    private func initials(for name: String) -> String {
        String(name.prefix(2)).uppercased()
    }
}

private struct ExpiryRow: View {
    let label: String
    let duration: TimeInterval
    var suffix: String? = nil
    
    var body: some View {
        HStack {
            Text(label)
            Spacer()
            Text("\(Int(duration / 60))m" + (suffix.map { " \($0)" } ?? ""))
                .font(.body.monospaced())
                .foregroundColor(.secondary)
        }
        .padding()
    }
}
