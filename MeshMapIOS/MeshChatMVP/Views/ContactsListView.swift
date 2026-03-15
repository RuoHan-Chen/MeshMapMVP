import SwiftUI

struct ContactsListView: View {
    @EnvironmentObject var mesh: BluetoothMeshService
    @AppStorage("accessibilityMode") private var accessibilityMode = false
    @AppStorage("accessibilityLargeText") private var accessibilityLargeText = true
    @State private var contacts: [SavedContact] = []
    @State private var loadError: String?
    @State private var editingContact: SavedContact?

    var body: some View {
        NavigationStack {
            Group {
                if let err = loadError {
                    Text(err)
                        .font(accessibilityMode && accessibilityLargeText ? .body : .caption)
                        .foregroundStyle(accessibilityMode ? .primary : .secondary)
                        .padding()
                } else if contacts.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "person.crop.circle.badge.plus")
                            .font(accessibilityMode ? .title : .largeTitle)
                            .foregroundStyle(accessibilityMode ? .primary : .secondary)
                        Text("No contacts yet")
                            .font(accessibilityMode && accessibilityLargeText ? .title2 : .headline)
                        Text("Dashboard or group chat → add contact, then open private chat here.")
                            .font(accessibilityMode && accessibilityLargeText ? .body : .subheadline)
                            .foregroundStyle(accessibilityMode ? .primary : .secondary)
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
                                HStack(alignment: .top, spacing: 10) {
                                    VStack(alignment: .leading, spacing: 4) {
                                        HStack(spacing: 8) {
                                            Text(c.nickname)
                                                .font(accessibilityMode && accessibilityLargeText ? .title3 : .headline)
                                            if let u = act?.unread, u > 0 {
                                                Text(u > 99 ? "99+" : "\(u)")
                                                    .font(.caption2.weight(.bold))
                                                    .foregroundStyle(.white)
                                                    .padding(.horizontal, 6)
                                                    .padding(.vertical, 2)
                                                    .background(Capsule().fill(Color.red))
                                            }
                                        }
                                        Text(act?.lastText.isEmpty == false ? act!.lastText : "No messages yet")
                                            .font(accessibilityMode && accessibilityLargeText ? .body : .subheadline)
                                            .foregroundStyle(accessibilityMode ? .primary : .secondary)
                                            .lineLimit(2)
                                        Text("\(KeyManager.fingerprint(c.publicKey, length: 8)) · \(c.relationship)")
                                            .font(accessibilityMode && accessibilityLargeText ? .caption : .caption2)
                                            .foregroundStyle(accessibilityMode ? .primary : .tertiary)
                                    }
                                    Spacer(minLength: 0)
                                }
                                .padding(.vertical, accessibilityMode ? 8 : 4)
                                .frame(minHeight: accessibilityMode ? 44 : nil)
                            }
                            .accessibilityLabel("Contact \(c.nickname)")
                            .accessibilityHint("Tap to open private chat")
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
            let da = mesh.activity(forPeerID: pa)?.lastDate ?? 0
            let db = mesh.activity(forPeerID: pb)?.lastDate ?? 0
            if da != db { return da > db }
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
