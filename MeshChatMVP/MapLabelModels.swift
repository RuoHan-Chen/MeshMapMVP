import Foundation

enum LabelCategory: String, Codable, CaseIterable, Identifiable {
    case hazard
    case resource
    case info
    case meeting
    case danger

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .hazard:   return "Hazard"
        case .resource: return "Resource"
        case .info:     return "Info"
        case .meeting:  return "Meeting"
        case .danger:   return "Danger"
        }
    }

    var systemImage: String {
        switch self {
        case .hazard:   return "exclamationmark.triangle.fill"
        case .resource: return "shippingbox.fill"
        case .info:     return "info.circle.fill"
        case .meeting:  return "person.2.fill"
        case .danger:   return "xmark.octagon.fill"
        }
    }
}

struct MapLabelPayload: Codable, Identifiable {
    var id: UUID
    var category: String
    var lat: Double
    var lon: Double
    var senderID: String
    var senderName: String
    var timestamp: UInt64
}

struct MapLabelVotePayload: Codable {
    var labelId: UUID
    var vote: Int
    var voterID: String
}
