import SwiftUI
import PhotosUI

/// Group chat (quick links, unread, last line).
struct ChatView: View {
    @EnvironmentObject var mesh: BluetoothMeshService
    @State private var draft = ""
    @FocusState private var messageFocused: Bool
    @State private var sendCooldown = false
    @State private var pickedItem: PhotosPickerItem?
    @State private var imageBusy = false
    @State private var showPhotoSendInfo = false
    @State private var imageSendPacketsTotal: Int?
    @State private var contactEditPK: ContactPublicKeyItem?
    @State private var navPath = NavigationPath()
    @State private var savedContacts: [SavedContact] = []
    @State private var editingContact: SavedContact?

    var body: some View {
        NavigationStack(path: $navPath) {
            VStack(spacing: 0) {
                statusStrip
                
                if imageBusy, let total = imageSendPacketsTotal, total > 0 {
                    sendingImageBanner(packetCount: total)
                }
                Divider()
                HStack {
                    Text("Group chat")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal)
                .padding(.top, 6)
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            ForEach(mesh.chatMessages.filter { !$0.isExpired }) { m in
                                bubble(m)
                                    .id(m.id)
                            }
                        }
                        .padding()
                        .contentShape(Rectangle())
                        .onTapGesture { messageFocused = false }
                    }
                    .onChange(of: mesh.chatMessages.count) { _ in
                        let visible = mesh.chatMessages.filter { !$0.isExpired }
                        if let last = visible.last {
                            withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                        }
                    }
                }
                Divider()
                HStack(alignment: .bottom, spacing: 10) {
                    PhotosPicker(selection: $pickedItem, matching: .images, photoLibrary: .shared()) {
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.title2)
                            .foregroundColor(imageBusy ? .secondary : .accentColor)
                    }
                    .disabled(imageBusy || sendCooldown)
                    TextField("Message", text: $draft, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(1...4)
                        .focused($messageFocused)
                    Button {
                        let t = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !t.isEmpty, !sendCooldown else { return }
                        sendCooldown = true
                        mesh.sendChat(text: t)
                        draft = ""
                        messageFocused = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                            sendCooldown = false
                        }
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.title2)
                    }
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || sendCooldown)
                }
                .padding()
            }
            .navigationTitle("")
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $showPhotoSendInfo) {
                photoSendInfoSheet
            }
            .navigationDestination(for: PrivateChatRoute.self) { route in
                PrivateChatView(peerID: route.peerID, displayName: route.displayName)
            }
            .sheet(item: $contactEditPK) { item in
                ContactEditorView(
                    publicKey: item.publicKey,
                    existing: try? DatabaseManager.shared.findContactByPublicKey(item.publicKey)
                ) {
                    mesh.contactsVersion = UUID()
                }
            }
            .task { reloadContacts() }
            .onChange(of: mesh.contactsVersion) { _ in reloadContacts() }
            .onChange(of: mesh.contactActivityRevision) { _ in }
            .sheet(item: $editingContact) { c in
                let pid = DatabaseManager.canonicalSenderID(publicKey: c.publicKey)
                ContactEditorView(
                    publicKey: c.publicKey,
                    existing: c,
                    onSave: {
                        mesh.contactsVersion = UUID()
                        reloadContacts()
                    },
                    onDelete: {
                        mesh.removeContactActivity(peerID: pid)
                    }
                )
            }
            .onChange(of: pickedItem) { newItem in
                guard let newItem else { return }
                imageBusy = true
                imageSendPacketsTotal = nil
                Task {
                    defer {
                        if imageSendPacketsTotal == nil {
                            Task { @MainActor in
                                imageBusy = false
                                pickedItem = nil
                            }
                        }
                    }
                    guard let data = try? await newItem.loadTransferable(type: Data.self),
                          let ui = UIImage(data: data),
                          let jpeg = try? MeshImageUtils.jpegDataForMesh(from: ui)
                    else {
                        await MainActor.run {
                            imageBusy = false
                            pickedItem = nil
                        }
                        return
                    }
                    await MainActor.run {
                        sendCooldown = true
                        mesh.sendImage(jpegData: jpeg) { count in
                            imageSendPacketsTotal = count
                            imageBusy = false
                            pickedItem = nil
                            sendCooldown = false
                        }
                        messageFocused = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            if imageBusy { sendCooldown = false }
                        }
                    }
                }
            }
        }
    }

    private func reloadContacts() {
        savedContacts = (try? DatabaseManager.shared.listContacts()) ?? []
    }

    private var photoSendInfoSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Photos are sent as many small mesh packets over BLE. Keep both apps in range; Dashboard shows link state.")
                    Text("Group chat is broadcast. Contacts above are direct threads (only you two keep those in history).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding()
            }
            .navigationTitle("How photos send")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showPhotoSendInfo = false }
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
            
            // Dropdown menu for connected peers
            Menu {
                if mesh.connectedPeerNames.isEmpty {
                    Text("No direct connections")
                } else {
                    ForEach(mesh.connectedPeerNames, id: \.self) { name in
                        Text(name)
                    }
                }
            } label: {
                HStack {
                    Text(mesh.connectedPeerNames.isEmpty ? "No connections" : "Connected to \(mesh.connectedPeerNames.count) peers")
                    Image(systemName: "chevron.down")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(Color(.secondarySystemBackground))
    }

    private func sendingImageBanner(packetCount: Int) -> some View {
        HStack {
            ProgressView()
            VStack(alignment: .leading, spacing: 2) {
                Text("Sending photo over mesh")
                    .font(.subheadline.weight(.semibold))
                Text("\(packetCount) packets (~\(BluetoothMeshService.imageChunkByteSize) bytes JPEG each, max \(BluetoothMeshService.meshEnvelopeMaxBytes) B per packet)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.accentColor.opacity(0.12))
    }

    private func bubble(_ m: ChatMessage) -> some View {
        let pk = !m.isLocal ? KeyManager.decodePublicKeyBase64(m.senderID) : nil
        let isSavedContact = pk.flatMap { try? DatabaseManager.shared.findContactByPublicKey($0) } != nil
        return HStack {
            if m.isLocal { Spacer(minLength: 48) }
            Group {
                if let pk, !m.isLocal {
                    Button {
                        if isSavedContact {
                            let name = mesh.senderDisplayName(senderID: m.senderID, fallbackSenderName: m.senderName)
                            navPath.append(PrivateChatRoute(peerID: m.senderID, displayName: name))
                        } else {
                            contactEditPK = ContactPublicKeyItem(publicKey: pk)
                        }
                    } label: {
                        bubbleContent(m, trailingIcon: isSavedContact ? "lock.open.fill" : "person.crop.circle.badge.plus")
                    }
                    .buttonStyle(.plain)
                } else {
                    bubbleContent(m, trailingIcon: nil)
                }
            }
            if !m.isLocal { Spacer(minLength: 48) }
        }
    }

    private func bubbleContent(_ m: ChatMessage, trailingIcon: String?) -> some View {
        VStack(alignment: m.isLocal ? .trailing : .leading, spacing: 4) {
            HStack(spacing: 6) {
                if !m.isLocal {
                    Text(mesh.senderDisplayName(senderID: m.senderID, fallbackSenderName: m.senderName))
                        .font(.caption.weight(.semibold))
                    if let trailingIcon {
                        Image(systemName: trailingIcon)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Text(m.date, style: .time).font(.caption2).foregroundStyle(.secondary)
                if m.isLocal { Text("You").font(.caption.weight(.semibold)) }
            }
            if !m.isLocal, let dist = m.distanceFromMe {
                Text(distanceString(dist)).font(.caption2).foregroundStyle(.secondary)
            }
            Group {
                if let b64 = m.imageJPEGBase64, let imgData = Data(base64Encoded: b64), let ui = UIImage(data: imgData) {
                    Image(uiImage: ui)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 220, maxHeight: 220)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                } else {
                    Text(m.text)
                        .font(.body)
                }
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(m.isLocal ? Color.accentColor.opacity(0.2) : Color(.secondarySystemBackground))
            )
        }
    }

    private func distanceString(_ meters: Double) -> String {
        if meters < 1000 { return "~\(Int(round(meters))) m away" }
        return String(format: "~%.1f km away", meters / 1000)
    }
}

private struct ContactPublicKeyItem: Identifiable {
    let id = UUID()
    let publicKey: Data
}

private struct PrivateChatRoute: Hashable {
    let peerID: String
    let displayName: String
}

#Preview {
    ChatView()
        .environmentObject(BluetoothMeshService())
}
