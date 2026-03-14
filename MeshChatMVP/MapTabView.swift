import SwiftUI
import MapKit
import CoreLocation
import PhotosUI

// MARK: - MapTabView

struct MapTabView: View {
    @EnvironmentObject var mesh: BluetoothMeshService
    @StateObject private var headingProvider = LocationHeadingProvider()

    private static let defaultCenter = CLLocationCoordinate2D(latitude: -33.8688, longitude: 151.2093)
    private static let defaultSpan   = MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)

    @State private var region = MKCoordinateRegion(center: defaultCenter, span: defaultSpan)
    @State private var showOfflineInfo    = false
    @State private var isCaching         = false
    @State private var showAddLabelSheet  = false
    @State private var showCooldownAlert  = false
    @State private var selectedLabel: MapLabelRecord?

    /// Drives the expiry-pruning timer.
    @State private var now = Date()

    /// Active (non-expired) label records.
    private var activeRecords: [MapLabelRecord] {
        labelRecords.filter { !$0.isExpired }
    }

    private var labelRecords: [MapLabelRecord] {
        mesh.mapLabels.map { id, payload in
            let votes    = mesh.labelVotes[id] ?? [:]
            let upVotes  = votes.values.filter { $0 == 1 }.count
            let downVotes = votes.values.filter { $0 == -1 }.count
            let category = LabelCategory(rawValue: payload.category) ?? .checkpoint
            return MapLabelRecord(
                id: id, category: category,
                latitude: payload.lat, longitude: payload.lon,
                senderID: payload.senderID, senderName: payload.senderName,
                date: Date(timeIntervalSince1970: Double(payload.timestamp) / 1000),
                upVotes: upVotes, downVotes: downVotes
            )
        }
    }

    private var combinedAnnotations: [MapAnnotationItem] {
        annotationItems.map { .transmitter($0) } + activeRecords.map { .label($0) }
    }

    private var annotationItems: [TransmitterPin] {
        var items: [TransmitterPin] = []
        for (senderID, coords) in mesh.senderCoordinates {
            let name = mesh.announceNicknames[senderID] ?? String(senderID.prefix(8))
            items.append(TransmitterPin(
                id: "sender-\(senderID)",
                coordinate: CLLocationCoordinate2D(latitude: coords.lat, longitude: coords.lon),
                displayName: name, isCurrentUser: false
            ))
        }
        if mesh.identity.shareLocation, let my = mesh.lastKnownLocation {
            items.append(TransmitterPin(
                id: "me",
                coordinate: CLLocationCoordinate2D(latitude: my.lat, longitude: my.lon),
                displayName: mesh.identity.nickname, isCurrentUser: true
            ))
        }
        return items
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                mapLayer

                // Compass overlay
                if let heading = headingProvider.headingDegrees {
                    VStack {
                        Spacer()
                        HStack {
                            Spacer()
                            CompassView(headingDegrees: heading)
                                .padding(.trailing, 14)
                                .padding(.bottom, 110)
                        }
                    }
                    .allowsHitTesting(false)
                }

                // Control bar
                topControls
            }
            .navigationTitle("Map")
            .navigationBarTitleDisplayMode(.inline)
            .alert("Cooldown", isPresented: $showCooldownAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Please wait \(Int(ceil(mesh.mapLabelCooldownRemaining)))s before placing another alert.")
            }
            .sheet(isPresented: $showOfflineInfo) {
                OfflineMapSheet(isCaching: $isCaching, region: region, onCache: cacheCurrentRegion)
            }
            .sheet(isPresented: $showAddLabelSheet) {
                AddLabelSheet(regionCenter: region.center) { category in
                    mesh.sendMapLabel(category: category, lat: region.center.latitude, lon: region.center.longitude)
                    showAddLabelSheet = false
                } onCancel: { showAddLabelSheet = false }
            }
            .sheet(item: $selectedLabel) { record in
                AlertThreadSheet(
                    record: record,
                    myVote: mesh.labelVotes[record.id]?[mesh.identity.deviceID],
                    comments: mesh.labelComments[record.id] ?? [],
                    onVote: { mesh.voteForLabel(labelId: record.id, up: $0) },
                    onComment: { text, image in
                        mesh.sendLabelComment(labelId: record.id, text: text, imageJPEGBase64: image)
                    },
                    selectedLabel: $selectedLabel
                )
            }
        }
        // Expire stale alerts every 60s
        .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { now in
            self.now = now
        }
    }

    // MARK: - Map layer

    @ViewBuilder
    private var mapLayer: some View {
        if combinedAnnotations.isEmpty {
            Map(coordinateRegion: $region).ignoresSafeArea(edges: .all)
            emptyMapOverlay
        } else {
            Map(coordinateRegion: $region, annotationItems: combinedAnnotations) { item in
                MapAnnotation(coordinate: item.coordinate) {
                    switch item {
                    case .transmitter(let p):  transmitterPin(p)
                    case .label(let record):   alertPin(record)
                    }
                }
            }
            .ignoresSafeArea(edges: .all)
            .onAppear { fitRegion() }
            .onChange(of: mesh.senderCoordinates.count)  { _ in fitRegion() }
            .onChange(of: mesh.identity.shareLocation)   { _ in fitRegion() }
            .onChange(of: mesh.mapLabels.count)          { _ in fitRegion() }
        }
    }

    private var emptyMapOverlay: some View {
        VStack(spacing: 10) {
            Spacer(minLength: 120)
            Image(systemName: "map")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(Color(.systemGray4))
            Text("No alerts or positions")
                .font(.headline).foregroundStyle(.secondary)
            Text("Enable location sharing or place an alert\nto populate the map.")
                .font(.subheadline).foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
            Spacer()
        }
    }

    // MARK: - Annotation views

    private func transmitterPin(_ p: TransmitterPin) -> some View {
        VStack(spacing: 3) {
            ZStack {
                Circle()
                    .fill(p.isCurrentUser ? Color.primary : Color(.systemBackground))
                    .frame(width: 30, height: 30)
                    .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
                Image(systemName: p.isCurrentUser ? "person.fill" : "antenna.radiowaves.left.and.right")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(p.isCurrentUser ? Color(.systemBackground) : .primary)
            }
            Text(p.displayName)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.primary)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(Capsule().fill(.ultraThinMaterial))
        }
    }

    private func alertPin(_ record: MapLabelRecord) -> some View {
        let commentCount = (mesh.labelComments[record.id] ?? []).count
        return Button { selectedLabel = record } label: {
            VStack(spacing: 3) {
                ZStack(alignment: .topTrailing) {
                    ZStack {
                        Circle()
                            .fill(Color(.systemBackground))
                            .frame(width: 28, height: 28)
                            .shadow(color: .black.opacity(0.14), radius: 3, y: 1)
                        Image(systemName: record.category.systemImage)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.red)
                    }
                    if commentCount > 0 {
                        Text("\(min(commentCount, 99))")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 3)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.red))
                            .offset(x: 6, y: -4)
                    }
                }
                Text(record.category.displayName)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(.ultraThinMaterial))
            }
            .opacity(record.mapOpacity)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Top controls

    private var topControls: some View {
        VStack {
            HStack(spacing: 10) {
                // Location sharing pill
                Button {
                    var id = mesh.identity
                    id.shareLocation.toggle()
                    mesh.updateIdentity(id)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: mesh.identity.shareLocation ? "location.fill" : "location.slash")
                            .font(.caption.weight(.semibold))
                        Text(mesh.identity.shareLocation ? "Sharing" : "Location Off")
                            .font(.caption.weight(.semibold))
                    }
                    .foregroundStyle(mesh.identity.shareLocation ? Color(.systemBackground) : .primary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(mesh.identity.shareLocation ? Color.primary : Color(.systemBackground)))
                }

                Spacer()

                // Place alert
                Button {
                    mesh.mapLabelCooldownRemaining > 0 ? (showCooldownAlert = true) : (showAddLabelSheet = true)
                } label: {
                    Group {
                        if mesh.mapLabelCooldownRemaining > 0 {
                            Text("\(Int(ceil(mesh.mapLabelCooldownRemaining)))s")
                                .font(.caption.monospacedDigit().weight(.semibold))
                        } else {
                            Image(systemName: "exclamationmark.circle")
                                .font(.system(size: 16, weight: .semibold))
                        }
                    }
                    .foregroundStyle(.primary)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(Color(.systemBackground)))
                    .shadow(color: .black.opacity(0.1), radius: 3, y: 1)
                }
                .disabled(mesh.mapLabelCooldownRemaining > 0)

                // Offline maps
                Button { showOfflineInfo = true } label: {
                    Image(systemName: "arrow.down.to.line")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(Color(.systemBackground)))
                        .shadow(color: .black.opacity(0.1), radius: 3, y: 1)
                }
            }
            .padding(12)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .shadow(color: .black.opacity(0.07), radius: 6, y: 2)
            .padding(.horizontal, 14)
            .padding(.top, 8)
            Spacer()
        }
    }

    // MARK: - Helpers

    private func cacheCurrentRegion() {
        guard !isCaching else { return }
        isCaching = true
        let opts = MKMapSnapshotter.Options()
        opts.region = region
        opts.size = CGSize(width: 512, height: 512)
        MKMapSnapshotter(options: opts).start { _, _ in
            DispatchQueue.main.async { isCaching = false }
        }
    }

    private func fitRegion() {
        guard !combinedAnnotations.isEmpty else { return }
        let coords = combinedAnnotations.map(\.coordinate)
        let lats = coords.map(\.latitude); let lons = coords.map(\.longitude)
        region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: ((lats.min() ?? 0) + (lats.max() ?? 0)) / 2,
                                           longitude: ((lons.min() ?? 0) + (lons.max() ?? 0)) / 2),
            span: MKCoordinateSpan(
                latitudeDelta:  max(0.005, ((lats.max() ?? 0) - (lats.min() ?? 0)) * 1.4),
                longitudeDelta: max(0.005, ((lons.max() ?? 0) - (lons.min() ?? 0)) * 1.4)
            )
        )
    }
}

