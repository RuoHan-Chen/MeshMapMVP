import SwiftUI
import MapKit

// Disambiguate our Alert model from SwiftUI.Alert.
private typealias MeshAlert = Alert

struct AlertFeedView: View {
    @EnvironmentObject var mesh: BluetoothMeshService
    @Binding var selectedTab: Int
    @Binding var mapRegion: MKCoordinateRegion
    @AppStorage("accessibilityMode") private var accessibilityMode = false
    @AppStorage("accessibilitySpeakAlerts") private var accessibilitySpeakAlerts = true
    @AppStorage("accessibilityLargeText") private var accessibilityLargeText = true

    @State private var clusters: [LabelEventCluster] = []
    @State private var myVotes:  [UUID: Int]         = [:]
    @State private var lastSpokenClusterIds: Set<UUID> = []

    private let timer = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationStack {
            List {
                ForEach(clusters) { cluster in
                    LabelEventClusterRow(
                        cluster:    cluster,
                        myVotes:    myVotes,
                        myDeviceID: mesh.identity.deviceID,
                        accessibilityMode: accessibilityMode,
                        accessibilityLargeText: accessibilityLargeText,
                        onVote: { labelID, confirms in
                            mesh.voteForLabel(labelId: labelID, up: confirms)
                            myVotes[labelID] = confirms ? 1 : -1
                            reload()
                        },
                        onNavigate: { lat, lon in
                            mapRegion.center = CLLocationCoordinate2D(latitude: lat, longitude: lon)
                            mapRegion.span = MKCoordinateSpan(latitudeDelta: 0.002, longitudeDelta: 0.002)
                            selectedTab = 1 // Switch to Map tab
                        }
                    )
                }
            }
            .listStyle(.plain)
            .overlay {
                if clusters.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "bell.slash")
                            .font(accessibilityMode && accessibilityLargeText ? .title : .largeTitle)
                            .foregroundStyle(accessibilityMode ? .primary : .secondary)
                        Text("No Active Alerts")
                            .font(accessibilityMode && accessibilityLargeText ? .title2 : .headline)
                        Text("Alerts from the mesh will appear here.")
                            .font(accessibilityMode && accessibilityLargeText ? .body : .caption)
                            .foregroundStyle(accessibilityMode ? .primary : .secondary)
                    }
                }
            }
            .navigationTitle("Alerts")
            .onAppear(perform: reload)
            .onReceive(timer) { _ in reload() }
            .onChange(of: mesh.mapLabels.count)  { _ in reload() }
            .onChange(of: mesh.labelVotes.count) { _ in reload() }
        }
    }

    // MARK: - Data loading

    private func reload() {
        // Capture main-thread properties before going async.
        let labels = mesh.mapLabels
        let votes  = mesh.labelVotes
        let myID   = mesh.identity.deviceID

        DispatchQueue.global(qos: .userInitiated).async {
            let newClusters = buildClusters(labels: labels, votes: votes, myID: myID)
            let newMyVotes  = buildMyVotes(labels: labels, votes: votes, myID: myID)
            DispatchQueue.main.async {
                clusters = newClusters
                myVotes  = newMyVotes
                if accessibilityMode && accessibilitySpeakAlerts {
                    for cluster in newClusters {
                        let id = cluster.leadScoredLabel.payload.id
                        guard !lastSpokenClusterIds.contains(id) else { continue }
                        let cat = LabelCategory(rawValue: cluster.leadScoredLabel.payload.category) ?? .other
                        let isCritical = (cat == .emergency || cat == .hazard || cat == .armedConflict || cat == .explosion || cat == .drone)
                        if isCritical {
                            let name = cluster.leadScoredLabel.payload.customLabelName.flatMap { $0.isEmpty ? nil : $0 }
                                ?? cat.displayName
                            let desc = cluster.leadScoredLabel.payload.customDescription ?? ""
                            let msg = desc.isEmpty
                                ? "Emergency alert nearby. \(name) reported."
                                : "Emergency alert nearby. \(name). \(desc)"
                            SpeechManager.shared.speak(msg)
                            lastSpokenClusterIds.insert(id)
                        }
                    }
                }
            }
        }
    }

    private func buildClusters(
        labels: [UUID: MapLabelPayload],
        votes:  [UUID: [String: Int]],
        myID:   String
    ) -> [LabelEventCluster] {
        let now        = Date()
        let expiry     = MapLabelRecord.eventExpirationInterval
        let contacts   = (try? DatabaseManager.shared.listContacts()) ?? []

        var relationships: [String: String] = [:]
        for sc in contacts {
            let sid = DatabaseManager.canonicalSenderID(publicKey: sc.publicKey)
            relationships[sid] = sc.relationship
        }

        var nodeIDs = Set(labels.values.map { $0.senderID })
        for v in votes.values { nodeIDs.formUnion(v.keys) }

        var sightings: [String: NodeSighting] = [:]
        for nodeID in nodeIDs {
            if let s = try? DatabaseManager.shared.recentSightings(for: nodeID, limit: 1).first {
                sightings[nodeID] = s
            }
        }

        let scored: [ScoredLabel] = labels.compactMap { id, payload in
            let age = now.timeIntervalSince1970 - Double(payload.timestamp) / 1000.0
            guard age <= expiry else { return nil }
            let score = AlertTrustEngine.scoreLabel(
                authorID:      payload.senderID,
                lat:           payload.lat,
                lon:           payload.lon,
                timestampMs:   payload.timestamp,
                votes:         votes[id] ?? [:],
                relationships: relationships,
                sightings:     sightings,
                myDeviceID:    myID,
                now:           now
            )
            return ScoredLabel(payload: payload, score: score, voteCount: votes[id]?.count ?? 0)
        }

        return AlertTrustEngine.clusterLabels(scoredLabels: scored)
    }

    private func buildMyVotes(
        labels: [UUID: MapLabelPayload],
        votes:  [UUID: [String: Int]],
        myID:   String
    ) -> [UUID: Int] {
        var result: [UUID: Int] = [:]
        for (id, voteMap) in votes where labels[id] != nil {
            if let mine = voteMap[myID] { result[id] = mine }
        }
        return result
    }
}

