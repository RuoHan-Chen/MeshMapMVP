import SwiftUI
import MapKit
import CoreLocation
import PhotosUI
import UIKit

/// Map tab: shows positions of transmitters using existing coordinate exchange data.
/// Reads only from mesh.lastKnownLocation, mesh.senderCoordinates, mesh.announceNicknames, mesh.identity.
struct MapTabView: View {
    @EnvironmentObject var mesh: BluetoothMeshService
    @StateObject private var headingProvider = LocationHeadingProvider()
    @StateObject private var eventTypesManager = EventTypesManager()

    private static let defaultCenter = CLLocationCoordinate2D(latitude: -33.8688, longitude: 151.2093)
    private static let defaultSpan = MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
    private static let maxLabelDistanceMeters = 5_000.0

    @State private var region = MKCoordinateRegion(
        center: defaultCenter,
        span: defaultSpan
    )
    @State private var showOfflineInfo = false
    @State private var isCaching = false
    @State private var showAddLabelSheet = false
    @State private var showCooldownAlert = false
    @State private var showTooFarAlert = false
    @State private var selectedLabel: MapLabelRecord?
    @State private var selectedCluster: LabelCluster?

    /// Labels built from mesh.mapLabels + mesh.labelVotes; filtered to within 5km and not expired.
    private var labelRecords: [MapLabelRecord] {
        let now = Date()
        guard let myLoc = mesh.lastKnownLocation else {
            return mesh.mapLabels.compactMap { id, payload in
                buildRecord(id: id, payload: payload)
            }
            .filter { now.timeIntervalSince($0.date) <= MapLabelRecord.eventExpirationInterval }
        }
        return mesh.mapLabels.compactMap { id, payload in
            guard let record = buildRecord(id: id, payload: payload) else { return nil }
            guard now.timeIntervalSince(record.date) <= MapLabelRecord.eventExpirationInterval else { return nil }
            let dist = BluetoothMeshService.haversineMeters(lat1: myLoc.lat, lon1: myLoc.lon, lat2: payload.lat, lon2: payload.lon)
            guard dist <= Self.maxLabelDistanceMeters else { return nil }
            return record
        }
    }

    private func buildRecord(id: UUID, payload: MapLabelPayload) -> MapLabelRecord? {
        let votes = mesh.labelVotes[id] ?? [:]
        let upVotes = votes.values.filter { $0 == 1 }.count
        let downVotes = votes.values.filter { $0 == -1 }.count
        let category = LabelCategory(rawValue: payload.category) ?? .checkpoint
        return MapLabelRecord(
            id: id,
            category: category,
            latitude: payload.lat,
            longitude: payload.lon,
            senderID: payload.senderID,
            senderName: payload.senderName,
            date: Date(timeIntervalSince1970: Double(payload.timestamp) / 1000),
            upVotes: upVotes,
            downVotes: downVotes,
            customLabelName: payload.customLabelName,
            customDescription: payload.customDescription,
            customSystemImage: payload.customSystemImage
        )
    }

    /// True if the given coordinate is within 5km of user (or we don't have location).
    private func isWithinPlacementRange(_ coordinate: CLLocationCoordinate2D) -> Bool {
        guard let my = mesh.lastKnownLocation else { return true }
        let dist = BluetoothMeshService.haversineMeters(lat1: my.lat, lon1: my.lon, lat2: coordinate.latitude, lon2: coordinate.longitude)
        return dist <= Self.maxLabelDistanceMeters
    }

    /// Clustered labels so nearby events share one pin.
    private var labelClusters: [LabelCluster] {
        var clusters: [LabelCluster] = []
        let radiusMeters = 60.0
        for record in labelRecords {
            var placed = false
            for idx in clusters.indices {
                let center = clusters[idx].coordinate
                let dist = BluetoothMeshService.haversineMeters(
                    lat1: center.latitude,
                    lon1: center.longitude,
                    lat2: record.latitude,
                    lon2: record.longitude
                )
                if dist <= radiusMeters {
                    clusters[idx].records.append(record)
                    let all = clusters[idx].records
                    let avgLat = all.map { $0.latitude }.reduce(0, +) / Double(all.count)
                    let avgLon = all.map { $0.longitude }.reduce(0, +) / Double(all.count)
                    clusters[idx].coordinate = CLLocationCoordinate2D(latitude: avgLat, longitude: avgLon)
                    placed = true
                    break
                }
            }
            if !placed {
                clusters.append(
                    LabelCluster(
                        id: record.id,
                        coordinate: record.coordinate,
                        records: [record]
                    )
                )
            }
        }
        return clusters
    }