// MARK: - Alert Thread Sheet (forum-style)

struct AlertThreadSheet: View {
    let record: MapLabelRecord
    let myVote: Int?
    let comments: [LabelComment]
    let onVote: (Bool) -> Void
    let onComment: (String, String?) -> Void
    @Binding var selectedLabel: MapLabelRecord?

    @State private var draft = ""
    @FocusState private var inputFocused: Bool
    @State private var pickedItem: PhotosPickerItem?
    @State private var pendingImage: UIImage?
    @State private var isSending = false

    private var timeRemaining: String {
        let remaining = record.expiresAt.timeIntervalSinceNow
        if remaining <= 0 { return "Expired" }
        if remaining < 3600 { return "Expires in \(Int(remaining / 60))m" }
        return "Expires in \(Int(remaining / 3600))h"
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Alert header
                alertHeader
                Divider()

                // Vote bar
                voteBar

                Divider()

                // Comment thread
                ScrollViewReader { proxy in
                    ScrollView {
                        if comments.isEmpty {
                            VStack(spacing: 8) {
                                Spacer(minLength: 40)
                                Image(systemName: "text.bubble")
                                    .font(.system(size: 32, weight: .light))
                                    .foregroundStyle(Color(.systemGray4))
                                Text("No reports yet")
                                    .font(.subheadline).foregroundStyle(.secondary)
                                Text("Be the first to verify or add context to this alert.")
                                    .font(.caption).foregroundStyle(.tertiary)
                                    .multilineTextAlignment(.center).padding(.horizontal, 40)
                                Spacer()
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.top, 20)
                        } else {
                            LazyVStack(spacing: 0) {
                                ForEach(comments) { comment in
                                    commentRow(comment)
                                    Divider().padding(.leading, 52)
                                }
                            }
                        }
                    }
                    .background(Color(.systemGroupedBackground))
                    .onChange(of: comments.count) { _ in
                        if let last = comments.last { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }

                // Pending image preview
                if let img = pendingImage {
                    HStack(spacing: 10) {
                        Image(uiImage: img)
                            .resizable().scaledToFill()
                            .frame(width: 52, height: 52)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        Text("Photo attached")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button { pendingImage = nil } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(Color(.systemGray3))
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Color(.systemBackground))
                    Divider()
                }

                // Comment input bar
                commentInputBar
            }
            .navigationTitle(record.category.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Close") { selectedLabel = nil }
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { inputFocused = false }
                }
            }
            .onChange(of: pickedItem) { item in
                guard let item else { return }
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self),
                       let ui = UIImage(data: data) {
                        await MainActor.run { pendingImage = ui; pickedItem = nil }
                    }
                }
            }
        }
    }

    // MARK: Header

    private var alertHeader: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(.systemGray6))
                    .frame(width: 44, height: 44)
                Image(systemName: record.category.systemImage)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.red)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(record.senderName)
                    .font(.subheadline.weight(.semibold))
                HStack(spacing: 6) {
                    Text(record.date.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption).foregroundStyle(.secondary)
                    Text("·").font(.caption).foregroundStyle(.tertiary)
                    Text(timeRemaining)
                        .font(.caption)
                        .foregroundStyle(record.expiresAt.timeIntervalSinceNow < 3600 ? .orange : .secondary)
                }
            }
            Spacer()
            confidenceBadge
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private var confidenceBadge: some View {
        let score = record.confidenceScore
        let color: Color = score > 0.6 ? .red : (score < 0.4 ? Color(.systemGray3) : .orange)
        return VStack(spacing: 2) {
            Text(String(format: "%.0f%%", score * 100))
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(color)
            Text("confidence")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: Vote bar

    private var voteBar: some View {
        HStack(spacing: 0) {
            voteButton(up: true,  label: "Confirmed",  icon: "checkmark.circle",      count: record.upVotes,   selected: myVote == 1)
            Divider().frame(height: 36)
            voteButton(up: false, label: "Unverified", icon: "questionmark.circle",   count: record.downVotes, selected: myVote == -1)
        }
        .background(Color(.systemBackground))
    }

    private func voteButton(up: Bool, label: String, icon: String, count: Int, selected: Bool) -> some View {
        Button { onVote(up) } label: {
            HStack(spacing: 6) {
                Image(systemName: selected ? icon.replacingOccurrences(of: ".circle", with: ".circle.fill") : icon)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(selected ? (up ? .green : .orange) : .secondary)
                Text(label)
                    .font(.subheadline.weight(selected ? .semibold : .regular))
                    .foregroundStyle(selected ? .primary : .secondary)
                Text("(\(count))")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
        }
        .buttonStyle(.plain)
    }

    // MARK: Comment row

    private func commentRow(_ c: LabelComment) -> some View {
        HStack(alignment: .top, spacing: 12) {
            // Avatar
            ZStack {
                Circle()
                    .fill(c.isLocal ? Color.primary : Color(.systemGray5))
                    .frame(width: 32, height: 32)
                Text(String(c.senderName.prefix(1)).uppercased())
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(c.isLocal ? Color(.systemBackground) : .primary)
            }

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(c.senderName)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(c.isLocal ? .primary : .secondary)
                    Text(c.date, style: .relative)
                        .font(.caption2).foregroundStyle(.tertiary)
                }
                if !c.text.isEmpty {
                    Text(c.text)
                        .font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let b64 = c.imageJPEGBase64,
                   let data = Data(base64Encoded: b64),
                   let ui = UIImage(data: data) {
                    Image(uiImage: ui)
                        .resizable().scaledToFit()
                        .frame(maxWidth: 200, maxHeight: 180)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .padding(.top, 2)
                }
            }
            Spacer()
        }
        .id(c.id)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color(.systemBackground))
    }

    // MARK: Comment input

    private var commentInputBar: some View {
        HStack(alignment: .bottom, spacing: 10) {
            PhotosPicker(selection: $pickedItem, matching: .images, photoLibrary: .shared()) {
                Image(systemName: "photo")
                    .font(.system(size: 18))
                    .foregroundStyle(.secondary)
                    .frame(width: 32, height: 32)
            }

            TextField("Add a report or context…", text: $draft, axis: .vertical)
                .font(.subheadline)
                .lineLimit(1...4)
                .focused($inputFocused)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color(.systemGray6))
                )

            Button {
                guard !isSending else { return }
                let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty || pendingImage != nil else { return }
                isSending = true
                var b64: String? = nil
                if let img = pendingImage,
                   let compressed = try? MeshImageUtils.jpegDataForMesh(from: img) {
                    b64 = compressed.base64EncodedString()
                }
                onComment(text, b64)
                draft = ""
                pendingImage = nil
                inputFocused = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { isSending = false }
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(
                        (draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && pendingImage == nil) || isSending
                            ? Color(.systemGray4) : Color.primary
                    )
            }
            .disabled((draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && pendingImage == nil) || isSending)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color(.systemBackground))
    }
}

