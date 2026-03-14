import Foundation
import SwiftUI

// MARK: - Message channel types

enum ChannelType: String, Codable, CaseIterable {
    case broadcast   // @everyone — floods the whole mesh
    case group       // named group, members by deviceID
    case direct      // 1:1 between two deviceIDs
}

struct Channel: Identifiable, Codable, Equatable {
    var id: String              // for broadcast = "broadcast"; for direct = sorted pair; for group = UUID
    var type: ChannelType
    var name: String
    var memberIDs: [String]     // empty = open broadcast
    var createdAt: Date
    var lastMessageAt: Date
    var unreadCount: Int

    static var broadcast: Channel {
        Channel(id: "broadcast", type: .broadcast, name: "@everyone",
                memberIDs: [], createdAt: Date(), lastMessageAt: Date(), unreadCount: 0)
    }

    static func direct(myID: String, peerID: String, peerName: String) -> Channel {
        let sorted = [myID, peerID].sorted()
        return Channel(id: sorted.joined(separator: ":"), type: .direct,
                       name: peerName, memberIDs: sorted,
                       createdAt: Date(), lastMessageAt: Date(), unreadCount: 0)
    }

    static func group(name: String, memberIDs: [String]) -> Channel {
        Channel(id: UUID().uuidString, type: .group, name: name,
                memberIDs: memberIDs, createdAt: Date(), lastMessageAt: Date(), unreadCount: 0)
    }
}

// MARK: - Enhanced chat message (stored locally)

struct StoredMessage: Identifiable, Codable, Equatable {
    var id: UUID
    var channelID: String
    var envelopeID: UUID
    var senderID: String
    var senderName: String
    var text: String
    var imageData: Data?        // compressed JPEG for photo messages
    var timestamp: Date
    var isFromMe: Bool
    var distanceMeters: Double?
    var reactions: [String: [String]] = [:]  // emoji → [senderID]
    var replyToID: UUID?

    init(
        id: UUID = UUID(),
        channelID: String,
        envelopeID: UUID,
        senderID: String,
        senderName: String,
        text: String,
        imageData: Data? = nil,
        timestamp: Date,
        isFromMe: Bool,
        distanceMeters: Double? = nil,
        reactions: [String: [String]] = [:],
        replyToID: UUID? = nil
    ) {
        self.id = id
        self.channelID = channelID
        self.envelopeID = envelopeID
        self.senderID = senderID
        self.senderName = senderName
        self.text = text
        self.imageData = imageData
        self.timestamp = timestamp
        self.isFromMe = isFromMe
        self.distanceMeters = distanceMeters
        self.reactions = reactions
        self.replyToID = replyToID
    }

    // Convert from live ChatMessage
    init(from msg: ChatMessage, channelID: String, myID: String) {
        self.id = msg.id
        self.channelID = channelID
        self.envelopeID = msg.envelopeId
        self.senderID = msg.senderID
        self.senderName = msg.senderName
        self.text = msg.text
        self.imageData = msg.imageJPEGBase64.flatMap { Data(base64Encoded: $0) }
        self.timestamp = msg.date
        self.isFromMe = msg.isLocal
        self.distanceMeters = msg.distanceFromMe
        self.reactions = [:]
        self.replyToID = nil
    }
}

// MARK: - Alert / incident

enum AlertSeverity: String, Codable, CaseIterable {
    case danger, warning, safe, medical, info

    var color: Color {
        switch self {
        case .danger:  return Color(hex: "#e53e3e")
        case .warning: return Color(hex: "#f5a623")
        case .safe:    return Color(hex: "#00e5a0")
        case .medical: return Color(hex: "#64a0ff")
        case .info:    return Color(hex: "#a78bfa")
        }
    }
    var icon: String {
        switch self {
        case .danger:  return "exclamationmark.octagon.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .safe:    return "checkmark.shield.fill"
        case .medical: return "cross.circle.fill"
        case .info:    return "info.circle.fill"
        }
    }
    var label: String { rawValue.capitalized }
}

struct MeshAlertItem: Identifiable, Codable, Equatable {
    var id: UUID
    var severity: AlertSeverity
    var title: String
    var body: String
    var authorID: String
    var authorName: String
    var timestamp: Date
    var isExpired: Bool
    var expiresAt: Date?
    // Proximity trust: list of deviceIDs who are direct contacts of ours and confirmed this
    var confirmedByContacts: [String]
    // Thread of comments
    var comments: [AlertComment]
    // Photos attached to alert
    var photoData: [Data]

    var trustScore: Double {
        // Based purely on how many of YOUR direct contacts confirmed it
        // 0 contacts = 0.1 base, each contact vouch adds 0.25, cap at 0.95
        let base = 0.10
        let perContact = 0.25
        return min(0.95, base + Double(confirmedByContacts.count) * perContact)
    }
}

struct AlertComment: Identifiable, Codable, Equatable {
    var id: UUID
    var alertID: UUID
    var authorID: String
    var authorName: String
    var text: String
    var imageData: Data?
    var timestamp: Date
    var isFromContact: Bool     // true if author is in your contacts
}

// MARK: - Contact

struct Contact: Identifiable, Codable, Equatable {
    var id: String              // = deviceID
    var nickname: String        // their callsign
    var localName: String?      // your local alias for them
    var firstSeenAt: Date
    var lastSeenAt: Date
    var rssiHistory: [Int]      // last N RSSI readings for proximity estimate
    var isFriend: Bool          // you explicitly added them
    var mutualFriendIDs: [String] // friends of friends seen via announce chain

    var displayName: String { localName ?? nickname }

    // Proximity-based trust:
    // Direct contact you added = 1.0
    // Seen directly (BLE, in range) but not added = 0.6
    // Friend-of-friend = 0.35
    // Unknown (never seen directly) = 0.1
    func trustScore(myContacts: [Contact]) -> Double {
        if isFriend { return 1.0 }
        let isDirectlySeen = !rssiHistory.isEmpty
        if isDirectlySeen { return 0.6 }
        let sharedFriend = myContacts.contains { $0.isFriend && mutualFriendIDs.contains($0.id) }
        if sharedFriend { return 0.35 }
        return 0.10
    }
}

// MARK: - Color hex extension (shared)

extension Color {
    init(hex: String) {
        let h = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var n: UInt64 = 0
        Scanner(string: h).scanHexInt64(&n)
        self.init(
            red:   Double((n >> 16) & 0xFF) / 255,
            green: Double((n >>  8) & 0xFF) / 255,
            blue:  Double( n        & 0xFF) / 255
        )
    }
}