    /// Combined annotations: transmitters + clustered labels (single list for Map).
    private var combinedAnnotations: [MapAnnotationItem] {
        let transmitterItems = annotationItems.map { MapAnnotationItem.transmitter($0) }
        let labelItems = labelClusters.map { MapAnnotationItem.labelCluster($0) }
        return transmitterItems + labelItems
    }

    /// Pins to show: remote senders from senderCoordinates plus current user if sharing.
    private var annotationItems: [TransmitterPin] {
        var items: [TransmitterPin] = []
        for (senderID, coords) in mesh.senderCoordinates {
            let name = mesh.announceNicknames[senderID] ?? String(senderID.prefix(8))
            items.append(TransmitterPin(
                id: "sender-\(senderID)",
                coordinate: CLLocationCoordinate2D(latitude: coords.lat, longitude: coords.lon),
                displayName: name,
                isCurrentUser: false
            ))
        }
        if mesh.identity.shareLocation, let my = mesh.lastKnownLocation {
            items.append(TransmitterPin(
                id: "me",
                coordinate: CLLocationCoordinate2D(latitude: my.lat, longitude: my.lon),
                displayName: mesh.identity.nickname,
                isCurrentUser: true
            ))
        }
        return items
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                if combinedAnnotations.isEmpty {
                    Map(coordinateRegion: $region)
                        .ignoresSafeArea(edges: .all)
                    VStack(spacing: 8) {
                        Text("No positions or labels yet")
                            .font(.headline)
                        Text("Turn on \"Share location\" to show your position. Tap \"Add label\" to place an incident label; others can vote on validity.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }
                    .padding(.top, 60)
                } else {
                    Map(coordinateRegion: $region, annotationItems: combinedAnnotations) { item in
                        MapAnnotation(coordinate: item.coordinate) {
                            switch item {
                            case .transmitter(let p):
                                VStack(spacing: 2) {
                                    Image(systemName: p.isCurrentUser ? "person.circle.fill" : "antenna.radiowaves.left.and.right")
                                        .font(.title2)
                                        .foregroundStyle(p.isCurrentUser ? .blue : .orange)
                                    Text(p.displayName)
                                        .font(.caption2)
                                        .lineLimit(1)
                                }
                                .padding(6)
                                .background(.background, in: RoundedRectangle(cornerRadius: 8))
                            case .labelCluster(let cluster):
                                let sorted = cluster.records.sorted { $0.confidenceScore > $1.confidenceScore }
                                let top = sorted.first!
                                Button {
                                    if sorted.count == 1 {
                                        selectedLabel = top
                                    } else {
                                        selectedCluster = cluster
                                    }
                                } label: {
                                    VStack(spacing: 2) {
                                        Image(systemName: top.systemImage)
                                            .font(.title2)
                                            .foregroundStyle(eventColor(for: top))
                                        Text(top.displayName)
                                            .font(.caption2)
                                            .lineLimit(1)
                                            .multilineTextAlignment(.center)
                                        Text(String(format: String(localized: "%lld events · top %@"), Int64(sorted.count), String(format: "%.0f%%", top.confidenceScore * 100)))
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                    .padding(6)
                                    .background(.background, in: RoundedRectangle(cornerRadius: 8))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .ignoresSafeArea(edges: .all)
                    .onAppear { fitRegionToAnnotations() }
                    .onChange(of: mesh.senderCoordinates.count) { _ in fitRegionToAnnotations() }
                    .onChange(of: mesh.identity.shareLocation) { _ in fitRegionToAnnotations() }
                    .onChange(of: mesh.mapLabels.count) { _ in fitRegionToAnnotations() }
                }

                // Compass: direction the user is pointed (magnetic heading)
                if let heading = headingProvider.headingDegrees {
                    VStack {
                        Spacer()
                        HStack {
                            Spacer()
                            CompassView(headingDegrees: heading)
                                .padding(.trailing, 16)
                                .padding(.bottom, 100)
                        }
                    }
                    .allowsHitTesting(false)
                }

                // Top controls: share toggle + offline + add label + recenter
                VStack(spacing: 12) {
                    HStack {
                        Toggle(isOn: shareLocationBinding) {
                            Label("Share location", systemImage: "location.fill")
                                .font(.subheadline.weight(.medium))
                        }
                        .toggleStyle(.button)
                        .tint(.accentColor)
                        Spacer()
                        Button {
                            recenterMap()
                        } label: {
                            Image(systemName: "location.circle.fill")
                                .font(.body)
                        }
                        .help("Recenter map on your location")
                        Button {
                            if mesh.mapLabelCooldownRemaining > 0 {
                                showCooldownAlert = true
                            } else if !isWithinPlacementRange(region.center) {
                                showTooFarAlert = true
                            } else {
                                showAddLabelSheet = true
                            }
                        } label: {
                            if mesh.mapLabelCooldownRemaining > 0 {
                                Text("\(Int(ceil(mesh.mapLabelCooldownRemaining)))s")
                                    .font(.caption.monospacedDigit())
                            } else {
                                Image(systemName: "mappin.circle.fill")
                                    .font(.body)
                            }
                        }
                        .disabled(mesh.mapLabelCooldownRemaining > 0)
                        Button {
                            showOfflineInfo = true
                        } label: {
                            Image(systemName: "map.fill")
                                .font(.body)
                        }
                    }
                    .padding(10)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
                    .padding(.horizontal)
                    .padding(.top, 8)
                    Spacer()
                }
            }
            .navigationTitle("Map")
            .navigationBarTitleDisplayMode(.inline)
            .alert(String(localized: "Label cooldown"), isPresented: $showCooldownAlert) {
                Button(String(localized: "OK"), role: .cancel) {}
            } message: {
                Text(String(format: String(localized: "Please wait %lld seconds before placing another label."), Int64(ceil(mesh.mapLabelCooldownRemaining))))
            }
            .alert(String(localized: "Too far"), isPresented: $showTooFarAlert) {
                Button(String(localized: "OK"), role: .cancel) {}
            } message: {
                Text(String(localized: "Place event labels within 5 km of your current location. Turn on Share location and move closer."))
            }
            .sheet(isPresented: $showOfflineInfo) {
                OfflineMapSheet(isCaching: $isCaching, region: region, onCache: cacheCurrentRegion)
            }
            .sheet(isPresented: $showAddLabelSheet) {
                AddLabelSheet(regionCenter: region.center, eventTypesConfig: eventTypesManager.config) { category, customName, customDescription, iconName, thumbnailData in
                    if let data = thumbnailData {
                        _ = mesh.sendMapLabelWithThumbnail(
                            category: category,
                            lat: region.center.latitude,
                            lon: region.center.longitude,
                            customLabelName: customName,
                            customDescription: customDescription,
                            customSystemImage: iconName,
                            jpegData: data
                        )
                    } else {
                        _ = mesh.sendMapLabel(
                            category: category,
                            lat: region.center.latitude,
                            lon: region.center.longitude,
                            customLabelName: customName,
                            customDescription: customDescription,
                            customSystemImage: iconName
                        )
                    }
                    showAddLabelSheet = false
                } onCancel: {
                    showAddLabelSheet = false
                }
            }
            .sheet(item: $selectedLabel) { record in
                LabelVoteSheet(
                    record: record,
                    myVote: mesh.labelVotes[record.id]?[mesh.identity.deviceID],
                    canDelete: true,
                    onVote: { up in
                        mesh.voteForLabel(labelId: record.id, up: up)
                    },
                    onDelete: {
                        mesh.removeMapLabel(id: record.id)
                        selectedLabel = nil
                    },
                    selectedLabel: $selectedLabel
                )
            }
            .sheet(item: $selectedCluster) { cluster in
                ClusterListSheet(
                    cluster: cluster,
                    onSelectRecord: { record in
                        selectedLabel = record
                    },
                    selectedCluster: $selectedCluster
                )
            }
        }
    }

    /// Binding that updates identity via existing updateIdentity (no change to identity logic).
    private var shareLocationBinding: Binding<Bool> {
        Binding(
            get: { mesh.identity.shareLocation },
            set: { newValue in
                var id = mesh.identity
                id.shareLocation = newValue
                mesh.updateIdentity(id)
            }
        )
    }

    /// Preload/cache current map region for better offline use (MapKit caches tiles when rendered).
    private func cacheCurrentRegion() {
        guard !isCaching else { return }
        isCaching = true
        let options = MKMapSnapshotter.Options()
        options.region = region
        options.size = CGSize(width: 512, height: 512)
        let snapshotter = MKMapSnapshotter(options: options)
        snapshotter.start { [self] _, _ in
            DispatchQueue.main.async { isCaching = false }
        }
    }

    private func fitRegionToAnnotations() {
        guard !combinedAnnotations.isEmpty else { return }
        let coords = combinedAnnotations.map(\.coordinate)
        let lats = coords.map(\.latitude)
        let lons = coords.map(\.longitude)
        let minLat = lats.min() ?? 0
        let maxLat = lats.max() ?? 0
        let minLon = lons.min() ?? 0
        let maxLon = lons.max() ?? 0
        let center = CLLocationCoordinate2D(
            latitude: (minLat + maxLat) / 2,
            longitude: (minLon + maxLon) / 2
        )
        let span = MKCoordinateSpan(
            latitudeDelta: max(0.005, (maxLat - minLat) * 1.4),
            longitudeDelta: max(0.005, (maxLon - minLon) * 1.4)
        )
        region = MKCoordinateRegion(center: center, span: span)
    }

    /// Recenter map on user location, or fit all if no location.
    private func recenterMap() {
        if let my = mesh.lastKnownLocation {
            region = MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: my.lat, longitude: my.lon),
                span: Self.defaultSpan
            )
        } else {
            fitRegionToAnnotations()
        }
    }

    /// Color for event pin: redder = more valid votes (higher confidence score).
    private func eventColor(for record: MapLabelRecord) -> Color {
        let score = record.confidenceScore
        // 0 → green, 0.5 → yellow/orange, 1 → red
        let red = min(1, score * 2)
        let green = min(1, (1 - score) * 2)
        return Color(red: red, green: green, blue: 0.2)
    }

    private func relativeTime(_ date: Date) -> String {
        let s = Date().timeIntervalSince(date)
        if s < 60 { return String(localized: "now") }
        if s < 3600 { return String(format: String(localized: "%lldm ago"), Int64(s / 60)) }
        if s < 86400 { return String(format: String(localized: "%lldh ago"), Int64(s / 3600)) }
        return String(format: String(localized: "%lldd ago"), Int64(s / 86400))
    }
}

/// One pin on the map (remote transmitter or current user).
private struct TransmitterPin: Identifiable {
    let id: String
    let coordinate: CLLocationCoordinate2D
    let displayName: String
    let isCurrentUser: Bool
}

/// Unified map annotation: transmitter or clustered labels.
private enum MapAnnotationItem: Identifiable {
    case transmitter(TransmitterPin)
    case labelCluster(LabelCluster)

    var id: String {
        switch self {
        case .transmitter(let p): return "tx-\(p.id)"
        case .labelCluster(let c): return "cluster-\(c.id.uuidString)"
        }
    }

    var coordinate: CLLocationCoordinate2D {
        switch self {
        case .transmitter(let p): return p.coordinate
        case .labelCluster(let c): return c.coordinate
        }
    }
}

/// Cluster of nearby labels that share one pin.
private struct LabelCluster: Identifiable {
    let id: UUID
    var coordinate: CLLocationCoordinate2D
    var records: [MapLabelRecord]
}

// MARK: - Compass (direction user is pointed)

/// Shows device heading: arrow points in the direction the user is facing (0° = North).
private struct CompassView: View {
    let headingDegrees: Double
    var body: some View {
        ZStack {
            Circle()
                .fill(.ultraThinMaterial)
                .frame(width: 56, height: 56)
            // Arrow points upward when facing North; rotate so North is at top
            Image(systemName: "location.north.fill")
                .font(.title)
                .foregroundStyle(.blue)
                .rotationEffect(.degrees(-headingDegrees))
            Circle()
                .strokeBorder(.secondary, lineWidth: 1)
                .frame(width: 56, height: 56)
        }
        .overlay(alignment: .top) {
            Text(String(localized: "N"))
                .font(.system(size: 10, weight: .bold))
                .offset(y: -28)
        }
    }
}

// MARK: - Device heading provider (no change to mesh; map-only)

/// Provides device magnetic heading for compass. Uses its own CLLocationManager for heading only.
private final class LocationHeadingProvider: NSObject, ObservableObject {
    @Published private(set) var headingDegrees: Double?
    private let manager = CLLocationManager()

    override init() {
        super.init()
        manager.delegate = self
        manager.headingFilter = 5
        if CLLocationManager.headingAvailable() {
            manager.startUpdatingHeading()
        }
    }

    deinit {
        manager.stopUpdatingHeading()
    }
}

extension LocationHeadingProvider: CLLocationManagerDelegate {
    func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        guard newHeading.headingAccuracy >= 0 else { return }
        DispatchQueue.main.async { [weak self] in
            self?.headingDegrees = newHeading.trueHeading >= 0 ? newHeading.trueHeading : newHeading.magneticHeading
        }
    }
}

// MARK: - Add label (event type + optional custom name/description)

private struct AddLabelSheet: View {
    let regionCenter: CLLocationCoordinate2D
    let eventTypesConfig: EventTypesConfig
    let onSelect: (LabelCategory, String?, String?, String?, Data?) -> Void
    let onCancel: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var customName = ""
    @State private var customDescription = ""
    @State private var selectedCategory: LabelCategory?
    @State private var selectedIcon: String?
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var selectedThumbnailData: Data?

    private func displayName(for category: LabelCategory) -> String {
        switch category {
        case .hazard: return eventTypesConfig.hazard.name
        case .help: return eventTypesConfig.help.name
        case .other: return eventTypesConfig.other.name
        default: return category.displayName
        }
    }

    private func displayDescription(for category: LabelCategory) -> String {
        switch category {
        case .hazard: return eventTypesConfig.hazard.description
        case .help: return eventTypesConfig.help.description
        case .other: return eventTypesConfig.other.description
        default: return ""
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Place a label at the current map center. Set a name and description; others can vote on validity.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Section("Event type") {
                    ForEach(LabelCategory.configurableEventTypes, id: \.rawValue) { category in
                        Button {
                            selectedCategory = category
                        } label: {
                            HStack {
                                Image(systemName: category.systemImage)
                                Text(displayName(for: category))
                                if selectedCategory == category {
                                    Spacer()
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.green)
                                }
                            }
                        }
                    }
                }
                if selectedCategory != nil {
                    Section("Icon") {
                        let icons = ["exclamationmark.triangle.fill", "flame.fill", "car.fill", "bandage.fill", "cross.case.fill", "phone.fill", "questionmark.circle.fill", "figure.wave"]
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 12) {
                                ForEach(icons, id: \.self) { name in
                                    Button {
                                        selectedIcon = name
                                    } label: {
                                        Image(systemName: name)
                                            .font(.title2)
                                            .padding(8)
                                            .background(
                                                Circle()
                                                    .strokeBorder(selectedIcon == name ? Color.accentColor : Color.secondary.opacity(0.3), lineWidth: selectedIcon == name ? 2 : 1)
                                            )
                                    }
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                    Section("Label name (optional)") {
                        TextField("Custom name", text: $customName)
                    }
                    Section("Description (optional)") {
                        TextField("Description", text: $customDescription, axis: .vertical)
                            .lineLimit(2...4)
                    }
                    Section("Photo (optional)") {
                        VStack(alignment: .leading, spacing: 8) {
                            PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                                Label(selectedThumbnailData == nil ? "Add photo" : "Change photo", systemImage: "photo")
                            }
                            if let data = selectedThumbnailData, let image = UIImage(data: data) {
                                Image(uiImage: image)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(maxHeight: 120)
                                    .cornerRadius(8)
                            } else {
                                Text("Small, low‑res image for situational awareness.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Add label")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        onCancel()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Place") {
                        guard let cat = selectedCategory else { return }
                        onSelect(
                            cat,
                            customName.isEmpty ? nil : customName,
                            customDescription.isEmpty ? nil : customDescription,
                            selectedIcon,
                            selectedThumbnailData
                        )
                        dismiss()
                    }
                    .disabled(selectedCategory == nil)
                }
            }
            .onChange(of: selectedPhotoItem) { newItem in
                guard let item = newItem else { return }
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self),
                       let thumb = prepareThumbnailData(from: data) {
                        await MainActor.run {
                            self.selectedThumbnailData = thumb
                        }
                    }
                }
            }
        }
    }

    /// Downscale and compress to a small JPEG thumbnail suitable for mesh transfer.
    private func prepareThumbnailData(from data: Data) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        let maxDimension: CGFloat = 200
        let size = image.size
        let scale = min(maxDimension / max(size.width, size.height), 1)
        let targetSize = CGSize(width: size.width * scale, height: size.height * scale)

        UIGraphicsBeginImageContextWithOptions(targetSize, true, 1)
        image.draw(in: CGRect(origin: .zero, size: targetSize))
        let resized = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()

        guard let finalImage = resized else { return nil }
        return finalImage.jpegData(compressionQuality: 0.35)
    }
}

