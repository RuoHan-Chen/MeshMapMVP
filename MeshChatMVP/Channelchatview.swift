
import SwiftUI
import PhotosUI
 
// MARK: - Channel list (inbox)
 
struct ChannelListView: View {
    @EnvironmentObject var mesh: BluetoothMeshService
    @ObservedObject var store: LocalStore = .shared
    @State private var showNewGroup = false
    @State private var showNewDirect = false
    @State private var searchText = ""
 
    private var sortedChannels: [Channel] {
        store.channels
            .filter { searchText.isEmpty || $0.name.localizedCaseInsensitiveContains(searchText) }
            .sorted { $0.lastMessageAt > $1.lastMessageAt }
    }
 
    var body: some View {
        NavigationStack {
            ZStack {
                Color(hex: "#060809").ignoresSafeArea()
 
                VStack(spacing: 0) {
                    // Header
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("MESSAGES")
                                .font(.custom("IBMPlexMono-SemiBold", size: 13))
                                .foregroundColor(Color(hex: "#d4eaf5"))
                                .kerning(1)
                            meshStatusLine
                        }
                        Spacer()
                        Menu {
                            Button { showNewDirect = true } label: {
                                Label("New Direct Message", systemImage: "person")
                            }
                            Button { showNewGroup = true } label: {
                                Label("New Group", systemImage: "person.3")
                            }
                        } label: {
                            Image(systemName: "square.and.pencil")
                                .font(.system(size: 18))
                                .foregroundColor(Color(hex: "#00e5a0"))
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(Color(hex: "#060809"))
                    .overlay(alignment: .bottom) { Divider().overlay(Color(hex: "#1e2d3d")) }
 
                    // Search
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").font(.system(size: 13))
                            .foregroundColor(Color(hex: "#4a6580"))
                        TextField("Search channels…", text: $searchText)
                            .font(.custom("IBMPlexMono-Regular", size: 12))
                            .foregroundColor(Color(hex: "#d4eaf5"))
                            .autocorrectionDisabled()
                    }
                    .padding(10)
                    .background(Color(hex: "#111820"))
                    .cornerRadius(8)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(hex: "#1e2d3d"), lineWidth: 0.5))
                    .padding(.horizontal, 16).padding(.vertical, 10)
 
                    // Channel rows
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(sortedChannels) { ch in
                                NavigationLink(destination: ChannelChatView(channel: ch)) {
                                    ChannelRow(channel: ch)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
            .navigationBarHidden(true)
        }
        .sheet(isPresented: $showNewGroup) { NewGroupSheet() }
        .sheet(isPresented: $showNewDirect) { NewDirectSheet() }
        .onAppear { ensureBroadcastChannel() }
    }
 
    private var meshStatusLine: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(mesh.readyRemoteCount > 0 || mesh.subscribedCentralCount > 0
                      ? Color(hex: "#00e5a0") : Color(hex: "#4a6580"))
                .frame(width: 6, height: 6)
            let count = mesh.readyRemoteCount + mesh.subscribedCentralCount
            Text(count > 0 ? "\(count) node\(count == 1 ? "" : "s") connected" : "Scanning…")
                .font(.custom("IBMPlexMono-Regular", size: 10))
                .foregroundColor(Color(hex: "#4a6580"))
        }
    }
 
    private func ensureBroadcastChannel() {
        if !store.channels.contains(where: { $0.id == "broadcast" }) {
            store.saveChannel(.broadcast)
        }
    }
}
 
// MARK: - Channel row
 
private struct ChannelRow: View {
    let channel: Channel
    private var lastMsg: StoredMessage? {
        LocalStore.shared.messages(for: channel.id).last
    }
 
