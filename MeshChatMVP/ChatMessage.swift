import Foundation

/// One row in the chat transcript (UI + debug).
struct ChatMessage: Identifiable, Equatable {
    let id: UUID
    let envelopeId: UUID
    let senderID: String
    let senderName: String
    let text: String
    let date: Date
    /// True if this device only relayed (we still show same as receive for MVP).
    var isLocal: Bool
}
