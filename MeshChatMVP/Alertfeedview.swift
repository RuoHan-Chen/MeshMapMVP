import SwiftUI
import PhotosUI
 
// MARK: - Alert feed
 
struct AlertFeedView: View {
    @ObservedObject private var store = LocalStore.shared
    @EnvironmentObject var mesh: BluetoothMeshService
    @State private var showNew = false
    @State private var selectedAlert: MeshAlertItem?
    @State private var filterSeverity: AlertSeverity? = nil
 
    private var displayed: [MeshAlertItem] {
        store.activeAlerts
            .filter { filterSeverity == nil || $0.severity == filterSeverity }
    }
 
    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottomTrailing) {
                Color(hex: "#060809").ignoresSafeArea()
 
                VStack(spacing: 0) {
                    // Header
                    HStack {
                        Text("ALERTS")
                            .font(.custom("IBMPlexMono-SemiBold", size: 13))
                            .foregroundColor(Color(hex: "#d4eaf5"))
                            .kerning(1)
                        Spacer()
                        Text("\(displayed.count) active")
                            .font(.custom("IBMPlexMono-Regular", size: 10))
                            .foregroundColor(Color(hex: "#00e5a0"))
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(Color(hex: "#00e5a0").opacity(0.08))
                            .clipShape(Capsule())
                            .overlay(Capsule().stroke(Color(hex: "#00e5a0").opacity(0.2), lineWidth: 0.5))
                    }
                    .padding(.horizontal, 16).padding(.vertical, 12)
                    .background(Color(hex: "#060809"))
                    .overlay(alignment: .bottom) { Divider().overlay(Color(hex: "#1e2d3d")) }
 
                    // Severity filter chips
                    filterBar
 
                    // Alert list
                    if displayed.isEmpty {
                        Spacer()
                        VStack(spacing: 12) {
                            Image(systemName: "checkmark.shield")
                                .font(.system(size: 40))
                                .foregroundColor(Color(hex: "#2a3f52"))
                            Text("No active alerts")
                                .font(.custom("IBMPlexMono-Regular", size: 13))
                                .foregroundColor(Color(hex: "#2a3f52"))
                        }
                        Spacer()
                    } else {
                        ScrollView {
                            LazyVStack(spacing: 0) {
                                ForEach(displayed) { alert in
                                    NavigationLink(destination: AlertThreadView(alert: alert)) {
                                        AlertCardRow(alert: alert)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.bottom, 80)
                        }
                    }
                }
 
                // FAB
                Button { showNew = true } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(Color(hex: "#060809"))
                        .frame(width: 52, height: 52)
                        .background(Color(hex: "#00e5a0"))
                        .clipShape(Circle())
                        .shadow(color: Color(hex: "#00e5a0").opacity(0.3), radius: 12)
                }
                .padding(.trailing, 20).padding(.bottom, 24)
            }
            .navigationBarHidden(true)
        }
        .sheet(isPresented: $showNew) { NewAlertSheet() }
    }
 
    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                filterChip(nil, label: "ALL")
                ForEach(AlertSeverity.allCases, id: \.self) { s in
                    filterChip(s, label: s.label.uppercased())
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
        }
        .background(Color(hex: "#060809"))
        .overlay(alignment: .bottom) { Divider().overlay(Color(hex: "#1e2d3d")) }
    }
 
    private func filterChip(_ sev: AlertSeverity?, label: String) -> some View {
        let active = filterSeverity == sev
        let col = sev?.color ?? Color(hex: "#00e5a0")
        return Button { withAnimation { filterSeverity = sev } } label: {
            Text(label)
                .font(.custom("IBMPlexMono-Regular", size: 9))
                .kerning(0.8)
                .foregroundColor(active ? Color(hex: "#060809") : Color(hex: "#4a6580"))
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(active ? col : Color(hex: "#111820"))
                .clipShape(Capsule())
                .overlay(Capsule().stroke(active ? Color.clear : Color(hex: "#1e2d3d"), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.15), value: filterSeverity)
    }
}
 
// MARK: - Alert card row
 
struct AlertCardRow: View {
    let alert: MeshAlertItem
    @ObservedObject private var store = LocalStore.shared
 
