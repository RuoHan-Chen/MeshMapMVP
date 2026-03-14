import Foundation

struct AnnouncementPayload: Codable, Equatable {
    let nickname: String
    /// Sender’s Curve25519 **signing** public key (32 bytes), base64 — identity / deviceID.
    var publicKeyBase64: String?
    /// X25519 **encryption** public key for E2E DMs (32 bytes), standard base64.
    var encryptionPublicKeyBase64: String?

    init(nickname: String, publicKeyBase64: String?, encryptionPublicKeyBase64: String? = nil) {
        self.nickname = nickname
        self.publicKeyBase64 = publicKeyBase64
        self.encryptionPublicKeyBase64 = encryptionPublicKeyBase64
    }
}
