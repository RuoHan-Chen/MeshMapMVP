import SwiftUI
import MapKit

struct MapTabView: View {
    @EnvironmentObject var mesh: BluetoothMeshService
    @State private var region = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194),
        span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)
    )
    @State private var selectedCategory: LabelCategory = .info
    @State private var showingAddSheet = false

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottomTrailing) {
                Map(coordinateRegion: $region, annotationItems: Array(mesh.mapLabels.values)) { label in
                    MapAnnotation(coordinate: CLLocationCoordinate2D(latitude: label.lat, longitude: label.lon)) {
                        LabelAnnotationView(label: label, votes: mesh.labelVotes[label.id] ?? [:])
                    }
                }
                .ignoresSafeArea(edges: .top)

                Button {
                    showingAddSheet = true
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(.white, .blue)
                        .shadow(radius: 4)
                }
                .padding()
            }
            .navigationTitle("Map")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showingAddSheet) {
                AddLabelSheet(region: region) { category, lat, lon in
                    mesh.sendMapLabel(category: category, lat: lat, lon: lon)
                }
            }
            .onAppear {
                if let loc = mesh.lastKnownLocation {
                    region.center = CLLocationCoordinate2D(latitude: loc.lat, longitude: loc.lon)
                }
            }
        }
    }
}

private struct LabelAnnotationView: View {
    let label: MapLabelPayload
    let votes: [String: Int]
    @EnvironmentObject var mesh: BluetoothMeshService

    private var netVotes: Int {
        votes.values.reduce(0, +)
    }

    private var category: LabelCategory? {
        LabelCategory(rawValue: label.category)
    }

    var body: some View {
        VStack(spacing: 2) {
            Image(systemName: category?.systemImage ?? "mappin.circle.fill")
                .font(.title2)
                .foregroundStyle(netVotes < -2 ? .gray : .red)

            HStack(spacing: 4) {
                Button { mesh.voteForLabel(labelId: label.id, up: true) } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.caption)
                }
                Text("\(netVotes)")
                    .font(.caption2)
                    .bold()
                Button { mesh.voteForLabel(labelId: label.id, up: false) } label: {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.caption)
                }
            }
        }
    }
}

private struct AddLabelSheet: View {
    let region: MKCoordinateRegion
    let onAdd: (LabelCategory, Double, Double) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selected: LabelCategory = .info

    var body: some View {
        NavigationStack {
            Form {
                Section("Category") {
                    Picker("Type", selection: $selected) {
                        ForEach(LabelCategory.allCases) { cat in
                            Label(cat.displayName, systemImage: cat.systemImage)
                                .tag(cat)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
                Section("Location") {
                    Text("Will drop at map center: \(region.center.latitude, specifier: "%.4f"), \(region.center.longitude, specifier: "%.4f")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Add Label")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Drop") {
                        onAdd(selected, region.center.latitude, region.center.longitude)
                        dismiss()
                    }
                }
            }
        }
    }
}
