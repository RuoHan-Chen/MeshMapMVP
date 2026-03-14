import Foundation

struct ChatPayload: Codable, Equatable {
    let text: String
    /// When set, only sender + this peer should show the message (still floods mesh for relay).
    var recipientID: String?
    init(text: String, recipientID: String? = nil) {
        self.text = text
        self.recipientID = recipientID
    }
}
