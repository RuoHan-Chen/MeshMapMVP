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
                if annotationItems.isEmpty {
                    Map(coordinateRegion: $region)
                        .ignoresSafeArea(edges: .all)
                    VStack(spacing: 8) {
                        Text("No transmitter positions yet")
                            .font(.headline)
                        Text("Turn on \"Share location\" below. Positions appear when peers share coordinates.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }
                    .padding(.top, 60)
                } else {
                    Map(coordinateRegion: $region, annotationItems: annotationItems) { item in
                        MapAnnotation(coordinate: item.coordinate) {
                            VStack(spacing: 2) {
                                Image(systemName: item.isCurrentUser ? "person.circle.fill" : "antenna.radiowaves.left.and.right")
                                    .font(.title2)
                                    .foregroundStyle(item.isCurrentUser ? .blue : .orange)
                                Text(item.displayName)
                                    .font(.caption2)
                                    .lineLimit(1)
                            }
                            .padding(6)
                            .background(.background, in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                    .ignoresSafeArea(edges: .all)
                    .onAppear { fitRegionToAnnotations() }
                    .onChange(of: mesh.senderCoordinates.count) { _ in fitRegionToAnnotations() }
                    .onChange(of: mesh.identity.shareLocation) { _ in fitRegionToAnnotations() }
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

                // Top controls: share toggle + offline
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
            .sheet(isPresented: $showOfflineInfo) {
                OfflineMapSheet(isCaching: $isCaching, region: region, onCache: cacheCurrentRegion)
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
        guard !annotationItems.isEmpty else { return }
        let coords = annotationItems.map(\.coordinate)
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
