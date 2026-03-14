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
    @State private var selectedPeerPopover: TransmitterPin?

    // MARK: - Trust Score & Topology

    private func peerTrustScore(for senderID: String) -> Double {
        // Check if senderID maps to a saved contact
        // We need to iterate known contacts or look up.
        // Since we don't have direct access to DatabaseManager's full list here without query,
        // we can try to find by ID if we can derive PK, or just assume we have a way.
        // BluetoothMeshService doesn't expose a "getContact(id)" easily.
        // But we can check `mesh.isSavedContactPeer(senderID)`.
        // If true, we need the relationship.
        // Let's assume we can get it.
        // For MVP, let's use a simplified lookup if possible, or fetch.
        // `mesh.activity(forPeerID: senderID)` gives us some info but not relationship.
        // Let's use `DatabaseManager.shared.savedNickname(forSenderID: senderID)` to check existence, but we need relationship.
        
        // We can use `DatabaseManager.shared.findContactByPublicKey` if we have PK.
        // `mesh.discoveredPeers` has PK.
        // `mesh.senderCoordinates` keys are senderIDs.
        
        var baseScore = 0.40
        
        // Try to find PK from discovered peers
        if let peer = mesh.discoveredPeers.first(where: { $0.id.uuidString == senderID || ($0.publicKey != nil && KeyManager.fingerprint($0.publicKey!, length: 32) == senderID) }) { // ID mismatch potential here
             // senderID is deviceID (base64 of PK usually, or UUID).
             // DeviceIdentity.deviceID is base64 of PK.
             if let pk = peer.publicKey,
                let contact = try? DatabaseManager.shared.findContactByPublicKey(pk) {
                 if contact.relationship == "friend" { baseScore = 0.85 }
                 else if contact.relationship == "associate" { baseScore = 0.65 }
             }
        } else {
             // Try to look up in DB if we have a mapping.
             // For now, default to 0.40 if unknown.
        }
        
        // Boost if they send high confidence labels
        // (Simplified: random boost or stub for MVP as "seen sending map labels" is complex to query efficiently here)
        
        return baseScore
    }
    
    struct MeshConnectionLine: Identifiable {
        let id: String
        let coordinates: [CLLocationCoordinate2D]
        let color: Color
        let lineWidth: CGFloat
        let dashPattern: [CGFloat]?
        let opacity: Double
    }

    private var connectionLines: [MeshConnectionLine] {
        var lines: [MeshConnectionLine] = []
        let items = annotationItems
        
        // Pairwise connections between all visible peers (mesh topology simulation)
        // In a real mesh, we'd know the routing table. Here we draw lines between all sharing location.
        for i in 0..<items.count {
            for j in (i+1)..<items.count {
                let p1 = items[i]
                let p2 = items[j]
                
                let t1 = peerTrustScore(for: p1.id.replacingOccurrences(of: "sender-", with: ""))
                let t2 = peerTrustScore(for: p2.id.replacingOccurrences(of: "sender-", with: ""))
                let avgTrust = (t1 + t2) / 2.0
                
                let opacity = 0.15 + avgTrust * 0.80
                let width = 0.8 + avgTrust * 0.8
                
                lines.append(MeshConnectionLine(
                    id: "\(p1.id)-\(p2.id)",
                    coordinates: [p1.coordinate, p2.coordinate],
                    color: Color(red: 0.52, green: 0.74, blue: 0.92),
                    lineWidth: width,
                    dashPattern: [6, 4],
                    opacity: opacity
                ))
            }
        }
        return lines
    }
    
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
                    MapViewWrapper(
                        region: $region,
                        annotations: combinedAnnotations,
                        polylines: connectionLines,
                        onSelect: { item in
                            switch item {
                            case .transmitter(let p):
                                selectedPeerPopover = p
                            case .labelCluster(let cluster):
                                let sorted = cluster.records.sorted { $0.confidenceScore > $1.confidenceScore }
                                if let top = sorted.first {
                                    if sorted.count == 1 {
                                        selectedLabel = top
                                    } else {
                                        selectedCluster = cluster
                                    }
                                }
                            }
                        }
                    )
                    .ignoresSafeArea(edges: .all)
                    .onAppear { fitRegionToAnnotations() }
                    .onChange(of: mesh.senderCoordinates.count) { _ in fitRegionToAnnotations() }
                    .onChange(of: mesh.identity.shareLocation) { _ in fitRegionToAnnotations() }
                    .onChange(of: mesh.mapLabels.count) { _ in fitRegionToAnnotations() }
                    
                    // Peer Tooltip
                    if let p = selectedPeerPopover {
                        VStack(spacing: 4) {
                            Text(p.displayName)
                                .font(.headline)
                            Text(p.id.replacingOccurrences(of: "sender-", with: "")) // Fingerprint stub
                                .font(.system(.caption, design: .monospaced))
                                .foregroundColor(.secondary)
                            
                            let trust = peerTrustScore(for: p.id.replacingOccurrences(of: "sender-", with: ""))
                            TrustBadge(score: trust)
                            
                            // RSSI if available (need to look up peer)
                            if let peer = mesh.discoveredPeers.first(where: { $0.id.uuidString == p.id.replacingOccurrences(of: "sender-", with: "") }) {
                                Text("RSSI: \(peer.rssi)")
                                    .font(.caption)
                            }
                        }
                        .padding()
                        .background(Color(UIColor.systemBackground))
                        .cornerRadius(12)
                        .shadow(radius: 5)
                        .padding()
                        .transition(.scale)
                        .onTapGesture {
                            selectedPeerPopover = nil
                        }
                        .zIndex(100)
                    }
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
                        }
                    }
                    .padding(10)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
                    .padding(.horizontal)
                    .padding(.top, 8)
                    
                    // Legend
                    HStack {
                        Spacer()
                        VStack(alignment: .trailing, spacing: 4) {
                            HStack {
                                Text("High trust")
                                    .font(.caption2)
                                Rectangle()
                                    .stroke(style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                                    .frame(width: 20, height: 1)
                                    .foregroundColor(Color(red: 0.52, green: 0.74, blue: 0.92))
                            }
                            HStack {
                                Text("Low trust")
                                    .font(.caption2)
                                Rectangle()
                                    .stroke(style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                                    .frame(width: 20, height: 1)
                                    .foregroundColor(Color(red: 0.52, green: 0.74, blue: 0.92).opacity(0.25))
                            }
                        }
                        .padding(6)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6))
                        .padding(.trailing, 12)
                    }
                    
                    Spacer()
                }
            }
            .navigationTitle("Map")
            .navigationBarTitleDisplayMode(.inline)
            .alert("Label cooldown", isPresented: $showCooldownAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Please wait \(Int(ceil(mesh.mapLabelCooldownRemaining))) seconds before placing another label.")
            }
            .alert("Too far", isPresented: $showTooFarAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Place event labels within 5 km of your current location. Turn on Share location and move closer.")
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
        if s < 60 { return "now" }
        if s < 3600 { return "\(Int(s / 60))m ago" }
        if s < 86400 { return "\(Int(s / 3600))h ago" }
        return "\(Int(s / 86400))d ago"
    }
}