    var body: some View {
        HStack(spacing: 12) {
            channelIcon
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(channel.name)
                        .font(.custom("IBMPlexSans-Medium", size: 14))
                        .foregroundColor(Color(hex: "#d4eaf5"))
                    Spacer()
                    if let msg = lastMsg {
                        Text(msg.timestamp.chatRelative)
                            .font(.custom("IBMPlexMono-Regular", size: 10))
                            .foregroundColor(Color(hex: "#4a6580"))
                    }
                }
                HStack {
                    if let msg = lastMsg {
                        Text((msg.isFromMe ? "You: " : "\(msg.senderName): ") + msg.text)
                            .font(.custom("IBMPlexSans-Regular", size: 12))
                            .foregroundColor(Color(hex: "#4a6580"))
                            .lineLimit(1)
                    } else {
                        Text(channelSubtitle)
                            .font(.custom("IBMPlexMono-Regular", size: 10))
                            .foregroundColor(Color(hex: "#2a3f52"))
                    }
                    Spacer()
                    if channel.unreadCount > 0 {
                        Text("\(channel.unreadCount)")
                            .font(.custom("IBMPlexMono-Regular", size: 9))
                            .foregroundColor(Color(hex: "#060809"))
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(Color(hex: "#00e5a0"))
                            .clipShape(Capsule())
                    }
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 11)
        .background(Color(hex: "#060809"))
        .overlay(alignment: .bottom) {
            Divider().overlay(Color(hex: "#111820")).padding(.leading, 72)
        }
    }
 
    private var channelIcon: some View {
        ZStack {
            Circle()
                .fill(Color(hex: iconBG))
                .frame(width: 44, height: 44)
                .overlay(Circle().stroke(Color(hex: "#1e2d3d"), lineWidth: 0.5))
            Image(systemName: channelSFSymbol)
                .font(.system(size: 18))
                .foregroundColor(Color(hex: iconFG))
        }
    }
 
    private var channelSFSymbol: String {
        switch channel.type {
        case .broadcast: return "antenna.radiowaves.left.and.right"
        case .group:     return "person.3.fill"
        case .direct:    return "person.fill"
        }
    }
    private var iconBG: String {
        switch channel.type {
        case .broadcast: return "0c1a14"
        case .group:     return "12101a"
        case .direct:    return "0e1318"
        }
    }
    private var iconFG: String {
        switch channel.type {
        case .broadcast: return "00e5a0"
        case .group:     return "a78bfa"
        case .direct:    return "64a0ff"
        }
    }
    private var channelSubtitle: String {
        switch channel.type {
        case .broadcast: return "Broadcast to all mesh nodes"
        case .group:     return "\(channel.memberIDs.count) members"
        case .direct:    return "Direct message"
        }
    }
}
 
// MARK: - Channel chat view
 
struct ChannelChatView: View {
    let channel: Channel
    @EnvironmentObject var mesh: BluetoothMeshService
    @ObservedObject private var store: LocalStore = .shared
 
    @State private var draft = ""
    @State private var replyTo: StoredMessage? = nil
    @State private var selectedPhoto: PhotosPickerItem? = nil
    @State private var pendingImage: UIImage? = nil
    @FocusState private var focused: Bool
 
    private var messages: [StoredMessage] {
        store.messages(for: channel.id)
    }
 
    var body: some View {
        ZStack {
            Color(hex: "#060809").ignoresSafeArea()
            VStack(spacing: 0) {
                chatHeader
                Divider().overlay(Color(hex: "#1e2d3d"))
                messageList
                Divider().overlay(Color(hex: "#1e2d3d"))
                inputBar
            }
        }
        .navigationBarHidden(true)
        .onAppear { store.markRead(channelID: channel.id) }
        .onDisappear { store.markRead(channelID: channel.id) }
    }
 
    // MARK: Header
 
