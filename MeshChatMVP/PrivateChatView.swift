import SwiftUI

/// 1:1 thread (payload carries `recipientID`; same DB channel for both peers).
struct PrivateChatView: View {
    @EnvironmentObject var mesh: BluetoothMeshService
    let peerID: String
    let displayName: String

    @State private var draft = ""
    @FocusState private var focused: Bool
    @State private var sendCooldown = false

    private var thread: [ChatMessage] {
        mesh.directThreadMessages[peerID] ?? []
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        if thread.isEmpty {
                            HStack {
                                Image(systemName: "info.circle")
                                Text("Direct messages expire after 20 minutes on this device and on the mesh.")
                            }
                            .font(.caption)
                            .foregroundColor(.meshInfo)
                            .padding()
                            .background(Color.meshInfo.opacity(0.1))
                            .cornerRadius(8)
                            .padding()
                        }
                        ForEach(thread) { m in
                            dmBubble(m).id(m.id)
                        }
                    }
                    .padding()
                }
                .onChange(of: thread.count) { _ in
                    if let last = thread.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }
            Divider()
            HStack(alignment: .bottom, spacing: 10) {
                TextField("Message", text: $draft, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...4)
                    .focused($focused)
                Button {
                    let t = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !t.isEmpty, !sendCooldown else { return }
                    sendCooldown = true
                    mesh.sendDirectChat(text: t, toPeerID: peerID, peerDisplayName: displayName)
                    draft = ""
                    focused = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { sendCooldown = false }
                } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.title2)
                }
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || sendCooldown)
            }
            .padding()
        }
        .navigationTitle(displayName)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            mesh.loadDirectThread(peerID: peerID)
            mesh.markContactThreadRead(peerID: peerID)
        }
    }

    private func dmBubble(_ m: ChatMessage) -> some View {
        HStack {
            if m.isLocal { Spacer(minLength: 48) }
            VStack(alignment: m.isLocal ? .trailing : .leading, spacing: 4) {
                HStack(spacing: 6) {
                    if !m.isLocal {
                        Text(mesh.senderDisplayName(senderID: m.senderID, fallbackSenderName: m.senderName))
                            .font(.caption.weight(.semibold))
                        TrustBadge(score: trustScore(for: m.senderID))
                        TTLBadge(expiresAt: m.date.addingTimeInterval(ChatMessage.expirationInterval))
                    }
                    Text(m.date, style: .time).font(.caption2).foregroundStyle(.secondary)
                    if m.isLocal { Text("You").font(.caption.weight(.semibold)) }
                }
                Text(m.text)
                    .font(.body)
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 16)
                            .fill(m.isLocal ? Color.accentColor.opacity(0.2) : Color(.secondarySystemBackground))
                    )
            }
            if !m.isLocal { Spacer(minLength: 48) }
        }
    }
    
    private func trustScore(for senderID: String) -> Double {
        guard let pk = KeyManager.decodePublicKeyBase64(senderID) else { return 0.40 }
        if let contact = try? DatabaseManager.shared.findContactByPublicKey(pk) {
            if contact.relationship == "friend" { return 0.85 }
            if contact.relationship == "associate" { return 0.65 }
        }
        return 0.40
    }
}
