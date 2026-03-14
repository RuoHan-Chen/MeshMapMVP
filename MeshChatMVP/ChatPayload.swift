import Foundation

struct ChatPayload: Codable, Equatable {
    var text: String
    /// When set, only sender + this peer should show the message (still floods mesh for relay).
    var recipientID: String?
    /// If true, `text` is ignored; body is in `ciphertextB64` (AES-GCM, X25519-derived key).
    var encrypted: Bool?
    var ciphertextB64: String?

    init(text: String, recipientID: String? = nil, encrypted: Bool? = nil, ciphertextB64: String? = nil) {
        self.text = text
        self.recipientID = recipientID
        self.encrypted = encrypted
        self.ciphertextB64 = ciphertextB64
    }
}