    private var chatHeader: some View {
        HStack(spacing: 10) {
            BackButton()
            VStack(alignment: .leading, spacing: 2) {
                Text(channel.name)
                    .font(.custom("IBMPlexSans-Medium", size: 15))
                    .foregroundColor(Color(hex: "#d4eaf5"))
                Text(headerSub)
                    .font(.custom("IBMPlexMono-Regular", size: 9))
                    .foregroundColor(Color(hex: "#4a6580"))
            }
            Spacer()
            Image(systemName: "lock.fill")
                .font(.system(size: 12))
                .foregroundColor(Color(hex: "#2a3f52"))
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(Color(hex: "#060809"))
    }
 
    private var headerSub: String {
        switch channel.type {
        case .broadcast: return "All \(mesh.readyRemoteCount + mesh.subscribedCentralCount + 1) nodes · end-to-end encrypted"
        case .group:     return "\(channel.memberIDs.count) members · encrypted"
        case .direct:    return "Direct · encrypted"
        }
    }
 
    // MARK: Message list
 
    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(messages) { msg in
                        MessageBubbleView(
                            message: msg,
                            replyMessage: msg.replyToID.flatMap { rid in messages.first { $0.id == rid } },
                            onReply: { replyTo = msg },
                            onReact: { emoji in store.addReaction(emoji: emoji, to: msg.id, by: mesh.identity.deviceID) }
                        )
                        .id(msg.id)
                    }
                }
                .padding(.vertical, 10)
            }
            .onChange(of: messages.count) { _ in
                if let last = messages.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            .onAppear {
                if let last = messages.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
            .contentShape(Rectangle())
            .onTapGesture { focused = false }
        }
    }
 
    // MARK: Input bar
 
    private var inputBar: some View {
        VStack(spacing: 0) {
            // Reply preview
            if let reply = replyTo {
                HStack(spacing: 8) {
                    Rectangle().fill(Color(hex: "#00e5a0")).frame(width: 2)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Replying to \(reply.senderName)")
                            .font(.custom("IBMPlexMono-Regular", size: 10))
                            .foregroundColor(Color(hex: "#00e5a0"))
                        Text(reply.text).lineLimit(1)
                            .font(.custom("IBMPlexSans-Regular", size: 12))
                            .foregroundColor(Color(hex: "#4a6580"))
                    }
                    Spacer()
                    Button { replyTo = nil } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 12))
                            .foregroundColor(Color(hex: "#4a6580"))
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 6)
                .background(Color(hex: "#0c1014"))
            }
 
            // Image preview
            if let img = pendingImage {
                HStack(spacing: 8) {
                    Image(uiImage: img)
                        .resizable().scaledToFill()
                        .frame(width: 52, height: 52)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    Text("Photo ready to send")
                        .font(.custom("IBMPlexMono-Regular", size: 11))
                        .foregroundColor(Color(hex: "#4a6580"))
                    Spacer()
                    Button { pendingImage = nil } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(Color(hex: "#e53e3e"))
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(Color(hex: "#0c1014"))
            }
 
            HStack(alignment: .bottom, spacing: 8) {
                // Photo picker
                PhotosPicker(selection: $selectedPhoto, matching: .images) {
                    Image(systemName: "photo")
                        .font(.system(size: 20))
                        .foregroundColor(Color(hex: "#4a6580"))
                        .frame(width: 36, height: 36)
                }
                .onChange(of: selectedPhoto) { item in
                    Task {
                        if let data = try? await item?.loadTransferable(type: Data.self),
                           let img = UIImage(data: data) {
                            await MainActor.run { pendingImage = img }
                        }
                    }
                }
 
                // Text field
                ZStack(alignment: .leading) {
                    if draft.isEmpty && pendingImage == nil {
                        Text(channel.type == .broadcast ? "Message @everyone…" : "Message \(channel.name)…")
                            .font(.custom("IBMPlexSans-Regular", size: 14))
                            .foregroundColor(Color(hex: "#2a3f52"))
                            .padding(.leading, 14)
                    }
                    TextField("", text: $draft, axis: .vertical)
                        .font(.custom("IBMPlexSans-Regular", size: 14))
                        .foregroundColor(Color(hex: "#d4eaf5"))
                        .lineLimit(1...5)
                        .focused($focused)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                }
                .background(Color(hex: "#111820"))
                .cornerRadius(20)
                .overlay(Capsule().stroke(Color(hex: "#1e2d3d"), lineWidth: 0.5))
 
                // Send
                Button { sendMessage() } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(Color(hex: "#060809"))
                        .frame(width: 34, height: 34)
                        .background(canSend ? Color(hex: "#00e5a0") : Color(hex: "#2a3f52"))
                        .clipShape(Circle())
                }
                .disabled(!canSend)
                .animation(.easeInOut(duration: 0.15), value: canSend)
            }
            .padding(.horizontal, 12).padding(.vertical, 10).padding(.bottom, 4)
        }
        .background(Color(hex: "#060809"))
    }
 
    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || pendingImage != nil
    }
 
    private func sendMessage() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSend else { return }
        var imageData: Data? = nil
        if let img = pendingImage {
            imageData = img.jpegData(compressionQuality: 0.5)
        }
        let myID = mesh.identity.deviceID
        let msg = StoredMessage(
            id: UUID(), channelID: channel.id, envelopeID: UUID(),
            senderID: myID, senderName: mesh.identity.nickname,
            text: text.isEmpty ? "📷 Photo" : text,
            imageData: imageData,
            timestamp: Date(), isFromMe: true,
            distanceMeters: nil
        )
        // Persist locally
        store.saveMessage(msg)
        store.incrementUnread(channelID: channel.id)
        // Send via mesh
        if !text.isEmpty {
            mesh.sendChat(text: text)
        }
        draft = ""
        replyTo = nil
        pendingImage = nil
        selectedPhoto = nil
    }
}
 
