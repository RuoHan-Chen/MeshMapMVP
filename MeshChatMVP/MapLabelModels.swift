import Foundation
import CoreLocation

/// Category for user-placed map alerts (shared over mesh).
public enum LabelCategory: String, Codable, CaseIterable {
    case armedConflict = "armed_conflict"
    case explosion = "explosion"
    case drone = "drone"
    case militaryMovement = "military_movement"
    case policeCrackdown = "police_crackdown"
    case arrests = "arrests"
    case checkpoint = "checkpoint"

    public var displayName: String {
        switch self {
        case .armedConflict:    return "Armed Conflict / Gunfire"
        case .explosion:        return "Explosion / Bombing"
        case .drone:            return "Drone / Airstrike"
        case .militaryMovement: return "Military Movement"
        case .policeCrackdown:  return "Police Crackdown"
        case .arrests:          return "Arrests / Detention"
        case .checkpoint:       return "Checkpoint / Roadblock"
        }
    }

    public var systemImage: String {
        switch self {
        case .armedConflict:    return "exclamationmark.triangle.fill"
        case .explosion:        return "flame.fill"
        case .drone:            return "paperplane.fill"
        case .militaryMovement: return "person.3.fill"
        case .policeCrackdown:  return "shield.fill"
        case .arrests:          return "lock.fill"
        case .checkpoint:       return "minus.circle.fill"
        }
    }

    /// How long (seconds) before this alert type automatically fades from the map.
    public var expiryDuration: TimeInterval {
        switch self {
        case .armedConflict:    return 2 * 3600   // 2 h
        case .explosion:        return 3 * 3600   // 3 h
        case .drone:            return 1 * 3600   // 1 h
        case .militaryMovement: return 4 * 3600   // 4 h
        case .policeCrackdown:  return 3 * 3600   // 3 h
        case .arrests:          return 6 * 3600   // 6 h
        case .checkpoint:       return 8 * 3600   // 8 h
        }
    }
}

// MARK: - Wire payloads

/// Wire payload for a map label (place on map, share with peers).
/// Uses short keys and omits sender (use envelope.senderID/senderName) to stay under 512 bytes.
public struct MapLabelPayload: Codable, Equatable {
    public let id: UUID
    public let category: String
    public let lat: Double
    public let lon: Double
    public let senderID: String
    public let senderName: String
    public let timestamp: UInt64

    private enum CodingKeys: String, CodingKey {
        case id = "i", category = "c", lat = "a", lon = "o", timestamp = "t"
    }

    public init(id: UUID, category: String, lat: Double, lon: Double,
                senderID: String, senderName: String, timestamp: UInt64) {
        self.id = id; self.category = category; self.lat = lat; self.lon = lon
        self.senderID = senderID; self.senderName = senderName; self.timestamp = timestamp
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        category = try c.decode(String.self, forKey: .category)
        lat = try c.decode(Double.self, forKey: .lat)
        lon = try c.decode(Double.self, forKey: .lon)
        timestamp = try c.decode(UInt64.self, forKey: .timestamp)
        senderID = ""; senderName = ""
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(category, forKey: .category)
        try c.encode(lat, forKey: .lat)
        try c.encode(lon, forKey: .lon)
        try c.encode(timestamp, forKey: .timestamp)
    }
}

/// Wire payload for a vote on a label's validity (up = 1, down = -1). Short keys for size.
public struct MapLabelVotePayload: Codable, Equatable {
    public let labelId: UUID
    public let vote: Int
    public let voterID: String

    private enum CodingKeys: String, CodingKey {
        case labelId = "l", vote = "v", voterID = "r"
    }

    public init(labelId: UUID, vote: Int, voterID: String) {
        self.labelId = labelId; self.vote = vote; self.voterID = voterID
    }
}

/// Wire payload for a comment on an alert/label.
public struct LabelCommentPayload: Codable, Equatable {
    public let commentId: UUID
    public let labelId: UUID
    public let senderID: String
    public let senderName: String
    public let text: String
    /// Optional JPEG image as base64 (small, compressed for BLE).
    public let imageJPEGBase64: String?
    public let timestamp: UInt64

    private enum CodingKeys: String, CodingKey {
        case commentId = "ci", labelId = "li", senderID = "si",
             senderName = "sn", text = "tx", imageJPEGBase64 = "im", timestamp = "ts"
    }

    public init(commentId: UUID, labelId: UUID, senderID: String, senderName: String,
                text: String, imageJPEGBase64: String? = nil, timestamp: UInt64) {
        self.commentId = commentId; self.labelId = labelId; self.senderID = senderID
        self.senderName = senderName; self.text = text
        self.imageJPEGBase64 = imageJPEGBase64; self.timestamp = timestamp
    }
}

// MARK: - In-memory models

/// One comment thread entry on an alert.
public struct LabelComment: Identifiable, Equatable {
    public let id: UUID
    public let labelId: UUID
    public let senderID: String
    public let senderName: String
    public let text: String
    public let imageJPEGBase64: String?
    public let date: Date
    public var isLocal: Bool

    public init(id: UUID, labelId: UUID, senderID: String, senderName: String,
                text: String, imageJPEGBase64: String? = nil, date: Date, isLocal: Bool) {
        self.id = id; self.labelId = labelId; self.senderID = senderID
        self.senderName = senderName; self.text = text
        self.imageJPEGBase64 = imageJPEGBase64; self.date = date; self.isLocal = isLocal
    }
}

/// In-memory label with vote counts and expiry.
public struct MapLabelRecord: Identifiable, Equatable {
    public let id: UUID
    public let category: LabelCategory
    public let latitude: Double
    public let longitude: Double
    public let senderID: String
    public let senderName: String
    public let date: Date
    public var upVotes: Int
    public var downVotes: Int

    /// Date after which the alert disappears from the map.
    public var expiresAt: Date {
        date.addingTimeInterval(category.expiryDuration)
    }

    public var isExpired: Bool { Date() > expiresAt }

    public var confidenceScore: Double {
        let total = upVotes + downVotes
        guard total > 0 else { return 0.5 }
        return Double(upVotes) / Double(total)
    }

    public var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    /// Opacity fades in the last 20% of the expiry window.
    public var mapOpacity: Double {
        let total = category.expiryDuration
        let remaining = expiresAt.timeIntervalSinceNow
        guard remaining > 0 else { return 0 }
        let fraction = remaining / total
        return fraction < 0.2 ? fraction / 0.2 : 1.0
    }

    public init(id: UUID, category: LabelCategory, latitude: Double, longitude: Double,
                senderID: String, senderName: String, date: Date, upVotes: Int, downVotes: Int) {
        self.id = id; self.category = category; self.latitude = latitude; self.longitude = longitude
        self.senderID = senderID; self.senderName = senderName; self.date = date
        self.upVotes = upVotes; self.downVotes = downVotes
    }
}
