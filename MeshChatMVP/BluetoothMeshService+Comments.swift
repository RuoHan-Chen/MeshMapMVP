import Foundation

/// Extension that wires label comment state + sending into the existing mesh service.
/// Add the `@Published var labelComments` property to BluetoothMeshService directly,
/// or use this approach: we store comments in a shared store accessed via this extension.
///
/// TO INTEGRATE: Add the following to BluetoothMeshService's stored properties:
///   @Published var labelComments: [UUID: [LabelComment]] = [:]
///
/// And in the envelope-handling switch add a case for `.labelComment` that calls `handleLabelComment(_:)`.
///
/// The stubs below compile against the existing type; replace with real BLE send when ready.

extension BluetoothMeshService {

    /// Send a comment on an alert label.
    /// Wire this to a new `.labelComment` MessageType for real mesh delivery.
    func sendLabelComment(labelId: UUID, text: String, imageJPEGBase64: String? = nil) {
        let comment = LabelComment(
            id: UUID(),
            labelId: labelId,
            senderID: identity.deviceID,
            senderName: identity.nickname,
            text: text,
            imageJPEGBase64: imageJPEGBase64,
            date: Date(),
            isLocal: true
        )
        DispatchQueue.main.async {
            var map = self.labelComments
            var list = map[labelId] ?? []
            list.append(comment)
            map[labelId] = list
            self.labelComments = map
        }

        // TODO: encode as LabelCommentPayload and relay via BLE
        // let payload = LabelCommentPayload(...)
        // enqueue(payload, type: .labelComment)
    }

    /// Ingest a comment received from a peer (call this from your BLE receive handler).
    func handleLabelComment(_ payload: LabelCommentPayload) {
        let comment = LabelComment(
            id: payload.commentId,
            labelId: payload.labelId,
            senderID: payload.senderID,
            senderName: payload.senderName,
            text: payload.text,
            imageJPEGBase64: payload.imageJPEGBase64,
            date: Date(timeIntervalSince1970: Double(payload.timestamp) / 1000),
            isLocal: false
        )
        DispatchQueue.main.async {
            var map = self.labelComments
            var list = map[payload.labelId] ?? []
            // Deduplicate by commentId
            guard !list.contains(where: { $0.id == payload.commentId }) else { return }
            list.append(comment)
            list.sort { $0.date < $1.date }
            map[payload.labelId] = list
            self.labelComments = map
        }
    }
}
