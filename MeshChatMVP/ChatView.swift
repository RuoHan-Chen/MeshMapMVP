import SwiftUI
import PhotosUI

/// Group chat + contacts strip (quick links, unread, last line).
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

    private var contactsSorted: [SavedContact] {
        savedContacts.sorted { a, b in
            let pa = DatabaseManager.canonicalSenderID(publicKey: a.publicKey)
            let pb = DatabaseManager.canonicalSenderID(publicKey: b.publicKey)
            let da = mesh.activity(forPeerID: pa)?.lastDate ?? 0
            let db = mesh.activity(forPeerID: pb)?.lastDate ?? 0
            if da != db { return da > db }
            return a.nickname.localizedCaseInsensitiveCompare(b.nickname) == .orderedAscending
        }
    }

    var body: some View {
        NavigationStack(path: $navPath) {
            VStack(spacing: 0) {
                contactsQuickSection
                Divider()
                if imageBusy, let total = imageSendPacketsTotal, total > 0 {
                    sendingImageBanner(packetCount: total)
                }
                Divider()
                HStack {
                    Text("Group channel · broadcast · \(mesh.chatMessages.filter { !$0.isExpired }.count) active")
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
            .navigationTitle(navTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { messageFocused = false }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showPhotoSendInfo = true
                    } label: {
                        Label("How photos send", systemImage: "info.circle")
                    }
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

    private var navTitle: String {
        let u = mesh.contactUnreadTotal
        if u > 0 { return "Chat · \(u) unread" }
        return mesh.identity.nickname
    }

    private func reloadContacts() {
        savedContacts = (try? DatabaseManager.shared.listContacts()) ?? []
    }

    private var contactsQuickSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Contacts", systemImage: "person.2.fill")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if mesh.contactUnreadTotal > 0 {
                    Text("\(mesh.contactUnreadTotal) unread")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Color.red.opacity(0.85)))
                }
            }
            .padding(.horizontal)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    if savedContacts.isEmpty {
                        Text("No contacts yet")
                            .font(.caption)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Capsule().fill(Color.secondary.opacity(0.1)))
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(contactsSorted, id: \.id) { row in
                            let peerID = DatabaseManager.canonicalSenderID(publicKey: row.publicKey)
                            let act = mesh.activity(forPeerID: peerID)
                            let isLinked = mesh.discoveredPeers.contains(where: { $0.publicKey == row.publicKey && $0.linkState == "connected" })
                            
                            Button {
                                navPath.append(PrivateChatRoute(peerID: peerID, displayName: row.nickname))
                            } label: {
                                VStack(alignment: .center, spacing: 4) {
                                    ZStack(alignment: .bottomTrailing) {
                                        Circle()
                                            .fill(Color.blue)
                                            .frame(width: 48, height: 48)
                                            .overlay(
                                                Text(String(row.nickname.prefix(2)).uppercased())
                                                    .font(.headline)
                                                    .foregroundColor(.white)
                                            )
                                        
                                        if isLinked {
                                            Circle()
                                                .fill(Color.green)
                                                .frame(width: 12, height: 12)
                                                .overlay(Circle().stroke(Color(UIColor.systemBackground), lineWidth: 2))
                                        }
                                        
                                        if let u = act?.unread, u > 0 {
                                            ZStack {
                                                Circle()
                                                    .fill(Color.red)
                                                    .frame(width: 18, height: 18)
                                                Text(u > 9 ? "9+" : "\(u)")
                                                    .font(.system(size: 10, weight: .bold))
                                                    .foregroundColor(.white)
                                            }
                                            .offset(x: 4, y: -36)
                                        }
                                    }
                                    
                                    Text(row.nickname)
                                        .font(.caption)
                                        .lineLimit(1)
                                        .frame(width: 60)
                                }
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button {
                                    editingContact = row
                                } label: {
                                    Label("Edit contact", systemImage: "pencil")
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal)
            }
        }
        .padding(.vertical, 10)
        .background(Color(.systemBackground))
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

    private func trustScore(for senderID: String) -> Double {
        // Heuristic:
        // Saved friend -> 0.85
        // Saved associate -> 0.65
        // Unknown -> 0.40
        // (Vouch logic omitted for MVP UI simplicity here, just base relationship)
        
        // We need to find the contact by senderID (which is deviceID).
        // DatabaseManager stores contacts by publicKey.
        // We need to map senderID to publicKey or check if we can find by senderID.
        // DatabaseManager has `savedNickname(forSenderID:)` which implies lookup.
        // But `findContactByPublicKey` needs PK.
        // `BluetoothMeshService` has `isSavedContactPeer(peerID)`.
        
        // Let's try to find the contact.
        // We can iterate savedContacts since we have them loaded.
        if let contact = savedContacts.first(where: { DatabaseManager.canonicalSenderID(publicKey: $0.publicKey) == senderID }) {
            if contact.relationship == "friend" { return 0.85 }
            if contact.relationship == "associate" { return 0.65 }
            return 0.50 // Default saved
        }
        return 0.40
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
                    // Trust badge
                    TrustBadge(score: trustScore(for: m.senderID))
                    // TTL badge
                    TTLBadge(expiresAt: m.date.addingTimeInterval(ChatMessage.expirationInterval))
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
                        .foregroundColor(m.isLocal ? .white : .primary)
                }
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(m.isLocal ? Color(red: 0.1, green: 0.25, blue: 0.5) : Color.white)
                    .shadow(color: Color.black.opacity(0.05), radius: 2, x: 0, y: 1)
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
