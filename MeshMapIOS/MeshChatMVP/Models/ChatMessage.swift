import Foundation

/// One row in the chat transcript. In-memory photos use `imageJPEGBase64`; **persistence strips images** (see `saveChatHistory`).
struct ChatMessage: Identifiable, Equatable, Codable {
    let id: UUID
    let envelopeId: UUID
    let senderID: String
    let senderName: String
    /// Caption or placeholder when `imageJPEGBase64` is set (e.g. "[photo]").
    let text: String
    let date: Date
    var isLocal: Bool
    var distanceFromMe: Double?
    /// JPEG as base64 for persistence / UI (simple MVP; no separate encryption).
    var imageJPEGBase64: String?

    /// Messages expire after 20 minutes by default (map UI filter).
    static let expirationInterval: TimeInterval = 20 * 60

    var isExpired: Bool {
        Date().timeIntervalSince(date) > Self.expirationInterval
    }

    init(
        id: UUID = UUID(),
        envelopeId: UUID,
        senderID: String,
        senderName: String,
        text: String,
        date: Date,
        isLocal: Bool,
        distanceFromMe: Double? = nil,
        imageJPEGBase64: String? = nil
    ) {
        self.id = id
        self.envelopeId = envelopeId
        self.senderID = senderID
        self.senderName = senderName
        self.text = text
        self.date = date
        self.isLocal = isLocal
        self.distanceFromMe = distanceFromMe
        self.imageJPEGBase64 = imageJPEGBase64
    }
}
