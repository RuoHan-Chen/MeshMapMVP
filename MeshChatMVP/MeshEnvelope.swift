import Foundation

/// Single MVP envelope: flood over BLE with TTL + dedup by `id`.
struct MeshEnvelope: Codable, Equatable {
    var id: UUID
    var type: MessageType
    var senderID: String
    var senderName: String
    var timestamp: UInt64
    var ttl: UInt8
    var payload: Data

    static func encodeJSON(_ envelope: MeshEnvelope) -> Data? {
        try? JSONEncoder().encode(envelope)
    }

    static func decodeJSON(_ data: Data) -> MeshEnvelope? {
        try? JSONDecoder().decode(MeshEnvelope.self, from: data)
    }
}