// MARK: - Message bubble
 
struct MessageBubbleView: View {
    let message: StoredMessage
    let replyMessage: StoredMessage?
    let onReply: () -> Void
    let onReact: (String) -> Void
 
    @State private var showReactions = false
    @State private var longPressed = false
 
    private let emojis = ["👍","❤️","⚠️","✅","🙏","🔥"]
 
    var body: some View {
        VStack(alignment: message.isFromMe ? .trailing : .leading, spacing: 2) {
            HStack(alignment: .bottom, spacing: 8) {
                if message.isFromMe { Spacer(minLength: 64) }
 
                VStack(alignment: message.isFromMe ? .trailing : .leading, spacing: 4) {
                    // Sender name + trust
                    if !message.isFromMe {
                        HStack(spacing: 6) {
                            Text(message.senderName)
                                .font(.custom("IBMPlexMono-Medium", size: 10))
                                .foregroundColor(Color(hex: "#4a6580"))
                            if let dist = message.distanceMeters {
                                Text("~\(distStr(dist))")
                                    .font(.custom("IBMPlexMono-Regular", size: 9))
                                    .foregroundColor(Color(hex: "#2a3f52"))
                            }
                            let trust = LocalStore.shared.trustScore(for: message.senderID)
                            TrustPill(score: trust)
                        }
                    }
 
                    // Reply quote
                    if let reply = replyMessage {
                        HStack(spacing: 6) {
                            Rectangle().fill(Color(hex: "#00e5a0").opacity(0.6)).frame(width: 2)
                            Text(reply.text).lineLimit(1)
                                .font(.custom("IBMPlexSans-Regular", size: 11))
                                .foregroundColor(Color(hex: "#4a6580"))
                        }
                        .padding(6)
                        .background(Color(hex: "#0c1014"))
                        .cornerRadius(6)
                    }
 
                    // Image
                    if let data = message.imageData, let img = UIImage(data: data) {
                        Image(uiImage: img)
                            .resizable().scaledToFit()
                            .frame(maxWidth: 220, maxHeight: 180)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
 
                    // Text bubble
                    if !message.text.isEmpty && message.text != "📷 Photo" {
                        Text(message.text)
                            .font(.custom("IBMPlexSans-Regular", size: 15))
                            .foregroundColor(message.isFromMe ? Color(hex: "#060809") : Color(hex: "#d4eaf5"))
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .background(message.isFromMe ? Color(hex: "#00e5a0") : Color(hex: "#182030"))
                            .cornerRadius(16, corners: message.isFromMe
                                ? [.topLeft, .topRight, .bottomLeft]
                                : [.topLeft, .topRight, .bottomRight])
                    }
 
                    // Reactions
                    if !message.reactions.isEmpty {
                        reactionBar
                    }
 
                    // Meta
                    HStack(spacing: 5) {
                        Text(message.timestamp.chatTimeString)
                            .font(.custom("IBMPlexMono-Regular", size: 9))
                            .foregroundColor(Color(hex: "#2a3f52"))
                        if message.isFromMe {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 9))
                                .foregroundColor(Color(hex: "#00b87a"))
                        }
                    }
                }
 
                if !message.isFromMe { Spacer(minLength: 64) }
            }
 
            // Quick reaction picker (shown on long press)
            if showReactions {
                HStack(spacing: 8) {
                    if !message.isFromMe { Spacer() }
                    ForEach(emojis, id: \.self) { e in
                        Button {
                            onReact(e)
                            withAnimation { showReactions = false }
                        } label: {
                            Text(e).font(.system(size: 22))
                        }
                    }
                    Button { onReply(); showReactions = false } label: {
                        Image(systemName: "arrowshape.turn.up.left.fill")
                            .foregroundColor(Color(hex: "#4a6580"))
                    }
                    if message.isFromMe { Spacer() }
                }
                .padding(.vertical, 6).padding(.horizontal, 10)
                .background(Color(hex: "#111820"))
                .cornerRadius(20)
                .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color(hex: "#1e2d3d"), lineWidth: 0.5))
                .transition(.scale(scale: 0.8).combined(with: .opacity))
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 2)
        .contentShape(Rectangle())
        .onLongPressGesture(minimumDuration: 0.4) {
            withAnimation(.spring(response: 0.3)) { showReactions.toggle() }
        }
    }
 
    private var reactionBar: some View {
        HStack(spacing: 4) {
            ForEach(Array(message.reactions.keys.sorted()), id: \.self) { emoji in
                let senders = message.reactions[emoji] ?? []
                HStack(spacing: 3) {
                    Text(emoji).font(.system(size: 13))
                    Text("\(senders.count)")
                        .font(.custom("IBMPlexMono-Regular", size: 10))
                        .foregroundColor(Color(hex: "#4a6580"))
                }
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(Color(hex: "#111820"))
                .cornerRadius(10)
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(hex: "#1e2d3d"), lineWidth: 0.5))
            }
        }
    }
 
    private func distStr(_ m: Double) -> String {
        m < 1000 ? "\(Int(m))m" : String(format: "%.1fkm", m / 1000)
    }
}
 
