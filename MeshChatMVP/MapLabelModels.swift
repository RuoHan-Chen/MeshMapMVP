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
public struct MapLabelPayload: Codable, Equatable {
    public let id: UUID
    public let category: String
    public let lat: Double
    public let lon: Double
    public let senderID: String
    public let senderName: String
    public let timestamp: UInt64

    public init(id: UUID, category: String, lat: Double, lon: Double, senderID: String, senderName: String, timestamp: UInt64) {
        self.id = id
        self.category = category
        self.lat = lat
        self.lon = lon
        self.senderID = senderID
        self.senderName = senderName
        self.timestamp = timestamp
    }
}

/// Wire payload for a vote on a label's validity (up = 1, down = -1).
public struct MapLabelVotePayload: Codable, Equatable {
    public let labelId: UUID
    public let vote: Int
    public let voterID: String

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