// MARK: - Label detail & vote (confidence score)

private struct LabelVoteSheet: View {
    let record: MapLabelRecord
    let myVote: Int?
    let canDelete: Bool
    let onVote: (Bool) -> Void
    let onDelete: () -> Void
    @Binding var selectedLabel: MapLabelRecord?
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var mesh: BluetoothMeshService

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label(record.displayName, systemImage: record.category.systemImage)
                        .font(.headline)
                    if let data = mesh.thumbnails[record.id], let image = UIImage(data: data) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(maxHeight: 160)
                            .cornerRadius(8)
                            .padding(.vertical, 4)
                    }
                    if let desc = record.customDescription, !desc.isEmpty {
                        Text(desc)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Text(String(format: String(localized: "By %@"), record.senderName))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(record.date.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Section("Confidence (votes)") {
                    HStack {
                        Text("Score")
                        Spacer()
                        Text(String(format: "%.0f%%", record.confidenceScore * 100))
                            .fontWeight(.medium)
                    }
                    HStack {
                        Text("↑ Valid")
                        Spacer()
                        Text("\(record.upVotes)")
                    }
                    HStack {
                        Text("↓ Not valid")
                        Spacer()
                        Text("\(record.downVotes)")
                    }
                }
                Section("Your vote") {
                    HStack(spacing: 20) {
                        Button {
                            onVote(true)
                        } label: {
                            Label("Valid", systemImage: "hand.thumbsup.fill")
                                .foregroundStyle(myVote == 1 ? .green : .secondary)
                        }
                        .buttonStyle(.borderless)
                        Button {
                            onVote(false)
                        } label: {
                            Label("Not valid", systemImage: "hand.thumbsdown.fill")
                                .foregroundStyle(myVote == -1 ? .red : .secondary)
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
            .navigationTitle("Label")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if canDelete {
                        Button(role: .destructive) {
                            onDelete()
                            dismiss()
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        selectedLabel = nil
                    }
                }
            }
        }
    }
}

/// Shows all labels in a cluster, ranked by confidence score.
private struct ClusterListSheet: View {
    let cluster: LabelCluster
    let onSelectRecord: (MapLabelRecord) -> Void
    @Binding var selectedCluster: LabelCluster?
    @Environment(\.dismiss) private var dismiss

    private var sortedRecords: [MapLabelRecord] {
        cluster.records.sorted { $0.confidenceScore > $1.confidenceScore }
    }

    private func rowColor(for record: MapLabelRecord) -> Color {
        let score = record.confidenceScore
        let red = min(1, score * 2)
        let green = min(1, (1 - score) * 2)
        return Color(red: red, green: green, blue: 0.2)
    }

    private func relativeTime(_ date: Date) -> String {
        let s = Date().timeIntervalSince(date)
        if s < 60 { return String(localized: "now") }
        if s < 3600 { return String(format: String(localized: "%lldm ago"), Int64(s / 60)) }
        if s < 86400 { return String(format: String(localized: "%lldh ago"), Int64(s / 3600)) }
        return String(format: String(localized: "%lldd ago"), Int64(s / 86400))
    }

    var body: some View {
        NavigationStack {
            List {
                Section(String(localized: "Events near this location")) {
                    ForEach(sortedRecords, id: \.id) { record in
                        Button {
                            onSelectRecord(record)
                            dismiss()
                        } label: {
                            HStack {
                                Image(systemName: record.systemImage)
                                    .foregroundStyle(rowColor(for: record))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(record.displayName)
                                    if let desc = record.customDescription, !desc.isEmpty {
                                        Text(desc)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Text("\(relativeTime(record.date)) · \(String(format: "%.0f%%", record.confidenceScore * 100))")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Nearby events")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        selectedCluster = nil
                    }
                }
            }
        }
    }
}

// MARK: - Offline map info & cache

private struct OfflineMapSheet: View {
    @Binding var isCaching: Bool
    let region: MKCoordinateRegion
    let onCache: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Map tiles are cached as you pan and zoom. To preload the current area, tap below. For full offline use, download regions in the Apple Maps app: Settings → Maps → turn on Offline, or open Maps and download areas before going offline.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Section("This area") {
                    Button {
                        onCache()
                    } label: {
                        HStack {
                            Label("Cache current map area", systemImage: "square.and.arrow.down")
                            if isCaching {
                                Spacer()
                                ProgressView()
                            }
                        }
                    }
                    .disabled(isCaching)
                }
            }
            .navigationTitle("Offline maps")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

#Preview {
    MapTabView()
        .environmentObject(BluetoothMeshService())
}