// MARK: - Trust pill
 
struct TrustPill: View {
    let score: Double
    private var color: Color {
        score >= 0.8 ? Color(hex: "#00e5a0")
        : score >= 0.4 ? Color(hex: "#f5a623")
        : Color(hex: "#e53e3e")
    }
    var body: some View {
        Text(String(format: "%.0f%%", score * 100))
            .font(.custom("IBMPlexMono-Regular", size: 8))
            .foregroundColor(color)
            .padding(.horizontal, 4).padding(.vertical, 1)
            .background(color.opacity(0.1))
            .cornerRadius(3)
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(color.opacity(0.2), lineWidth: 0.5))
    }
}
 
// MARK: - New group/direct sheets
 
struct NewGroupSheet: View {
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var mesh: BluetoothMeshService
    @State private var name = ""
 
    var body: some View {
        ZStack {
            Color(hex: "#060809").ignoresSafeArea()
            VStack(spacing: 24) {
                Text("NEW GROUP").font(.custom("IBMPlexMono-SemiBold", size: 13))
                    .foregroundColor(Color(hex: "#d4eaf5")).kerning(2).padding(.top, 24)
                TextField("Group name", text: $name)
                    .font(.custom("IBMPlexMono-Regular", size: 15))
                    .foregroundColor(Color(hex: "#d4eaf5"))
                    .padding(12).background(Color(hex: "#111820"))
                    .cornerRadius(8).padding(.horizontal, 32)
                Button("Create") {
                    let ch = Channel.group(name: name, memberIDs: [mesh.identity.deviceID])
                    LocalStore.shared.saveChannel(ch)
                    dismiss()
                }
                .disabled(name.isEmpty)
                .font(.custom("IBMPlexMono-Medium", size: 13))
                .foregroundColor(Color(hex: "#060809"))
                .padding(.horizontal, 32).padding(.vertical, 12)
                .background(name.isEmpty ? Color(hex: "#2a3f52") : Color(hex: "#00e5a0"))
                .cornerRadius(8).padding(.horizontal, 32)
                Spacer()
            }
        }
    }
}
 
