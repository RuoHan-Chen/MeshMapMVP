import SwiftUI

struct AlertFeedView: View {
    @EnvironmentObject var mesh: BluetoothMeshService

    @State private var clusters:  [AlertCluster] = []
    @State private var myVouches: [String: Int]  = [:]   // alertID → 1 or -1

    // Refresh every minute so decay scores stay current.
    private let timer = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationStack {
            Group {
                if clusters.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "bell.slash")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                        Text("No Active Alerts")
                            .font(.headline)
                        Text("Alerts from the mesh will appear here.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(clusters) { cluster in
                        AlertClusterRow(
                            cluster:  cluster,
                            myVouches: myVouches,
                            onVouch: { alertID, confirms in
                                mesh.sendVouch(alertID: alertID, confirms: confirms)
                                myVouches[alertID] = confirms ? 1 : -1
                                reload()
                            }
                        )
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Alerts")
            .onAppear(perform: reload)
            .onReceive(timer) { _ in reload() }
        }
    }

    // MARK: - Data loading

    private func reload() {
        DispatchQueue.global(qos: .userInitiated).async {
            let newClusters  = buildClusters()
            let newMyVouches = buildMyVouches()
            DispatchQueue.main.async {
                clusters  = newClusters
                myVouches = newMyVouches
            }
        }
    }

    private func buildClusters() -> [AlertCluster] {
        guard
            let pairs         = try? DatabaseManager.shared.alertsWithVouches(),
            let savedContacts = try? DatabaseManager.shared.listContacts()
        else { return [] }

        // Build relationship map: senderID → "friend" | "associate"
        var relationships: [String: String] = [:]
        for sc in savedContacts {
            let sid = DatabaseManager.canonicalSenderID(publicKey: sc.publicKey)
            relationships[sid] = sc.relationship
        }

        // Collect every node ID that appears in alerts or vouches.
        var nodeIDs = Set<String>()
        for (alert, vouches) in pairs {
            nodeIDs.insert(alert.authorID)
            vouches.forEach { nodeIDs.insert($0.voucherID) }
        }

        // Fetch the most-recent sighting per node (small N in a mesh network).
        var sightings: [String: NodeSighting] = [:]
        for nodeID in nodeIDs {
            if let s = try? DatabaseManager.shared.recentSightings(for: nodeID, limit: 1).first {
                sightings[nodeID] = s
            }
        }

        let scored = pairs.map { (alert, vouches) in
            ScoredAlert(
                alert: alert,
                score: AlertTrustEngine.score(
                    alert:         alert,
                    vouches:       vouches,
                    relationships: relationships,
                    sightings:     sightings
                )
            )
        }

        return AlertTrustEngine.cluster(scoredAlerts: scored)
    }

    private func buildMyVouches() -> [String: Int] {
        let myID = mesh.identity.deviceID
        guard let pairs = try? DatabaseManager.shared.alertsWithVouches() else { return [:] }
        var result: [String: Int] = [:]
        for (alert, vouches) in pairs {
            if let mine = vouches.first(where: { $0.voucherID == myID }) {
                result[alert.id] = mine.value
            }
        }
        return result
    }
}

// MARK: - Cluster row

private struct AlertClusterRow: View {
    let cluster:   AlertCluster
    let myVouches: [String: Int]
    let onVouch:   (String, Bool) -> Void

    var body: some View {
        let lead   = cluster.leadAlert
        let myVote = myVouches[lead.id]

        VStack(alignment: .leading, spacing: 8) {
            // Title row
            HStack(alignment: .top) {
                alertIcon(for: lead.type)
                Text(lead.description)
                    .font(.body)
                    .lineLimit(2)
                Spacer()
                Text(String(format: "%.1f", cluster.clusterScore))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            // Meta row
            HStack(spacing: 4) {
                severityBadge(lead.severity)
                Text(typeName(lead.type))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if cluster.alerts.count > 1 {
                    Text("· \(cluster.alerts.count) reports")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(timeAgo(lead.createdAt))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Vouch / deny buttons
            HStack(spacing: 12) {
                Button {
                    onVouch(lead.id, true)
                } label: {
                    Label("Confirm", systemImage: "hand.thumbsup")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .tint(myVote == 1 ? .green : nil)
                .disabled(myVote != nil)

                Button {
                    onVouch(lead.id, false)
                } label: {
                    Label("Deny", systemImage: "hand.thumbsdown")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .tint(myVote == -1 ? .red : nil)
                .disabled(myVote != nil)
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: Helpers

    private func alertIcon(for type: Alert.AlertType) -> some View {
        let (name, color): (String, Color) = {
            switch type {
            case .hazard: return ("exclamationmark.triangle.fill", .red)
            case .aid:    return ("cross.circle.fill", .green)
            case .other:  return ("info.circle.fill", .blue)
            }
        }()
        return Image(systemName: name).foregroundStyle(color)
    }

    private func severityBadge(_ severity: Int) -> some View {
        let labels = ["", "Low", "Med", "High"]
        let colors: [Color] = [.clear, .yellow, .orange, .red]
        let idx    = min(severity, 3)
        return Text(labels[idx])
            .font(.caption2.bold())
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(colors[idx].opacity(0.2))
            .clipShape(Capsule())
    }

    private func typeName(_ type: Alert.AlertType) -> String {
        switch type {
        case .hazard: return "Hazard"
        case .aid:    return "Aid"
        case .other:  return "Info"
        }
    }

    private func timeAgo(_ timestamp: Int64) -> String {
        let age = Date().timeIntervalSince1970 - Double(timestamp)
        if age < 60    { return "just now" }
        if age < 3600  { return "\(Int(age / 60))m ago" }
        return "\(Int(age / 3600))h ago"
    }
}