    private var contactTrust: Double {
        store.trustScore(for: alert.authorID)
    }
 
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                // Severity icon
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(alert.severity.color.opacity(0.1))
                        .frame(width: 40, height: 40)
                    Image(systemName: alert.severity.icon)
                        .font(.system(size: 18))
                        .foregroundColor(alert.severity.color)
                }
 
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(alert.title)
                            .font(.custom("IBMPlexSans-Medium", size: 14))
                            .foregroundColor(Color(hex: "#d4eaf5"))
                        Spacer()
                        Text(alert.timestamp.chatRelative)
                            .font(.custom("IBMPlexMono-Regular", size: 9))
                            .foregroundColor(Color(hex: "#2a3f52"))
                    }
                    Text(alert.body).lineLimit(2)
                        .font(.custom("IBMPlexSans-Regular", size: 12))
                        .foregroundColor(Color(hex: "#6b8fa8"))
 
                    // Footer
                    HStack(spacing: 8) {
                        Text(alert.authorName)
                            .font(.custom("IBMPlexMono-Regular", size: 9))
                            .foregroundColor(Color(hex: "#2a3f52"))
                        TrustPill(score: alert.trustScore)
 
                        // Comments count
                        HStack(spacing: 3) {
                            Image(systemName: "bubble.left").font(.system(size: 9))
                            Text("\(alert.comments.count)")
                                .font(.custom("IBMPlexMono-Regular", size: 9))
                        }
                        .foregroundColor(Color(hex: "#2a3f52"))
 
                        // Photos count
                        if !alert.photoData.isEmpty {
                            HStack(spacing: 3) {
                                Image(systemName: "photo").font(.system(size: 9))
                                Text("\(alert.photoData.count)")
                                    .font(.custom("IBMPlexMono-Regular", size: 9))
                            }
                            .foregroundColor(Color(hex: "#2a3f52"))
                        }
 
                        Spacer()
 
                        // Proximity trust bar
                        trustBar
                    }
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
 
            // Photo strip (first 3)
            if !alert.photoData.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(Array(alert.photoData.prefix(3).enumerated()), id: \.offset) { _, data in
                            if let img = UIImage(data: data) {
                                Image(uiImage: img).resizable().scaledToFill()
                                    .frame(width: 80, height: 60)
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                            }
                        }
                    }
                    .padding(.horizontal, 16).padding(.bottom, 10)
                }
            }
 
            Divider().overlay(Color(hex: "#111820"))
        }
        .background(Color(hex: "#060809"))
    }
 
    private var trustBar: some View {
        HStack(spacing: 4) {
            Image(systemName: "person.fill")
                .font(.system(size: 8))
                .foregroundColor(Color(hex: "#2a3f52"))
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2).fill(Color(hex: "#111820")).frame(width: 40, height: 3)
                RoundedRectangle(cornerRadius: 2)
                    .fill(trustColor)
                    .frame(width: max(2, 40 * alert.trustScore), height: 3)
            }
            Text(String(format: "%.0f%%", alert.trustScore * 100))
                .font(.custom("IBMPlexMono-Regular", size: 9))
                .foregroundColor(trustColor)
        }
    }
 
    private var trustColor: Color {
        alert.trustScore >= 0.7 ? Color(hex: "#00e5a0")
        : alert.trustScore >= 0.35 ? Color(hex: "#f5a623")
        : Color(hex: "#e53e3e")
    }
}
 
// MARK: - Alert thread (forum-style)
 
struct AlertThreadView: View {
    let alert: MeshAlertItem
    @EnvironmentObject var mesh: BluetoothMeshService
    @ObservedObject private var store = LocalStore.shared
    @State private var commentDraft = ""
    @State private var selectedPhoto: PhotosPickerItem? = nil
    @State private var pendingImage: UIImage? = nil
    @FocusState private var commentFocused: Bool
 
    private var currentAlert: MeshAlertItem {
        store.alerts.first(where: { $0.id == alert.id }) ?? alert
    }
 