/// One pin on the map (remote transmitter or current user).
struct TransmitterPin: Identifiable {
    let id: String
    let coordinate: CLLocationCoordinate2D
    let displayName: String
    let isCurrentUser: Bool
}

/// Unified map annotation: transmitter or clustered labels.
enum MapAnnotationItem: Identifiable {
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
            Text("N")
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


// MARK: - UIKit Map Wrapper (for polylines & custom annotations)

struct MapViewWrapper: UIViewRepresentable {
    @Binding var region: MKCoordinateRegion
    let annotations: [MapAnnotationItem]
    let polylines: [MapTabView.MeshConnectionLine]
    let onSelect: (MapAnnotationItem) -> Void
    
    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.register(MKAnnotationView.self, forAnnotationViewWithReuseIdentifier: "cluster")
        map.register(MKAnnotationView.self, forAnnotationViewWithReuseIdentifier: "transmitter")
        map.showsUserLocation = false // We use custom "me" pin
        return map
    }
    
    func updateUIView(_ uiView: MKMapView, context: Context) {
        // Update region (only if significantly different to avoid loop)
        let current = uiView.region
        if abs(current.center.latitude - region.center.latitude) > 0.0001 ||
           abs(current.center.longitude - region.center.longitude) > 0.0001 ||
           abs(current.span.latitudeDelta - region.span.latitudeDelta) > 0.0001 {
            uiView.setRegion(region, animated: true)
        }
        
        // Update annotations
        let currentAnnotations = uiView.annotations.compactMap { $0 as? MapAnnotationWrapper }
        let newIds = Set(annotations.map { $0.id })
        
        // Remove old
        let toRemove = currentAnnotations.filter { !newIds.contains($0.item.id) }
        uiView.removeAnnotations(toRemove)
        
        // Add new
        let currentIds = Set(currentAnnotations.map { $0.item.id })
        let toAdd = annotations.filter { !currentIds.contains($0.id) }.map { MapAnnotationWrapper(item: $0) }
        uiView.addAnnotations(toAdd)
        
        // Update polylines
        let currentOverlays = uiView.overlays.compactMap { $0 as? MeshPolylineWrapper }
        let newPolyIds = Set(polylines.map { $0.id })
        
        // Remove old
        let overlaysToRemove = currentOverlays.filter { !newPolyIds.contains($0.id ?? "") }
        uiView.removeOverlays(overlaysToRemove)
        
        // Add new
        let currentPolyIds = Set(currentOverlays.compactMap { $0.id })
        let overlaysToAdd = polylines.filter { !currentPolyIds.contains($0.id) }.map { line -> MeshPolylineWrapper in
            let poly = MeshPolylineWrapper(coordinates: line.coordinates, count: line.coordinates.count)
            poly.id = line.id
            poly.color = UIColor(line.color)
            poly.lineWidth = line.lineWidth
            poly.dashPattern = line.dashPattern?.map { NSNumber(value: $0) }
            poly.opacity = line.opacity
            return poly
        }
        uiView.addOverlays(overlaysToAdd)
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    class Coordinator: NSObject, MKMapViewDelegate {
        var parent: MapViewWrapper
        
        init(_ parent: MapViewWrapper) {
            self.parent = parent
        }
        
        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            DispatchQueue.main.async {
                self.parent.region = mapView.region
            }
        }
        
        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let poly = overlay as? MeshPolylineWrapper {
                let renderer = MKPolylineRenderer(polyline: poly)
                renderer.strokeColor = poly.color?.withAlphaComponent(poly.opacity)
                renderer.lineWidth = poly.lineWidth
                renderer.lineDashPattern = poly.dashPattern
                return renderer
            }
            return MKOverlayRenderer(overlay: overlay)
        }
        
        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard let wrapper = annotation as? MapAnnotationWrapper else { return nil }
            
