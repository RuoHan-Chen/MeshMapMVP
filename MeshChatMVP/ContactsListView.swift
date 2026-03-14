import SwiftUI

struct ContactsListView: View {
    @EnvironmentObject var mesh: BluetoothMeshService
    @State private var contacts: [SavedContact] = []
    @State private var loadError: String?
    @State private var editingContact: SavedContact?

    var body: some View {
        NavigationStack {
            Group {
                if let err = loadError {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding()
                } else if contacts.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "person.crop.circle.badge.plus")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                        Text("No contacts yet")
                            .font(.headline)
                        Text("Dashboard or group chat → add contact, then open private chat here.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(sortedContacts, id: \.id) { c in
                            let peerID = DatabaseManager.canonicalSenderID(publicKey: c.publicKey)
                            let act = mesh.activity(forPeerID: peerID)
                            NavigationLink {
                                PrivateChatView(peerID: peerID, displayName: c.nickname)
                                    .environmentObject(mesh)
                            } label: {
                                HStack(spacing: 12) {
                                    // Avatar
                                    Circle()
                                        .fill(Color.blue)
                                        .frame(width: 48, height: 48)
                                        .overlay(
                                            Text(String(c.nickname.prefix(2)).uppercased())
                                                .font(.headline)
                                                .foregroundColor(.white)
                                        )
                                    
                                    VStack(alignment: .leading, spacing: 4) {
                                        HStack {
                                            Text(c.nickname)
                                                .font(.headline)
                                            if let u = act?.unread, u > 0 {
                                                Text(u > 99 ? "99+" : "\(u)")
                                                    .font(.caption2.weight(.bold))
                                                    .foregroundStyle(.white)
                                                    .padding(.horizontal, 6)
                                                    .padding(.vertical, 2)
                                                    .background(Capsule().fill(Color.red))
                                            }
                                            Spacer()
                                            if let date = act?.lastDate, date > 0 {
                                                Text(Date(timeIntervalSince1970: date), style: .time)
                                                    .font(.caption2)
                                                    .foregroundColor(.secondary)
                                            }
                                        }
                                        
                                        Text(act?.lastText.isEmpty == false ? act!.lastText : "No messages yet")
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                        
                                        Text("\(KeyManager.fingerprint(c.publicKey, length: 8)) · \(c.relationship)")
                                            .font(.caption2)
                                            .foregroundStyle(.tertiary)
                                            .monospaced()
                                    }
                                }
                                .padding(.vertical, 4)
                            }
                            .swipeActions(edge: .leading, allowsFullSwipe: false) {
                                Button {
                                    editingContact = c
                                } label: {
                                    Label("Edit", systemImage: "pencil")
                                }
                                .tint(.indigo)
                            }
                            .contextMenu {
                                Button {
                                    editingContact = c
                                } label: {
                                    Label("Edit contact", systemImage: "pencil")
                                }
                            }
                        }
                    }
                }
            }
            .sheet(item: $editingContact) { c in
                let pid = DatabaseManager.canonicalSenderID(publicKey: c.publicKey)
                ContactEditorView(
                    publicKey: c.publicKey,
                    existing: c,
                    onSave: {
                        mesh.contactsVersion = UUID()
                        Task { await loadAsync() }
                    },
                    onDelete: {
                        mesh.removeContactActivity(peerID: pid)
                    }
                )
            }
            .navigationTitle("Contacts")
            .task { await loadAsync() }
            .refreshable { await loadAsync() }
            .onChange(of: mesh.contactsVersion) { _ in Task { await loadAsync() } }
            .onChange(of: mesh.contactActivityRevision) { _ in }
        }
    }

    private var sortedContacts: [SavedContact] {
        contacts.sorted { a, b in
            let pa = DatabaseManager.canonicalSenderID(publicKey: a.publicKey)
            let pb = DatabaseManager.canonicalSenderID(publicKey: b.publicKey)
            let actA = mesh.activity(forPeerID: pa)
            let actB = mesh.activity(forPeerID: pb)
            
            // Unread first
            let unreadA = actA?.unread ?? 0
            let unreadB = actB?.unread ?? 0
            if (unreadA > 0) != (unreadB > 0) { return unreadA > 0 }
            
            // Then date
            let da = actA?.lastDate ?? 0
            let db = actB?.lastDate ?? 0
            if da != db { return da > db }
            
            // Then alphabet
            return a.nickname.localizedCaseInsensitiveCompare(b.nickname) == .orderedAscending
        }
    }

    @MainActor
    private func loadAsync() async {
        loadError = nil
        do {
            contacts = try DatabaseManager.shared.listContacts()
        } catch {
            contacts = []
            loadError = "Couldn’t load contacts."
        }
    }
}
