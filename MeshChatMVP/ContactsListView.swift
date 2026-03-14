import SwiftUI

struct ContactsListView: View {
    @State private var contacts: [SavedContact] = []
    @State private var loadError: String?

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
                        Text("Dashboard → tap a peer’s fingerprint after you’re linked.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(contacts) { c in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(c.nickname)
                                .font(.headline)
                            Text(KeyManager.fingerprint(c.publicKey, length: 8))
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                            Text(c.relationship)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            .navigationTitle("Contacts")
            .task { await loadAsync() }
            .refreshable { await loadAsync() }
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