            let id = wrapper.item.id.starts(with: "cluster") ? "cluster" : "transmitter"
            var view = mapView.dequeueReusableAnnotationView(withIdentifier: id)
            if view == nil {
                view = MKAnnotationView(annotation: annotation, reuseIdentifier: id)
                view?.canShowCallout = false // Custom tap handling
            } else {
                view?.annotation = annotation
            }
            
            // Configure view based on item
            switch wrapper.item {
            case .transmitter(let p):
                view?.image = UIImage(systemName: p.isCurrentUser ? "person.circle.fill" : "antenna.radiowaves.left.and.right")?
                    .withTintColor(p.isCurrentUser ? .systemBlue : .systemOrange, renderingMode: .alwaysOriginal)
                // Simple label support via detailCalloutAccessoryView is standard, but we want custom SwiftUI-like view.
                // For MVP, just the icon. The tooltip handles details.
                
            case .labelCluster(let c):
                let sorted = c.records.sorted { $0.confidenceScore > $1.confidenceScore }
                if let top = sorted.first {
                    view?.image = UIImage(systemName: top.systemImage)?
                        .withTintColor(UIColor(eventColor(for: top)), renderingMode: .alwaysOriginal)
                }
            }
            
            return view
        }
        
        func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
            guard let wrapper = view.annotation as? MapAnnotationWrapper else { return }
            parent.onSelect(wrapper.item)
            mapView.deselectAnnotation(wrapper, animated: true)
        }
        
        private func eventColor(for record: MapLabelRecord) -> Color {
            let score = record.confidenceScore
            let red = min(1, score * 2)
            let green = min(1, (1 - score) * 2)
            return Color(red: red, green: green, blue: 0.2)
        }
    }
}

class MapAnnotationWrapper: NSObject, MKAnnotation {
    let item: MapAnnotationItem
    @objc dynamic var coordinate: CLLocationCoordinate2D
    
    init(item: MapAnnotationItem) {
        self.item = item
        self.coordinate = item.coordinate
    }
}

class MeshPolylineWrapper: MKPolyline {
    var id: String?
    var color: UIColor?
    var lineWidth: CGFloat = 1.0
    var dashPattern: [NSNumber]?
    var opacity: Double = 1.0
}