    var body: some View {
        ZStack {
            Color(hex: "#060809").ignoresSafeArea()
            VStack(spacing: 0) {
                // Nav header
                HStack(spacing: 10) {
                    BackButton()
                    VStack(alignment: .leading, spacing: 1) {
                        Text(currentAlert.title)
                            .font(.custom("IBMPlexSans-Medium", size: 14))
                            .foregroundColor(Color(hex: "#d4eaf5"))
                            .lineLimit(1)
                        Text("Alert thread · \(currentAlert.comments.count) comments")
                            .font(.custom("IBMPlexMono-Regular", size: 9))
                            .foregroundColor(Color(hex: "#4a6580"))
                    }
                    Spacer()
                    // Confirm button (proximity trust)
                    Button {
                        store.confirmAlert(id: alert.id, byContact: mesh.identity.deviceID)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark.shield")
                                .font(.system(size: 11))
                            Text("CONFIRM")
                                .font(.custom("IBMPlexMono-Regular", size: 9))
                                .kerning(0.5)
                        }
                        .foregroundColor(Color(hex: "#00e5a0"))
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Color(hex: "#00e5a0").opacity(0.08))
                        .cornerRadius(6)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(hex: "#00e5a0").opacity(0.2), lineWidth: 0.5))
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(Color(hex: "#060809"))
                .overlay(alignment: .bottom) { Divider().overlay(Color(hex: "#1e2d3d")) }
 
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        // Alert body card
                        alertBodyCard
                        // Photo grid
                        if !currentAlert.photoData.isEmpty {
                            photoGrid
                        }
                        // Trust explanation
                        trustExplanation
                        // Comments section
                        commentsSection
                    }
                }
 
                // Comment input
                commentInput
            }
        }
        .navigationBarHidden(true)
    }
 
    private var alertBodyCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(currentAlert.severity.color.opacity(0.12))
                        .frame(width: 44, height: 44)
                    Image(systemName: currentAlert.severity.icon)
                        .font(.system(size: 20))
                        .foregroundColor(currentAlert.severity.color)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(currentAlert.severity.label.uppercased())
                        .font(.custom("IBMPlexMono-Regular", size: 9))
                        .foregroundColor(currentAlert.severity.color)
                        .kerning(1)
                    Text(currentAlert.title)
                        .font(.custom("IBMPlexSans-Medium", size: 16))
                        .foregroundColor(Color(hex: "#d4eaf5"))
                }
            }
 
            Text(currentAlert.body)
                .font(.custom("IBMPlexSans-Regular", size: 14))
                .foregroundColor(Color(hex: "#a8c4d8"))
                .lineSpacing(4)
 
            HStack(spacing: 8) {
                Text("by \(currentAlert.authorName)")
                    .font(.custom("IBMPlexMono-Regular", size: 10))
                    .foregroundColor(Color(hex: "#4a6580"))
                Text("·")
                    .foregroundColor(Color(hex: "#2a3f52"))
                Text(currentAlert.timestamp.chatTimeString)
                    .font(.custom("IBMPlexMono-Regular", size: 10))
                    .foregroundColor(Color(hex: "#2a3f52"))
            }
        }
        .padding(16)
        .background(Color(hex: "#0c1014"))
        .cornerRadius(12)
        .overlay(RoundedRectangle(cornerRadius: 12)
            .stroke(currentAlert.severity.color.opacity(0.15), lineWidth: 0.8))
        .padding(16)
    }
 
    private var photoGrid: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("PHOTOS (\(currentAlert.photoData.count))")
                .font(.custom("IBMPlexMono-Regular", size: 9))
                .foregroundColor(Color(hex: "#2a3f52"))
                .kerning(1)
                .padding(.horizontal, 16)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(currentAlert.photoData.enumerated()), id: \.offset) { _, data in
                        if let img = UIImage(data: data) {
                            Image(uiImage: img).resizable().scaledToFill()
                                .frame(width: 140, height: 100)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
        }
        .padding(.bottom, 12)
    }
 
    private var trustExplanation: some View {
        HStack(spacing: 10) {
            Image(systemName: "person.2.fill")
                .font(.system(size: 14))
                .foregroundColor(currentAlert.severity.color)
            VStack(alignment: .leading, spacing: 2) {
                Text("Trust: \(Int(currentAlert.trustScore * 100))% (\(currentAlert.confirmedByContacts.count) contact\(currentAlert.confirmedByContacts.count == 1 ? "" : "s") confirmed)")
                    .font(.custom("IBMPlexMono-Regular", size: 11))
                    .foregroundColor(Color(hex: "#a8c4d8"))
                Text("Score based on how many of YOUR direct contacts verified this.")
                    .font(.custom("IBMPlexMono-Regular", size: 9))
                    .foregroundColor(Color(hex: "#4a6580"))
            }
        }
        .padding(12)
        .background(Color(hex: "#0c1014"))
        .cornerRadius(8)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(hex: "#1e2d3d"), lineWidth: 0.5))
        .padding(.horizontal, 16).padding(.bottom, 12)
    }
 
    private var commentsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("DISCUSSION")
                    .font(.custom("IBMPlexMono-Regular", size: 9))
                    .foregroundColor(Color(hex: "#2a3f52"))
                    .kerning(1.5)
                Spacer()
                Text("\(currentAlert.comments.count) comments")
                    .font(.custom("IBMPlexMono-Regular", size: 9))
                    .foregroundColor(Color(hex: "#2a3f52"))
            }
            .padding(.horizontal, 16).padding(.bottom, 8)
 
            if currentAlert.comments.isEmpty {
                Text("No comments yet. Be the first to verify or dispute this alert.")
                    .font(.custom("IBMPlexMono-Regular", size: 11))
                    .foregroundColor(Color(hex: "#2a3f52"))
                    .padding(16)
            } else {
                ForEach(currentAlert.comments) { comment in
                    CommentRow(comment: comment)
                }
            }
        }
        .padding(.top, 4)
    }
 
    private var commentInput: some View {
        VStack(spacing: 0) {
            Divider().overlay(Color(hex: "#1e2d3d"))
 
            if let img = pendingImage {
                HStack(spacing: 8) {
                    Image(uiImage: img).resizable().scaledToFill()
                        .frame(width: 44, height: 44)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    Text("Photo attached")
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
                PhotosPicker(selection: $selectedPhoto, matching: .images) {
                    Image(systemName: "photo").font(.system(size: 18))
                        .foregroundColor(Color(hex: "#4a6580"))
                        .frame(width: 34, height: 34)
                }
                .onChange(of: selectedPhoto) { item in
                    Task {
                        if let data = try? await item?.loadTransferable(type: Data.self),
                           let img = UIImage(data: data) {
                            await MainActor.run { pendingImage = img }
                        }
                    }
                }
 
                ZStack(alignment: .leading) {
                    if commentDraft.isEmpty { Text("Add comment or photo…")
                        .font(.custom("IBMPlexSans-Regular", size: 13))
                        .foregroundColor(Color(hex: "#2a3f52")).padding(.leading, 14) }
                    TextField("", text: $commentDraft, axis: .vertical)
                        .font(.custom("IBMPlexSans-Regular", size: 13))
                        .foregroundColor(Color(hex: "#d4eaf5"))
                        .lineLimit(1...4).focused($commentFocused)
                        .padding(.horizontal, 14).padding(.vertical, 9)
                }
                .background(Color(hex: "#111820")).cornerRadius(18)
                .overlay(Capsule().stroke(Color(hex: "#1e2d3d"), lineWidth: 0.5))
 
                Button { postComment() } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(Color(hex: "#060809"))
                        .frame(width: 32, height: 32)
                        .background(canPost ? Color(hex: "#00e5a0") : Color(hex: "#2a3f52"))
                        .clipShape(Circle())
                }
                .disabled(!canPost)
            }
            .padding(.horizontal, 12).padding(.vertical, 10).padding(.bottom, 4)
            .background(Color(hex: "#060809"))
        }
    }
 
    private var canPost: Bool {
        !commentDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || pendingImage != nil
    }
 
    private func postComment() {
        let text = commentDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let isContact = store.contacts.first(where: { $0.id == mesh.identity.deviceID })?.isFriend ?? false
        var imgData: Data? = nil
        if let img = pendingImage { imgData = img.jpegData(compressionQuality: 0.5) }
        let comment = AlertComment(
            id: UUID(), alertID: alert.id,
            authorID: mesh.identity.deviceID,
            authorName: mesh.identity.nickname,
            text: text.isEmpty ? "📷 Photo" : text,
            imageData: imgData,
            timestamp: Date(),
            isFromContact: isContact
        )
        store.addComment(comment, to: alert.id)
        commentDraft = ""
        pendingImage = nil
        selectedPhoto = nil
    }
}
 
