import SwiftUI
import MapKit
import CoreLocation

/// Map tab: shows positions of transmitters using existing coordinate exchange data.
/// Reads only from mesh.lastKnownLocation, mesh.senderCoordinates, mesh.announceNicknames, mesh.identity.
struct MapTabView: View {
    @EnvironmentObject var mesh: BluetoothMeshService
    @StateObject private var headingProvider = LocationHeadingProvider()

    private static let defaultCenter = CLLocationCoordinate2D(latitude: -33.8688, longitude: 151.2093)
    private static let defaultSpan = MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)

    @State private var region = MKCoordinateRegion(
        center: defaultCenter,
        span: defaultSpan
    )
    @State private var showOfflineInfo = false
    @State private var isCaching = false
    @State private var showAddLabelSheet = false
    @State private var showCooldownAlert = false
    @State private var selectedLabel: MapLabelRecord?

    /// Labels built from mesh.mapLabels + mesh.labelVotes for display and voting.
    private var labelRecords: [MapLabelRecord] {
        mesh.mapLabels.map { id, payload in
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
                downVotes: downVotes
            )
        }
    }

    /// Combined annotations: transmitters + labels (single list for Map).
    private var combinedAnnotations: [MapAnnotationItem] {
        let transmitterItems = annotationItems.map { MapAnnotationItem.transmitter($0) }
        let labelItems = labelRecords.map { MapAnnotationItem.label($0) }
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
                            case .label(let record):
                                Button {
                                    selectedLabel = record
                                } label: {
                                    VStack(spacing: 2) {
                                        Image(systemName: record.category.systemImage)
                                            .font(.title2)
                                            .foregroundStyle(.red)
                                        Text(record.category.displayName)
                                            .font(.caption2)
                                            .lineLimit(1)
                                            .multilineTextAlignment(.center)
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

                // Top controls: share toggle + offline + add label
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
                            if mesh.mapLabelCooldownRemaining > 0 {
                                showCooldownAlert = true
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
            .alert("Label cooldown", isPresented: $showCooldownAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Please wait \(Int(ceil(mesh.mapLabelCooldownRemaining))) seconds before placing another label.")
            }
            .sheet(isPresented: $showOfflineInfo) {
                OfflineMapSheet(isCaching: $isCaching, region: region, onCache: cacheCurrentRegion)
            }
            .sheet(isPresented: $showAddLabelSheet) {
                AddLabelSheet(regionCenter: region.center) { category in
                    mesh.sendMapLabel(category: category, lat: region.center.latitude, lon: region.center.longitude)
                    showAddLabelSheet = false
                } onCancel: {
                    showAddLabelSheet = false
                }
            }
            .sheet(item: $selectedLabel) { record in
                LabelVoteSheet(
                    record: record,
                    myVote: mesh.labelVotes[record.id]?[mesh.identity.deviceID],
                    onVote: { up in
                        mesh.voteForLabel(labelId: record.id, up: up)
                    },
                    selectedLabel: $selectedLabel
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
}

/// One pin on the map (remote transmitter or current user).
private struct TransmitterPin: Identifiable {
    let id: String
    let coordinate: CLLocationCoordinate2D
    let displayName: String
    let isCurrentUser: Bool
}

/// Unified map annotation: transmitter or label (for single Map annotationItems array).
private enum MapAnnotationItem: Identifiable {
    case transmitter(TransmitterPin)
    case label(MapLabelRecord)

    var id: String {
        switch self {
        case .transmitter(let p): return "tx-\(p.id)"
        case .label(let l): return "label-\(l.id.uuidString)"
        }
    }

    var coordinate: CLLocationCoordinate2D {
        switch self {
        case .transmitter(let p): return p.coordinate
        case .label(let l): return l.coordinate
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

// MARK: - Add label (category picker)

private struct AddLabelSheet: View {
    let regionCenter: CLLocationCoordinate2D
    let onSelect: (LabelCategory) -> Void
    let onCancel: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Text("Place a label at the current map center. Others can vote on validity.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                ForEach(LabelCategory.allCases, id: \.rawValue) { category in
                    Button {
                        onSelect(category)
                        dismiss()
                    } label: {
                        Label(category.displayName, systemImage: category.systemImage)
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
            }
        }
    }
}

// MARK: - Label detail & vote (confidence score)

private struct LabelVoteSheet: View {
    let record: MapLabelRecord
    let myVote: Int?
    let onVote: (Bool) -> Void
    @Binding var selectedLabel: MapLabelRecord?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label(record.category.displayName, systemImage: record.category.systemImage)
                        .font(.headline)
                    Text("By \(record.senderName)")
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
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        selectedLabel = nil
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
