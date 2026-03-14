import SwiftUI

/// Add or edit a saved contact for a mesh peer (public key required).
struct ContactEditorView: View {
    @Environment(\.dismiss) private var dismiss
    let publicKey: Data
    var existing: SavedContact?
    var onSave: () -> Void
    /// Called after a successful delete (e.g. bump contacts list).
    var onDelete: (() -> Void)?

    @State private var nickname: String = ""
    @State private var relationship: String = SavedContact.associate
    @State private var confirmDelete = false

    private var fingerprint: String { KeyManager.fingerprint(publicKey, length: 8) }
    init(
        publicKey: Data,
        existing: SavedContact?,
        onSave: @escaping () -> Void,
        onDelete: (() -> Void)? = nil
    ) {
        self.publicKey = publicKey
        self.existing = existing
        self.onSave = onSave
        self.onDelete = onDelete
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Public key") {
                    Text(fingerprint)
                        .font(.system(.body, design: .monospaced))
                    Text(String(format: String(localized: "%lld bytes · cannot change"), Int64(publicKey.count)))
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
                if existing != nil {
                    Section {
                        Button(role: .destructive) {
                            confirmDelete = true
                        } label: {
                            Label("Delete contact", systemImage: "trash")
                        }
                    } footer: {
                        Text("Removes them from your contacts. Group and DM history stay on device until you clear app data.")
                            .font(.caption)
                    }
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
            .confirmationDialog("Delete this contact?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) { deleteContact() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("You can add them again later from Dashboard or chat.")
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

    private func deleteContact() {
        guard let e = existing ?? (try? DatabaseManager.shared.findContactByPublicKey(publicKey)) else {
            dismiss()
            return
        }
        do {
            try DatabaseManager.shared.deleteContact(e)
            onDelete?()
            onSave()
            dismiss()
        } catch {
            dismiss()
        }
    }
}
