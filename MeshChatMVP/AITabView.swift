import SwiftUI

/// AI placeholder + mesh “who has internet” (WiFi/cellular).
struct AITabView: View {
    @EnvironmentObject var mesh: BluetoothMeshService

    private var freshPeers: [(id: String, row: PeerInternetRow)] {
        let now = Date().timeIntervalSince1970
        return mesh.peerInternetStatus
            .filter { $0.value.hasInternet && (now - $0.value.lastReceived) < BluetoothMeshService.connectivityPeerStaleSeconds }
            .map { ($0.key, $0.value) }
            .sorted { mesh.senderDisplayName(senderID: $0.id, fallbackSenderName: $0.id) < mesh.senderDisplayName(senderID: $1.id, fallbackSenderName: $1.id) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        Image(systemName: mesh.aiConnectivityGood ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(mesh.aiConnectivityGood ? .green : .red)
                            .font(.title2)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(mesh.aiConnectivityGood ? "Connected path to internet" : "No internet path (mesh)")
                                .font(.headline)
                            Text(mesh.localHasInternet
                                 ? "This device: WiFi or cellular."
                                 : "This device: offline. Need a peer on the mesh with data.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text("Status")
                } footer: {
                    Text("Peers broadcast coarse reachability (not URLs). Red tab badge = no one on mesh reports internet (within ~5 min).")
                        .font(.caption2)
                }

                Section("Peers with internet (mesh)") {
                    if freshPeers.isEmpty {
                        Text("None heard recently — stay in range or wait for scan.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(freshPeers, id: \.id) { item in
                            HStack {
                                Text(mesh.senderDisplayName(senderID: item.id, fallbackSenderName: item.id))
                                Spacer()
                                Text(item.row.interfaceType ?? "online")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                Section("AI (coming soon)") {
                    Text("When at least one node has internet, you could route prompts through the mesh. Not implemented in this build.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("AI")
        }
    }
}