// MARK: - Cluster row

private struct LabelEventClusterRow: View {
    let cluster:    LabelEventCluster
    let myVotes:    [UUID: Int]
    let myDeviceID: String
    let accessibilityMode: Bool
    let accessibilityLargeText: Bool
    let onVote:     (UUID, Bool) -> Void
    let onNavigate: (Double, Double) -> Void

    private var leadScored: ScoredLabel   { cluster.leadScoredLabel }
    private var lead: MapLabelPayload     { leadScored.payload }
    private var myVote: Int?              { myVotes[lead.id] }
    private var isOwn: Bool               { lead.senderID == myDeviceID }
    private var isUnverified: Bool        { leadScored.voteCount == 0 }
    private var category: LabelCategory  { LabelCategory(rawValue: lead.category) ?? .other }
    private var displayName: String {
        lead.customLabelName.flatMap { $0.isEmpty ? nil : $0 } ?? category.displayName
    }
    private var pinColor: Color {
        switch category {
        case .emergency, .hazard, .armedConflict, .explosion, .drone: return .red
        case .help:                                                  return .green
        default:                                                     return .orange
        }
    }
    private var timeAgo: String {
        let age = Date().timeIntervalSince1970 - Double(lead.timestamp) / 1000.0
        if age < 60   { return "just now" }
        if age < 3600 { return "\(Int(age / 60))m ago" }
        return "\(Int(age / 3600))h ago"
    }

    private var bodyFont: Font { accessibilityMode && accessibilityLargeText ? .title3 : .body }
    private var captionFont: Font { accessibilityMode && accessibilityLargeText ? .body : .caption }

    var body: some View {
        VStack(alignment: .leading, spacing: accessibilityMode ? 12 : 8) {
            // Tappable content area for navigation
            Button {
                onNavigate(lead.lat, lead.lon)
            } label: {
                VStack(alignment: .leading, spacing: accessibilityMode ? 12 : 8) {
                    HStack(alignment: .top) {
                        Image(systemName: category.systemImage)
                            .font(accessibilityMode ? .title2 : .body)
                            .foregroundStyle(pinColor)
                        Text(displayName)
                            .font(bodyFont)
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        Spacer()
                        if isUnverified {
                            Text("Unverified")
                                .font(captionFont.bold())
                                .foregroundStyle(.orange)
                        } else {
                            Text(String(format: "%.1f", cluster.clusterScore))
                                .font(captionFont.monospacedDigit())
                                .foregroundStyle(accessibilityMode ? .primary : .secondary)
                        }
                    }

                    if let desc = lead.customDescription, !desc.isEmpty {
                        Text(desc)
                            .font(captionFont)
                            .foregroundStyle(accessibilityMode ? .primary : .secondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }

                    HStack(spacing: 4) {
                        if cluster.labels.count > 1 {
                            Text("\(cluster.labels.count) reports")
                                .font(captionFont)
                                .foregroundStyle(accessibilityMode ? .primary : .secondary)
                        }
                        Spacer()
                        Text(timeAgo)
                            .font(captionFont)
                            .foregroundStyle(accessibilityMode ? .primary : .secondary)
                    }
                }
                .frame(minHeight: accessibilityMode ? 44 : nil)
                .padding(.vertical, accessibilityMode ? 8 : 0)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Emergency alert: \(displayName)")
            .accessibilityHint("Tap to view details and location on map")

            if isOwn {
                Text("Your post")
                    .font(captionFont)
                    .foregroundStyle(accessibilityMode ? .primary : .tertiary)
            } else {
                HStack(spacing: 12) {
                    if myVote == 1 {
                        Button { onVote(lead.id, true) } label: {
                            Label("Confirm", systemImage: "hand.thumbsup.fill")
                                .font(captionFont)
                                .frame(maxWidth: .infinity)
                                .frame(minHeight: 44)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.green)
                    } else {
                        Button { onVote(lead.id, true) } label: {
                            Label("Confirm", systemImage: "hand.thumbsup.fill")
                                .font(captionFont)
                                .frame(maxWidth: .infinity)
                                .frame(minHeight: 44)
                        }
                        .buttonStyle(.bordered)
                        .tint(.green)
                        .disabled(myVote == -1)
                        .opacity(myVote == -1 ? 0.5 : 1.0)
                    }

                    if myVote == -1 {
                        Button { onVote(lead.id, false) } label: {
                            Label("Deny", systemImage: "hand.thumbsdown.fill")
                                .font(captionFont)
                                .frame(maxWidth: .infinity)
                                .frame(minHeight: 44)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                    } else {
                        Button { onVote(lead.id, false) } label: {
                            Label("Deny", systemImage: "hand.thumbsdown.fill")
                                .font(captionFont)
                                .frame(maxWidth: .infinity)
                                .frame(minHeight: 44)
                        }
                        .buttonStyle(.bordered)
                        .tint(.red)
                        .disabled(myVote == 1)
                        .opacity(myVote == 1 ? 0.5 : 1.0)
                    }
                }
            }
        }
        .padding(.vertical, accessibilityMode ? 8 : 4)
    }
}
