import Foundation
import CoreLocation

/// Category for user-placed map labels (shared over mesh).
/// First three are the configurable event types (Hazard, Help, Other); rest are legacy.
public enum LabelCategory: String, Codable, CaseIterable {
    case hazard = "hazard"
    case help = "help"
    case other = "other"
    case armedConflict = "armed_conflict"
    case explosion = "explosion"
    case drone = "drone"
    case militaryMovement = "military_movement"
    case policeCrackdown = "police_crackdown"
    case arrests = "arrests"
    case checkpoint = "checkpoint"

    /// Default display name; can be overridden by customLabelName on the record.
    public var displayName: String {
        switch self {
        case .hazard: return "Hazard"
        case .help: return "Help"
        case .other: return "Other"
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
        case .hazard: return "exclamationmark.triangle.fill"
        case .help: return "hand.raised.fill"
        case .other: return "questionmark.circle.fill"
        case .armedConflict: return "bolt.fill"
        case .explosion: return "flame.fill"
        case .drone: return "airplane"
        case .militaryMovement: return "figure.march"
        case .policeCrackdown: return "shield.fill"
        case .arrests: return "hand.raised.fill"
        case .checkpoint: return "road.lanes"
        }
    }

    /// Only hazard, help, other use EventTypesConfig for custom names.
    public static var configurableEventTypes: [LabelCategory] { [.hazard, .help, .other] }
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
    /// Optional custom label name (for hazard/help/other).
    public let customLabelName: String?
    /// Optional description (for hazard/help/other).
    public let customDescription: String?
    /// Optional explicit SF Symbol chosen when creating the event.
    public let customSystemImage: String?

    private enum CodingKeys: String, CodingKey {
        case id = "i", category = "c", lat = "a", lon = "o", timestamp = "t", customLabelName = "n", customDescription = "d", customSystemImage = "s"
    }

    public init(
        id: UUID,
        category: String,
        lat: Double,
        lon: Double,
        senderID: String,
        senderName: String,
        timestamp: UInt64,
        customLabelName: String? = nil,
        customDescription: String? = nil,
        customSystemImage: String? = nil
    ) {
        self.id = id
        self.category = category
        self.lat = lat
        self.lon = lon
        self.senderID = senderID
        self.senderName = senderName
        self.timestamp = timestamp
        self.customLabelName = customLabelName
        self.customDescription = customDescription
        self.customSystemImage = customSystemImage
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
        customLabelName = try c.decodeIfPresent(String.self, forKey: .customLabelName)
        customDescription = try c.decodeIfPresent(String.self, forKey: .customDescription)
        customSystemImage = try c.decodeIfPresent(String.self, forKey: .customSystemImage)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(category, forKey: .category)
        try c.encode(lat, forKey: .lat)
        try c.encode(lon, forKey: .lon)
        try c.encode(timestamp, forKey: .timestamp)
        try c.encodeIfPresent(customLabelName, forKey: .customLabelName)
        try c.encodeIfPresent(customDescription, forKey: .customDescription)
        try c.encodeIfPresent(customSystemImage, forKey: .customSystemImage)
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

/// Wire payload for a chunk of a small thumbnail image associated with a map label.
/// Images are aggressively compressed thumbnails split into multiple chunks to stay under 512 bytes per envelope.
/// Optional LZ4 compression (c: true) for faster, more resilient transfer.
public struct MapLabelImageChunkPayload: Codable, Equatable {
    public let imageId: UUID      // ID of this thumbnail (usually same as labelId)
    public let labelId: UUID      // Associated map label
    public let index: Int         // 0-based chunk index
    public let total: Int         // Total number of chunks
    public let data: Data         // Raw bytes (JPEG or LZ4-compressed)
    public let compressed: Bool? // If true, reassembled payload is LZ4; decompress before use (nil = legacy raw JPEG)

    private enum CodingKeys: String, CodingKey {
        case imageId = "i", labelId = "l", index = "x", total = "t", data = "d", compressed = "c"
    }

    public init(imageId: UUID, labelId: UUID, index: Int, total: Int, data: Data, compressed: Bool? = nil) {
        self.imageId = imageId
        self.labelId = labelId
        self.index = index
        self.total = total
        self.data = data
        self.compressed = compressed
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
    /// Custom name set by user (for hazard/help/other); nil uses category default.
    public let customLabelName: String?
    /// Optional description.
    public let customDescription: String?
    /// Optional explicit SF Symbol chosen for the event.
    public let customSystemImage: String?

    /// Display name: custom name if set, else category default.
    public var displayName: String {
        if let name = customLabelName, !name.isEmpty { return name }
        return category.displayName
    }

    /// Icon to use when rendering the label.
    public var systemImage: String {
        if let img = customSystemImage, !img.isEmpty { return img }
        return category.systemImage
    }

    public var confidenceScore: Double {
        let total = upVotes + downVotes
        guard total > 0 else { return 0.5 }
        return Double(upVotes) / Double(total)
    }

    public var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    /// Events expire 1 hour after creation by default.
    public static let eventExpirationInterval: TimeInterval = 60 * 60

    public var isExpired: Bool {
        Date().timeIntervalSince(date) > Self.eventExpirationInterval
    }

    public init(
        id: UUID,
        category: LabelCategory,
        latitude: Double,
        longitude: Double,
        senderID: String,
        senderName: String,
        date: Date,
        upVotes: Int,
        downVotes: Int,
        customLabelName: String? = nil,
        customDescription: String? = nil,
        customSystemImage: String? = nil
    ) {
        self.id = id
        self.category = category
        self.latitude = latitude
        self.longitude = longitude
        self.senderID = senderID
        self.senderName = senderName
        self.date = date
        self.upVotes = upVotes
        self.downVotes = downVotes
        self.customLabelName = customLabelName
        self.customDescription = customDescription
        self.customSystemImage = customSystemImage
    }
}
