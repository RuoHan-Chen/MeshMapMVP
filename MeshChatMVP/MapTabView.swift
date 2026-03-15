import SwiftUI
import MapKit
import CoreLocation
import PhotosUI
import UIKit

/// Map tab: shows positions of transmitters using existing coordinate exchange data.
/// Reads only from mesh.lastKnownLocation, mesh.senderCoordinates, mesh.announceNicknames, mesh.identity.
struct MapTabView: View {
    @EnvironmentObject var mesh: BluetoothMeshService
    @StateObject private var eventTypesManager = EventTypesManager()

    private static let maxLabelDistanceMeters = 5_000.0

    @Binding var region: MKCoordinateRegion
    
    @State private var showAddLabelSheet = false
    @State private var showCooldownAlert = false
    @State private var showTooFarAlert = false
    @State private var selectedLabel: MapLabelRecord?
    @State private var selectedCluster: LabelCluster?
    @State private var showSOSAlert = false
    /// Cached trust inputs loaded from the database.
    @State private var labelRelationships: [String: String] = [:]
    @State private var labelSightings: [String: NodeSighting] = [:]

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
        let votes    = mesh.labelVotes[id] ?? [:]
        let category = LabelCategory(rawValue: payload.category) ?? .checkpoint
        let score    = AlertTrustEngine.scoreLabel(
            authorID:     payload.senderID,
            lat:          payload.lat,
            lon:          payload.lon,
            timestampMs:  payload.timestamp,
            votes:        votes,
            relationships: labelRelationships,
            sightings:    labelSightings,
            myDeviceID:   mesh.identity.deviceID
        )
        return MapLabelRecord(
            id: id,
            category: category,
            latitude: payload.lat,
            longitude: payload.lon,
            senderID: payload.senderID,
            senderName: payload.senderName,
            date: Date(timeIntervalSince1970: Double(payload.timestamp) / 1000),
            trustScore: score,
            voteCount: votes.count,
            customLabelName: payload.customLabelName,
            customDescription: payload.customDescription,
            customSystemImage: payload.customSystemImage
        )
    }

    /// Loads saved-contact relationships and node sightings from the DB for trust scoring.
    private func loadTrustData() {
        let currentLabels = mesh.mapLabels
        let currentVotes  = mesh.labelVotes
        DispatchQueue.global(qos: .utility).async {
            let contacts = (try? DatabaseManager.shared.listContacts()) ?? []
            var relationships: [String: String] = [:]
            for sc in contacts {
                let sid = DatabaseManager.canonicalSenderID(publicKey: sc.publicKey)
                relationships[sid] = sc.relationship
            }
            var nodeIDs = Set(currentLabels.values.map { $0.senderID })
            for votes in currentVotes.values { nodeIDs.formUnion(votes.keys) }
            var sightings: [String: NodeSighting] = [:]
            for nodeID in nodeIDs {
                if let s = try? DatabaseManager.shared.recentSightings(for: nodeID, limit: 1).first {
                    sightings[nodeID] = s
                }
            }
            DispatchQueue.main.async {
                labelRelationships = relationships
                labelSightings     = sightings
            }
        }
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

    /// Dynamic scale for annotations based on zoom level (span).
    /// Smaller scale when zoomed out (larger span).
    private var annotationScale: CGFloat {
        let span = region.span.latitudeDelta
        // Base span ~0.01 -> scale 1.0
        // Zoomed out -> scale down to ~0.4
        return max(0.4, min(1.0, 0.015 / span))
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
                        Text("Turn on \"Share location\" in Account to show your position. Tap \"+\" to place an incident label.")
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
                                .scaleEffect(annotationScale)
                                .animation(.easeInOut, value: annotationScale)
                            case .labelCluster(let cluster):
                                let sorted = cluster.records.sorted { $0.trustScore > $1.trustScore }
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
                                        Text(top.voteCount == 0 ? "\(sorted.count) events · Unverified" : "\(sorted.count) events · score \(String(format: "%.1f", top.trustScore))")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                    .padding(6)
                                    .background(.background, in: RoundedRectangle(cornerRadius: 8))
                                    .scaleEffect(annotationScale)
                                    .animation(.easeInOut, value: annotationScale)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .ignoresSafeArea(edges: .all)
                    .onAppear {
                        fitRegionToAnnotations()
                        loadTrustData()
                    }
                    // Disabled auto-fit on change to prevent zoom loop
                    // .onChange(of: mesh.senderCoordinates.count) { _ in fitRegionToAnnotations() }
                    // .onChange(of: mesh.identity.shareLocation) { _ in fitRegionToAnnotations() }
                    .onChange(of: mesh.mapLabels.count) { _ in
                        loadTrustData()
                    }
                }

                // Top Right Controls: SOS + Share
                VStack {
                    HStack {
                        Spacer()
                        Button {
                            showSOSAlert = true
                        } label: {
                            Text("SOS")
                                .font(.subheadline.weight(.bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(.red, in: RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                        
                        Button {
                            prepareAndShareMap()
                        } label: {
                            Image(systemName: "square.and.arrow.up")
                                .font(.body)
                                .padding(8)
                                .background(.ultraThinMaterial, in: Circle())
                        }
                        .help("Share map with outside world (events + member locations)")
                    }
                    .padding(.horizontal)
                    .padding(.top, 8)
                    Spacer()
                }
                
                // Bottom Right Controls: Add Label (+) + Recenter (Location Arrow)
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        VStack(spacing: 16) {
                            Button {
                                if mesh.mapLabelCooldownRemaining > 0 {
                                    showCooldownAlert = true
                                } else if !isWithinPlacementRange(region.center) {
                                    showTooFarAlert = true
                                } else {
                                    showAddLabelSheet = true
                                }
                            } label: {
                                ZStack {
                                    Circle()
                                        .fill(Color.blue)
                                        .frame(width: 56, height: 56)
                                        .shadow(radius: 4)
                                    if mesh.mapLabelCooldownRemaining > 0 {
                                        Text("\(Int(ceil(mesh.mapLabelCooldownRemaining)))")
                                            .font(.caption.monospacedDigit().bold())
                                            .foregroundStyle(.white)
                                    } else {
                                        Image(systemName: "plus")
                                            .font(.title.weight(.semibold))
                                            .foregroundStyle(.white)
                                    }
                                }
                            }
                            .disabled(mesh.mapLabelCooldownRemaining > 0)
                            
                            Button {
                                recenterMap()
                            } label: {
                                Image(systemName: "location.fill")
                                    .font(.title2)
                                    .padding(12)
                                    .background(.ultraThinMaterial, in: Circle())
                                    .shadow(radius: 2)
                            }
                            .help("Recenter map on your location")
                        }
                        .padding(.trailing, 16)
                        .padding(.bottom, 20) // Lift up from tab bar
                    }
                }
            }
            .navigationTitle("")
            .toolbar(.hidden, for: .navigationBar)
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
            .alert("Contact emergency services?", isPresented: $showSOSAlert) {
                Button("No", role: .cancel) {}
                Button("Yes", role: .destructive) {}
            } message: {
                Text("Dummy SOS button for prototype only. This does not call emergency services.")
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
                span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
            )
        } else {
            fitRegionToAnnotations()
        }
    }

    /// Build map export (events + network members) and present share sheet.
    /// Exports a single self-contained HTML file with an embedded Leaflet map and event photos.
    private func prepareAndShareMap() {
        let members = buildExportMembers()
        let events = buildExportEvents()

        // Build a lightweight JSON payload we embed as text in the HTML.
        var memberDicts: [[String: Any]] = []
        for m in members {
            memberDicts.append([
                "id": m.id,
                "name": m.name,
                "latitude": m.latitude,
                "longitude": m.longitude
            ])
        }

        var eventDicts: [[String: Any]] = []
        for e in events {
            var dict: [String: Any] = [
                "id": e.id,
                "name": e.name,
                "category": e.category,
                "latitude": e.latitude,
                "longitude": e.longitude,
                "date": e.date
            ]
            if let d = e.eventDescription { dict["description"] = d }
            if let icon = e.icon { dict["icon"] = icon }
            if let eventId = UUID(uuidString: e.id), let thumb = mesh.thumbnails[eventId] {
                dict["thumbnailDataURI"] = "data:image/jpeg;base64,\(thumb.base64EncodedString())"
            }
            eventDicts.append(dict)
        }

        let payload: [String: Any] = [
            "exporter": mesh.identity.nickname,
            "exportDate": ISO8601DateFormatter().string(from: Date()),
            "members": memberDicts,
            "events": eventDicts
        ]

        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let jsonString = String(data: data, encoding: .utf8) else { return }

        let html = """
        <!DOCTYPE html>
        <html>
        <head>
          <meta charset="utf-8" />
          <title>MeshMap Export</title>
          <meta name="viewport" content="width=device-width, initial-scale=1.0" />
          <link rel="stylesheet" href="https://unpkg.com/leaflet@1.9.4/dist/leaflet.css" />
          <style>
            html, body, #map { height: 100%; margin: 0; padding: 0; }
            .popup-img { max-width: 220px; display: block; margin-top: 4px; border-radius: 6px; }
          </style>
        </head>
        <body>
          <div id="map"></div>
          <pre id="mesh-data" style="display:none">
        \(jsonString)
          </pre>
          <script src="https://unpkg.com/leaflet@1.9.4/dist/leaflet.js"></script>
          <script>
            (function() {
              var pre = document.getElementById('mesh-data');
              if (!pre) { return; }
              var raw = pre.textContent || pre.innerText || '';
              var data;
              try {
                data = JSON.parse(raw);
              } catch (e) {
                console.error('Failed to parse mesh export data', e, raw);
                return;
              }

              var map = L.map('map');
              var bounds = null;

              function extendBounds(lat, lon) {
                if (!bounds) {
                  bounds = L.latLngBounds([lat, lon], [lat, lon]);
                } else {
                  bounds.extend([lat, lon]);
                }
              }

              (data.members || []).forEach(function(m) {
                var marker = L.marker([m.latitude, m.longitude]).addTo(map);
                marker.bindPopup('<strong>Member</strong><br/>' + (m.name || ''));
                extendBounds(m.latitude, m.longitude);
              });

              (data.events || []).forEach(function(e) {
                var html = '<strong>' + (e.name || e.category || 'Event') + '</strong>';
                if (e.category) {
                  html += '<br/><em>' + e.category + '</em>';
                }
                if (e.description) {
                  html += '<br/>' + e.description;
                }
                if (e.thumbnailDataURI) {
                  html += '<br/><img class="popup-img" src="' + e.thumbnailDataURI + '" alt="photo" />';
                }
                if (e.date) {
                  html += '<br/><small>' + e.date + '</small>';
                }
                var marker = L.marker([e.latitude, e.longitude]).addTo(map);
                marker.bindPopup(html);
                extendBounds(e.latitude, e.longitude);
              });

              if (bounds) {
                map.fitBounds(bounds.pad(0.2));
              } else {
                map.setView([0, 0], 2);
              }

              L.tileLayer('https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png', {
                maxZoom: 19,
                attribution: '&copy; OpenStreetMap contributors'
              }).addTo(map);
            })();
          </script>
        </body>
        </html>
        """

        let fileName = "meshmap-export-\(Date().timeIntervalSince1970).html"
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        do {
            try html.data(using: .utf8)?.write(to: temp)
            presentShareSheet(for: temp)
        } catch {
            // Could present an error; for now skip
        }
    }

    /// Present the iOS system share sheet for a given file URL.
    private func presentShareSheet(for url: URL) {
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let window = scene.windows.first(where: { $0.isKeyWindow }),
              let root = window.rootViewController else { return }
        let av = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        av.popoverPresentationController?.sourceView = window
        root.present(av, animated: true)
    }

    private func buildExportMembers() -> [MapExportMember] {
        var list: [MapExportMember] = []
        for (senderID, coords) in mesh.senderCoordinates {
            let name = mesh.announceNicknames[senderID] ?? String(senderID.prefix(8))
            list.append(MapExportMember(
                id: senderID,
                name: name,
                latitude: coords.lat,
                longitude: coords.lon
            ))
        }
        if mesh.identity.shareLocation, let my = mesh.lastKnownLocation {
            list.append(MapExportMember(
                id: mesh.identity.deviceID,
                name: mesh.identity.nickname,
                latitude: my.lat,
                longitude: my.lon
            ))
        }
        return list
    }

    private func buildExportEvents() -> [MapExportEvent] {
        labelRecords.map { record in
            let votes = mesh.labelVotes[record.id] ?? [:]
            let upVotes = votes.values.filter { $0 == 1 }.count
            let downVotes = votes.values.filter { $0 == -1 }.count
            return MapExportEvent(
                id: record.id.uuidString,
                category: record.category.rawValue,
                latitude: record.latitude,
                longitude: record.longitude,
                name: record.displayName,
                eventDescription: record.customDescription,
                icon: record.customSystemImage,
                date: ISO8601DateFormatter().string(from: record.date),
                upVotes: upVotes,
                downVotes: downVotes
            )
        }
    }

    /// Color for event pin: normalized trustScore — higher = greener (more trusted).
    private func eventColor(for record: MapLabelRecord) -> Color {
        // Normalize: 10 = self-authored baseline. >10 = vouched. <0 = denied.
        let normalized = max(0, min(1, record.trustScore / 10.0))
        let red   = min(1, (1 - normalized) * 2)
        let green = min(1, normalized * 2)
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

// MARK: - Map export (share with outside world)

private struct MapExportMember: Codable {
    let id: String
    let name: String
    let latitude: Double
    let longitude: Double
}

private struct MapExportEvent: Codable {
    let id: String
    let category: String
    let latitude: Double
    let longitude: Double
    let name: String
    let eventDescription: String?
    let icon: String?
    let date: String
    let upVotes: Int
    let downVotes: Int
}

private struct MapExport: Codable {
    let version: Int
    let exportDate: String
    let exporterName: String
    let members: [MapExportMember]
    let events: [MapExportEvent]
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
    @State private var addressString: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label(record.displayName, systemImage: record.category.systemImage)
                        .font(.headline)
                    
                    if let addr = addressString {
                        Text(addr)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

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
                    Text("By \(record.senderName)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(record.date.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Section("Trust Score") {
                    HStack {
                        Text("Score")
                        Spacer()
                        if record.voteCount == 0 {
                            Text("Unverified")
                                .fontWeight(.medium)
                                .foregroundStyle(.orange)
                        } else {
                            Text(String(format: "%.1f", record.trustScore))
                                .fontWeight(.medium)
                        }
                    }
                }
                Section("Your vote") {
                    if record.senderID == mesh.identity.deviceID {
                        Text("You can't vote on your own post.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
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
            }
            .navigationTitle("Alert")
            .navigationBarTitleDisplayMode(.inline)
            .task {
                let geocoder = CLGeocoder()
                let location = CLLocation(latitude: record.latitude, longitude: record.longitude)
                if let placemarks = try? await geocoder.reverseGeocodeLocation(location), let p = placemarks.first {
                    var parts: [String] = []
                    if let n = p.name { parts.append(n) }
                    if let t = p.thoroughfare { parts.append(t) }
                    if let l = p.locality { parts.append(l) }
                    addressString = parts.joined(separator: ", ")
                }
            }
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

/// Shows all labels in a cluster, ranked by trust score.
private struct ClusterListSheet: View {
    let cluster: LabelCluster
    let onSelectRecord: (MapLabelRecord) -> Void
    @Binding var selectedCluster: LabelCluster?
    @Environment(\.dismiss) private var dismiss

    private var sortedRecords: [MapLabelRecord] {
        cluster.records.sorted { $0.trustScore > $1.trustScore }
    }

    private func rowColor(for record: MapLabelRecord) -> Color {
        let normalized = max(0, min(1, record.trustScore / 10.0))
        let red   = min(1, (1 - normalized) * 2)
        let green = min(1, normalized * 2)
        return Color(red: red, green: green, blue: 0.2)
    }

    private func relativeTime(_ date: Date) -> String {
        let s = Date().timeIntervalSince(date)
        if s < 60 { return "now" }
        if s < 3600 { return "\(Int(s / 60))m ago" }
        if s < 86400 { return "\(Int(s / 3600))h ago" }
        return "\(Int(s / 86400))d ago"
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Events near this location") {
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
                                    Text(record.voteCount == 0 ? "\(relativeTime(record.date)) · Unverified" : "\(relativeTime(record.date)) · score \(String(format: "%.1f", record.trustScore))")
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

#Preview {
    ContentView()
        .environmentObject(BluetoothMeshService())
}