import Foundation

struct AnnouncementPayload: Codable, Equatable {
    let nickname: String
    /// Sender’s Curve25519 public key (32 bytes), base64 URL-safe. Required for new clients; omit for tiny payloads.
    var publicKeyBase64: String?

    init(nickname: String, publicKeyBase64: String?) {
        self.nickname = nickname
        self.publicKeyBase64 = publicKeyBase64
    }
}
