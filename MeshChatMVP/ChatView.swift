import SwiftUI

/// Chat-only UI (mesh status strip + transcript + send).
struct ChatView: View {
    @EnvironmentObject var mesh: BluetoothMeshService
    @State private var draft = ""
    @FocusState private var messageFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                statusStrip
                Divider()
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            ForEach(mesh.chatMessages) { m in
                                bubble(m)
                                    .id(m.id)
                            }
                        }
                        .padding()
                        .contentShape(Rectangle())
                        .onTapGesture { messageFocused = false }
                    }
                    .onChange(of: mesh.chatMessages.count) { _ in
                        if let last = mesh.chatMessages.last {
                            withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                        }
                    }
                }
                Divider()
                HStack(alignment: .bottom, spacing: 10) {
                    TextField("Message", text: $draft, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(1...4)
                        .focused($messageFocused)
                    Button {
                        mesh.sendChat(text: draft)
                        draft = ""
                        messageFocused = false
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.title2)
                    }
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding()
            }
            .navigationTitle(mesh.identity.nickname)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { messageFocused = false }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        messageFocused = false
                    } label: {
                        Label("Hide keyboard", systemImage: "keyboard.chevron.compact.down")
                    }
                    .opacity(messageFocused ? 1 : 0)
                    .disabled(!messageFocused)
                }
            }
        }
    }

    private var statusStrip: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Label(
                    mesh.readyRemoteCount > 0 || mesh.subscribedCentralCount > 0 ? "Linked" : "Finding peers…",
                    systemImage: mesh.readyRemoteCount > 0 || mesh.subscribedCentralCount > 0
                        ? "link.circle.fill" : "antenna.radiowaves.left.and.right"
                )
                .font(.subheadline.weight(.medium))
                .foregroundStyle(
                    mesh.readyRemoteCount > 0 || mesh.subscribedCentralCount > 0 ? Color.green : Color.secondary
                )
                Spacer()
                if mesh.isScanning {
                    Text("Scanning")
                        .font(.caption2)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Color.green.opacity(0.2)))
                } else if mesh.secondsUntilNextScan > 0 {
                    Text("Next scan \(Int(mesh.secondsUntilNextScan))s")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Text("Switch tab bar → Dashboard to leave chat. Tap transcript or Done to hide keyboard.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(Color(.secondarySystemBackground))
    }

    private func bubble(_ m: ChatMessage) -> some View {
        HStack {
            if m.isLocal { Spacer(minLength: 48) }
            VStack(alignment: m.isLocal ? .trailing : .leading, spacing: 4) {
                HStack(spacing: 6) {
                    if !m.isLocal { Text(m.senderName).font(.caption.weight(.semibold)) }
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
}

#Preview {
    ChatView()
        .environmentObject(BluetoothMeshService())
}
