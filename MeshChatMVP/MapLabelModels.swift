import Foundation
import CoreLocation

/// Category for user-placed map labels (shared over mesh).
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
        case .armedConflict: return "Armed conflict / gunfire"
        case .explosion: return "Explosion / bombing"
        case .drone: return "Drone / airstrike"
        case .militaryMovement: return "Military movement"
        case .policeCrackdown: return "Police crackdown"
        case .arrests: return "Arrests / detention"
        case .checkpoint: return "Checkpoint / roadblock"
        }
    }

    public var systemImage: String {
        switch self {
        case .armedConflict: return "bolt.fill"
        case .explosion: return "flame.fill"
        case .drone: return "airplane"
        case .militaryMovement: return "figure.march"
        case .policeCrackdown: return "shield.fill"
        case .arrests: return "hand.raised.fill"
        case .checkpoint: return "road.lanes"
        }
    }
}

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

    public init(id: UUID, category: String, lat: Double, lon: Double, senderID: String, senderName: String, timestamp: UInt64) {
        self.id = id
        self.category = category
        self.lat = lat
        self.lon = lon
        self.senderID = senderID
        self.senderName = senderName
        self.timestamp = timestamp
    }

    /// Decode from wire (short keys); caller must set senderID/senderName from envelope when storing.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        category = try c.decode(String.self, forKey: .category)
        lat = try c.decode(Double.self, forKey: .lat)
        lon = try c.decode(Double.self, forKey: .lon)
        timestamp = try c.decode(UInt64.self, forKey: .timestamp)
        senderID = ""
        senderName = ""
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(category, forKey: .category)
        try c.encode(lat, forKey: .lat)
        try c.encode(lon, forKey: .lon)
        try c.encode(timestamp, forKey: .timestamp)
        // Omit senderID/senderName on wire; receiver uses envelope
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
        self.labelId = labelId
        self.vote = vote
        self.voterID = voterID
    }
}

/// In-memory label with vote counts for display (confidence score).
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

    public var confidenceScore: Double {
        let total = upVotes + downVotes
        guard total > 0 else { return 0.5 }
        return Double(upVotes) / Double(total)
    }

    public var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    public init(id: UUID, category: LabelCategory, latitude: Double, longitude: Double, senderID: String, senderName: String, date: Date, upVotes: Int, downVotes: Int) {
        self.id = id
        self.category = category
        self.latitude = latitude
        self.longitude = longitude
        self.senderID = senderID
        self.senderName = senderName
        self.date = date
        self.upVotes = upVotes
        self.downVotes = downVotes
    }
}
