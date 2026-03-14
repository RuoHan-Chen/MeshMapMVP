import SwiftUI

/// Add or edit a saved contact for a mesh peer (public key required).
struct ContactEditorView: View {
    @Environment(\.dismiss) private var dismiss
    let publicKey: Data
    var existing: SavedContact?
    var onSave: () -> Void

    @State private var nickname: String = ""
    @State private var relationship: String = SavedContact.associate

    private var fingerprint: String { KeyManager.fingerprint(publicKey, length: 8) }

    var body: some View {
        NavigationStack {
            Form {
                Section("Public key") {
                    Text(fingerprint)
                        .font(.system(.body, design: .monospaced))
                    Text("\(publicKey.count) bytes · tap Save to store")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section("Name") {
                    TextField("Nickname", text: $nickname)
                }
                Section("Relationship") {
                    Picker("Relationship", selection: $relationship) {
                        Text("Associate").tag(SavedContact.associate)
                        Text("Friend").tag(SavedContact.friend)
                    }
                    .pickerStyle(.segmented)
                }
            }
            .navigationTitle(existing == nil ? "Add contact" : "Edit contact")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(nickname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear {
                if let e = existing {
                    nickname = e.nickname
                    relationship = e.relationship
                }
            }
        }
    }

    private func save() {
        let name = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let now = Int64(Date().timeIntervalSince1970)
        do {
            if var e = existing {
                e.nickname = name
                e.relationship = relationship
                e.lastSeen = now
                try DatabaseManager.shared.updateContact(e)
            } else if let dup = try? DatabaseManager.shared.findContactByPublicKey(publicKey) {
                var e = dup
                e.nickname = name
                e.relationship = relationship
                e.lastSeen = now
                try DatabaseManager.shared.updateContact(e)
            } else {
                try DatabaseManager.shared.createContact(SavedContact(
                    id: UUID().uuidString,
                    nickname: name,
                    relationship: relationship,
                    firstSeen: now,
                    lastSeen: now,
                    publicKey: publicKey
                ))
            }
            onSave()
            dismiss()
        } catch {
            // ignore for MVP
        }
    }
}