// MARK: - Comment row
 
private struct CommentRow: View {
    let comment: AlertComment
    @ObservedObject private var store = LocalStore.shared
 
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            // Avatar
            Circle().fill(Color(hex: "#111820"))
                .frame(width: 30, height: 30)
                .overlay(
                    Text(String(comment.authorName.prefix(2)).uppercased())
                        .font(.custom("IBMPlexMono-Regular", size: 10))
                        .foregroundColor(Color(hex: "#4a6580"))
                )
 
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(comment.authorName)
                        .font(.custom("IBMPlexMono-Medium", size: 10))
                        .foregroundColor(comment.isFromContact ? Color(hex: "#00e5a0") : Color(hex: "#4a6580"))
                    if comment.isFromContact {
                        Label("Contact", systemImage: "person.badge.shield.checkmark.fill")
                            .labelStyle(.iconOnly)
                            .font(.system(size: 9))
                            .foregroundColor(Color(hex: "#00e5a0"))
                    }
                    Text("·")
                        .foregroundColor(Color(hex: "#2a3f52"))
                    Text(comment.timestamp.chatRelative)
                        .font(.custom("IBMPlexMono-Regular", size: 9))
                        .foregroundColor(Color(hex: "#2a3f52"))
                    Spacer()
                    TrustPill(score: store.trustScore(for: comment.authorID))
                }
 
                if let data = comment.imageData, let img = UIImage(data: data) {
                    Image(uiImage: img).resizable().scaledToFit()
                        .frame(maxWidth: 200, maxHeight: 140)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
 
                if !comment.text.isEmpty && comment.text != "📷 Photo" {
                    Text(comment.text)
                        .font(.custom("IBMPlexSans-Regular", size: 13))
                        .foregroundColor(Color(hex: "#a8c4d8"))
                        .lineSpacing(2)
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .overlay(alignment: .bottom) { Divider().overlay(Color(hex: "#0c1014")).padding(.leading, 56) }
    }
}
 
