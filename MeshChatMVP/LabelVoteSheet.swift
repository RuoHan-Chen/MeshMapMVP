import SwiftUI
import MapKit

// MARK: - Label detail & vote (confidence score)

struct LabelVoteSheet: View {
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
                ToolbarItem(placement: .cancellationAction) {
                    if canDelete {
                        Button(role: .destructive) {
                            onDelete()
                            dismiss()
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    } else {
                        Button("Close") {
                            dismiss()
                        }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        selectedLabel = nil
                        dismiss()
                    }
                }
            }
        }
    }
}

/// Shows all labels in a cluster, ranked by confidence score.
struct ClusterListSheet: View {
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

/// Cluster of nearby labels that share one pin.
struct LabelCluster: Identifiable {
    let id: UUID
    var coordinate: CLLocationCoordinate2D
    var records: [MapLabelRecord]
}