struct NewDirectSheet: View {
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var mesh: BluetoothMeshService
    @ObservedObject private var store = LocalStore.shared
    @State private var selected: Contact?
 
    var body: some View {
        ZStack {
            Color(hex: "#060809").ignoresSafeArea()
            VStack(spacing: 0) {
                Text("DIRECT MESSAGE").font(.custom("IBMPlexMono-SemiBold", size: 13))
                    .foregroundColor(Color(hex: "#d4eaf5")).kerning(2).padding(20)
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(store.contacts) { contact in
                            Button {
                                let ch = Channel.direct(myID: mesh.identity.deviceID,
                                                       peerID: contact.id,
                                                       peerName: contact.displayName)
                                store.saveChannel(ch)
                                dismiss()
                            } label: {
                                HStack(spacing: 12) {
                                    Circle().fill(Color(hex: "#111820"))
                                        .frame(width: 36, height: 36)
                                        .overlay(Text(String(contact.displayName.prefix(2)).uppercased())
                                            .font(.custom("IBMPlexMono-Regular", size: 12))
                                            .foregroundColor(Color(hex: "#a8c4d8")))
                                    Text(contact.displayName)
                                        .font(.custom("IBMPlexSans-Medium", size: 14))
                                        .foregroundColor(Color(hex: "#d4eaf5"))
                                    Spacer()
                                    TrustPill(score: contact.trustScore(myContacts: store.contacts))
                                }
                                .padding(.horizontal, 16).padding(.vertical, 10)
                            }
                            .buttonStyle(.plain)
                            Divider().overlay(Color(hex: "#111820")).padding(.leading, 64)
                        }
                    }
                }
            }
        }
    }
}
 
// MARK: - Helpers
 
struct BackButton: View {
    @Environment(\.dismiss) var dismiss
    var body: some View {
        Button { dismiss() } label: {
            Image(systemName: "chevron.left")
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(Color(hex: "#00e5a0"))
                .frame(width: 32, height: 32)
        }
    }
}
 
extension View {
    func cornerRadius(_ radius: CGFloat, corners: UIRectCorner) -> some View {
        clipShape(RoundedCorner(radius: radius, corners: corners))
    }
}
struct RoundedCorner: Shape {
    var radius: CGFloat = 0; var corners: UIRectCorner = .allCorners
    func path(in rect: CGRect) -> Path {
        Path(UIBezierPath(roundedRect: rect, byRoundingCorners: corners,
                          cornerRadii: CGSize(width: radius, height: radius)).cgPath)
    }
}
extension Date {
    var chatTimeString: String {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f.string(from: self)
    }
    var chatRelative: String {
        let age = -timeIntervalSinceNow
        if age < 60 { return "now" }
        if age < 3600 { return "\(Int(age/60))m" }
        if age < 86400 { return "\(Int(age/3600))h" }
        return "\(Int(age/86400))d"
    }
}
 