// MARK: - New alert sheet
 
struct NewAlertSheet: View {
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var mesh: BluetoothMeshService
    @ObservedObject private var store = LocalStore.shared
 
    @State private var severity: AlertSeverity = .warning
    @State private var title = ""
    @State private var alertBodyText = ""
    @State private var selectedPhoto: PhotosPickerItem? = nil
    @State private var photos: [UIImage] = []
 
    var body: some View {
        ZStack {
            Color(hex: "#060809").ignoresSafeArea()
            VStack(spacing: 0) {
                HStack {
                    Button("Cancel") { dismiss() }
                        .font(.custom("IBMPlexMono-Regular", size: 13))
                        .foregroundColor(Color(hex: "#4a6580"))
                    Spacer()
                    Text("NEW ALERT")
                        .font(.custom("IBMPlexMono-SemiBold", size: 12))
                        .foregroundColor(Color(hex: "#d4eaf5"))
                        .kerning(1.5)
                    Spacer()
                    Button("Post") { post() }
                        .font(.custom("IBMPlexMono-Medium", size: 13))
                        .foregroundColor(title.isEmpty ? Color(hex: "#2a3f52") : Color(hex: "#00e5a0"))
                        .disabled(title.isEmpty)
                }
                .padding(16)
                .overlay(alignment: .bottom) { Divider().overlay(Color(hex: "#1e2d3d")) }
 
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        // Severity picker
                        VStack(alignment: .leading, spacing: 8) {
                            fieldLabel("SEVERITY")
                            HStack(spacing: 8) {
                                ForEach(AlertSeverity.allCases, id: \.self) { s in
                                    Button { severity = s } label: {
                                        HStack(spacing: 4) {
                                            Image(systemName: s.icon).font(.system(size: 11))
                                            Text(s.label.uppercased())
                                                .font(.custom("IBMPlexMono-Regular", size: 9))
                                                .kerning(0.5)
                                        }
                                        .foregroundColor(severity == s ? Color(hex: "#060809") : s.color)
                                        .padding(.horizontal, 10).padding(.vertical, 7)
                                        .background(severity == s ? s.color : s.color.opacity(0.08))
                                        .cornerRadius(6)
                                        .overlay(RoundedRectangle(cornerRadius: 6)
                                            .stroke(severity == s ? Color.clear : s.color.opacity(0.25), lineWidth: 0.5))
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
 
                        // Title
                        VStack(alignment: .leading, spacing: 8) {
                            fieldLabel("TITLE")
                            TextField("e.g. Checkpoint · North Gate", text: $title)
                                .font(.custom("IBMPlexSans-Regular", size: 14))
                                .foregroundColor(Color(hex: "#d4eaf5"))
                                .padding(12).background(Color(hex: "#111820"))
                                .cornerRadius(8)
                                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(hex: "#1e2d3d"), lineWidth: 0.5))
                        }
 
                        // Body
                        VStack(alignment: .leading, spacing: 8) {
                            fieldLabel("DETAILS")
                            ZStack(alignment: .topLeading) {
                                if alertBodyText.isEmpty {
                                    Text("What did you observe? Be specific about location and time.")
                                        .font(.custom("IBMPlexSans-Regular", size: 13))
                                        .foregroundColor(Color(hex: "#2a3f52"))
                                        .padding(12)
                                }
                                TextEditor(text: $alertBodyText)
                                    .font(.custom("IBMPlexSans-Regular", size: 13))
                                    .foregroundColor(Color(hex: "#d4eaf5"))
                                    .scrollContentBackground(.hidden)
                                    .frame(minHeight: 80)
                                    .padding(8)
                            }
                            .background(Color(hex: "#111820")).cornerRadius(8)
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(hex: "#1e2d3d"), lineWidth: 0.5))
                        }
 
                        // Photos
                        VStack(alignment: .leading, spacing: 8) {
                            fieldLabel("PHOTOS (optional)")
                            HStack(spacing: 8) {
                                ForEach(Array(photos.enumerated()), id: \.offset) { _, img in
                                    Image(uiImage: img).resizable().scaledToFill()
                                        .frame(width: 72, height: 72)
                                        .clipShape(RoundedRectangle(cornerRadius: 8))
                                }
                                PhotosPicker(selection: $selectedPhoto, matching: .images) {
                                    VStack(spacing: 4) {
                                        Image(systemName: "plus").font(.system(size: 20))
                                        Text("Add").font(.custom("IBMPlexMono-Regular", size: 9))
                                    }
                                    .foregroundColor(Color(hex: "#4a6580"))
                                    .frame(width: 72, height: 72)
                                    .background(Color(hex: "#111820"))
                                    .cornerRadius(8)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8)
                                            .stroke(Color(hex: "#1e2d3d"), style: StrokeStyle(lineWidth: 0.5, dash: [4]))
                                    )
                                }
                                .onChange(of: selectedPhoto) { item in
                                    Task {
                                        if let data = try? await item?.loadTransferable(type: Data.self),
                                           let img = UIImage(data: data) {
                                            await MainActor.run { photos.append(img) }
                                        }
                                    }
                                }
                            }
                        }
 
                        // Trust note
                        HStack(spacing: 8) {
                            Image(systemName: "info.circle").font(.system(size: 12))
                                .foregroundColor(Color(hex: "#4a6580"))
                            Text("Trust score is based on how many of YOUR direct contacts confirm this alert — not on endorsements from strangers.")
                                .font(.custom("IBMPlexMono-Regular", size: 9))
                                .foregroundColor(Color(hex: "#4a6580"))
                                .lineSpacing(2)
                        }
                        .padding(10).background(Color(hex: "#0c1014"))
                        .cornerRadius(8)
                    }
                    .padding(16)
                }
            }
        }
    }
 
    private func fieldLabel(_ t: String) -> some View {
        Text(t).font(.custom("IBMPlexMono-Regular", size: 9))
            .foregroundColor(Color(hex: "#2a3f52")).kerning(1.5)
    }
 
    private func post() {
        let photoDataArray = photos.compactMap { $0.jpegData(compressionQuality: 0.5) }
        let alert = MeshAlertItem(
            id: UUID(), severity: severity, title: title, body: alertBodyText,
            authorID: mesh.identity.deviceID, authorName: mesh.identity.nickname,
            timestamp: Date(), isExpired: false, expiresAt: Date().addingTimeInterval(6 * 3600),
            confirmedByContacts: [], comments: [], photoData: photoDataArray
        )
        store.saveAlert(alert)
        dismiss()
    }
}