// MARK: - Add Label Sheet

private struct AddLabelSheet: View {
    let regionCenter: CLLocationCoordinate2D
    let onSelect: (LabelCategory) -> Void
    let onCancel: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Place an alert at the current map center. Nearby peers will receive it and can verify with comments and votes.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Section("Alert Type") {
                    ForEach(LabelCategory.allCases, id: \.rawValue) { category in
                        Button {
                            onSelect(category)
                            dismiss()
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: category.systemImage)
                                    .font(.system(size: 15, weight: .medium))
                                    .foregroundStyle(.red)
                                    .frame(width: 24)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(category.displayName)
                                        .foregroundStyle(.primary)
                                    Text("Auto-expires in \(expiryLabel(category))")
                                        .font(.caption).foregroundStyle(.tertiary)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Place Alert")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onCancel(); dismiss() }
                }
            }
        }
    }

    private func expiryLabel(_ c: LabelCategory) -> String {
        let h = Int(c.expiryDuration / 3600)
        return h == 1 ? "1 hour" : "\(h) hours"
    }
}

// MARK: - Offline Map Sheet

private struct OfflineMapSheet: View {
    @Binding var isCaching: Bool
    let region: MKCoordinateRegion
    let onCache: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Map tiles are cached as you pan and zoom. Tap below to pre-load the current area. For extended offline use, download regions in the Apple Maps app before going offline.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Section("This Area") {
                    Button {
                        onCache()
                    } label: {
                        HStack {
                            Label("Cache Current Area", systemImage: "square.and.arrow.down")
                                .foregroundStyle(.primary)
                            if isCaching { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(isCaching)
                }
            }
            .navigationTitle("Offline Maps")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Compass

private struct CompassView: View {
    let headingDegrees: Double
    var body: some View {
        ZStack {
            Circle()
                .fill(.ultraThinMaterial)
                .frame(width: 44, height: 44)
                .shadow(color: .black.opacity(0.1), radius: 3, y: 1)
            Image(systemName: "location.north.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.primary)
                .rotationEffect(.degrees(-headingDegrees))
        }
        .overlay(alignment: .top) {
            Text("N")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.secondary)
                .offset(y: -20)
        }
    }
}

// MARK: - Location heading provider

private final class LocationHeadingProvider: NSObject, ObservableObject {
    @Published private(set) var headingDegrees: Double?
    private let manager = CLLocationManager()
    override init() {
        super.init()
        manager.delegate = self
        manager.headingFilter = 5
        if CLLocationManager.headingAvailable() { manager.startUpdatingHeading() }
    }
    deinit { manager.stopUpdatingHeading() }
}

extension LocationHeadingProvider: CLLocationManagerDelegate {
    func locationManager(_ manager: CLLocationManager, didUpdateHeading h: CLHeading) {
        guard h.headingAccuracy >= 0 else { return }
        DispatchQueue.main.async { [weak self] in
            self?.headingDegrees = h.trueHeading >= 0 ? h.trueHeading : h.magneticHeading
        }
    }
}

// MARK: - Supporting types

private struct TransmitterPin: Identifiable {
    let id: String
    let coordinate: CLLocationCoordinate2D
    let displayName: String
    let isCurrentUser: Bool
}

private enum MapAnnotationItem: Identifiable {
    case transmitter(TransmitterPin)
    case label(MapLabelRecord)

    var id: String {
        switch self {
        case .transmitter(let p): return "tx-\(p.id)"
        case .label(let l):       return "label-\(l.id.uuidString)"
        }
    }
    var coordinate: CLLocationCoordinate2D {
        switch self {
        case .transmitter(let p): return p.coordinate
        case .label(let l):       return l.coordinate
        }
    }
}

#Preview {
    MapTabView().environmentObject(BluetoothMeshService())
}
