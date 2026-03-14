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
            case .help, .medical, .other:
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
                                        .font(.system(.caption, design: .monospaced))
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
                .font(.system(.caption, design: .monospaced))
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
                        .font(.system(.caption, design: .monospaced))
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
        case .help, .medical, .other:
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
