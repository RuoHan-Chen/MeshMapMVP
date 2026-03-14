import SwiftUI
import PhotosUI

/// Chat UI — clean Apple Messages-inspired design.
struct ChatView: View {
    @EnvironmentObject var mesh: BluetoothMeshService
    @State private var draft = ""
    @FocusState private var messageFocused: Bool
    @State private var sendCooldown = false
    @State private var pickedItem: PhotosPickerItem?
    @State private var imageBusy = false

    private var isConnected: Bool {
        mesh.readyRemoteCount > 0 || mesh.subscribedCentralCount > 0
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                statusBanner
                Divider()
                messageList
                Divider()
                inputBar
            }
            .navigationTitle(mesh.identity.nickname)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { messageFocused = false }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { messageFocused = false } label: {
                        Image(systemName: "keyboard.chevron.compact.down")
                            .foregroundStyle(.secondary)
                    }
                    .opacity(messageFocused ? 1 : 0)
                    .disabled(!messageFocused)
                }
            }
            .onChange(of: pickedItem) { newItem in
                guard let newItem else { return }
                imageBusy = true
                Task {
                    defer { Task { @MainActor in imageBusy = false; pickedItem = nil } }
                    guard let data = try? await newItem.loadTransferable(type: Data.self),
                          let ui = UIImage(data: data),
                          let jpeg = try? MeshImageUtils.jpegDataForMesh(from: ui) else { return }
                    await MainActor.run {
                        sendCooldown = true
                        mesh.sendImage(jpegData: jpeg)
                        messageFocused = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { sendCooldown = false }
                    }
                }
            }
        }
    }

    // MARK: - Status Banner

    private var statusBanner: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(isConnected ? Color.green : Color(.systemGray4))
                .frame(width: 7, height: 7)
            Text(isConnected ? "Connected" : "Searching for peers")
                .font(.subheadline)
                .foregroundStyle(isConnected ? .primary : .secondary)
            Spacer()
            if mesh.isScanning {
                HStack(spacing: 5) {
                    ProgressView().scaleEffect(0.65)
                    Text("Scanning")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if mesh.secondsUntilNextScan > 0 {
                Text("Scan in \(Int(mesh.secondsUntilNextScan))s")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Message List

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if mesh.chatMessages.isEmpty {
                    emptyState
                } else {
                    LazyVStack(spacing: 2) {
                        ForEach(mesh.chatMessages) { m in
                            messageBubble(m).id(m.id)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 12)
                }
            }
            .background(Color(.systemGroupedBackground))
            .contentShape(Rectangle())
            .onTapGesture { messageFocused = false }
            .onChange(of: mesh.chatMessages.count) { _ in
                if let last = mesh.chatMessages.last {
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer(minLength: 80)
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(Color(.systemGray4))
            Text("No messages yet")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("Messages sent over the Bluetooth mesh appear here.")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Spacer()
        }
    }

    // MARK: - Message Bubble

    private func messageBubble(_ m: ChatMessage) -> some View {
        HStack(alignment: .bottom) {
            if m.isLocal { Spacer(minLength: 60) }
            VStack(alignment: m.isLocal ? .trailing : .leading, spacing: 3) {
                if !m.isLocal {
                    HStack(spacing: 4) {
                        Text(m.senderName)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        if let dist = m.distanceFromMe {
                            Text("·").font(.caption2).foregroundStyle(.tertiary)
                            Text(distanceString(dist)).font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                    .padding(.horizontal, 4)
                }
                Group {
                    if let b64 = m.imageJPEGBase64, let data = Data(base64Encoded: b64), let ui = UIImage(data: data) {
                        Image(uiImage: ui)
                            .resizable().scaledToFit()
                            .frame(maxWidth: 220, maxHeight: 220)
                            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    } else {
                        Text(m.text)
                            .font(.body)
                            .foregroundStyle(m.isLocal ? .white : .primary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(
                                RoundedRectangle(cornerRadius: 20, style: .continuous)
                                    .fill(m.isLocal ? Color.primary : Color(.systemBackground))
                            )
                    }
                }
                Text(m.date, style: .time)
                    .font(.caption2).foregroundStyle(.tertiary)
                    .padding(.horizontal, 4)
            }
            if !m.isLocal { Spacer(minLength: 60) }
        }
        .padding(.vertical, 2)
    }

    // MARK: - Input Bar

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 10) {
            PhotosPicker(selection: $pickedItem, matching: .images, photoLibrary: .shared()) {
                Image(systemName: "photo")
                    .font(.system(size: 20))
                    .foregroundStyle(imageBusy ? Color(.systemGray4) : .secondary)
                    .frame(width: 34, height: 34)
            }
            .disabled(imageBusy || sendCooldown)

            TextField("Message", text: $draft, axis: .vertical)
                .font(.body)
                .lineLimit(1...4)
                .focused($messageFocused)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(Color(.systemGray6))
                )

            Button {
                let t = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !t.isEmpty, !sendCooldown else { return }
                sendCooldown = true
                mesh.sendChat(text: t)
                draft = ""
                messageFocused = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { sendCooldown = false }
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(
                        draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || sendCooldown
                            ? Color(.systemGray4) : Color.primary
                    )
            }
            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || sendCooldown)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private func distanceString(_ meters: Double) -> String {
        meters < 1000 ? "~\(Int(round(meters)))m" : String(format: "~%.1fkm", meters / 1000)
    }
}

#Preview {
    ChatView().environmentObject(BluetoothMeshService())
}
