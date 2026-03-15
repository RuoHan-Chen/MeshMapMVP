import Foundation
import GRDB

/// Persistent store for chat messages. Separate from ChatMessage (UI model).
struct PersistedMessage: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "messages"

    var id: String          // envelope UUID (dedup key)
    var senderID: String    // FK → contacts.id
    var senderName: String  // denormalized for display without join
    var text: String
    var timestamp: Int64    // sender timestamp (ms since epoch)
    var channel: String     // "broadcast" or a DM thread id
    var receivedAt: Int64   // local unix timestamp (seconds)
    var imageBase64: String?
}

extension PersistedMessage {
    /// Convert to the UI model used by ChatView.
    func toChatMessage(distanceFromMe: Double? = nil, isLocal: Bool = false) -> ChatMessage {
        ChatMessage(
            id: UUID(),
            envelopeId: UUID(uuidString: id) ?? UUID(),
            senderID: senderID,
            senderName: senderName,
            text: text,
            date: Date(timeIntervalSince1970: Double(receivedAt)),
            isLocal: isLocal,
            distanceFromMe: distanceFromMe,
            imageJPEGBase64: imageBase64
        )
    }
}
