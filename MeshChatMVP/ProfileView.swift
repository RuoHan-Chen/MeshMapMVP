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
                                    .font(.system(.caption, design: .monospaced))
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
                .font(.system(.body, design: .monospaced))
                .foregroundColor(.secondary)
        }
        .padding()
    }
}
