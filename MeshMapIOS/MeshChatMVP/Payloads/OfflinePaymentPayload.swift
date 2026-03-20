import Foundation

/// Signed payload data used for app-level offline mesh payment scaffolding.
/// NOTE: Receivers treat this as a *payment claim only* — no on-chain settlement is performed yet.
struct OfflinePaymentSigningData: Codable, Equatable {
    var paymentID: String
    var senderDeviceID: String
    var senderName: String
    var recipientDeviceID: String
    var recipientName: String

    var amountLamports: Int64
    var assetSymbol: String

    var createdAt: Int64
    var memo: String?

    var payloadVersion: Int
}

struct OfflinePaymentPayload: Codable, Equatable {
    var paymentID: String

    var senderDeviceID: String
    var senderName: String
    var recipientDeviceID: String
    var recipientName: String

    var amountLamports: Int64
    var assetSymbol: String

    var createdAt: Int64
    var memo: String?

    var paymentPublicKeyBase64: String
    var paymentSignatureBase64: String

    var payloadVersion: Int

    func signingData() -> OfflinePaymentSigningData {
        OfflinePaymentSigningData(
            paymentID: paymentID,
            senderDeviceID: senderDeviceID,
            senderName: senderName,
            recipientDeviceID: recipientDeviceID,
            recipientName: recipientName,
            amountLamports: amountLamports,
            assetSymbol: assetSymbol,
            createdAt: createdAt,
            memo: memo,
            payloadVersion: payloadVersion
        )
    }

    func paymentPublicKeyData() -> Data? {
        Data(base64Encoded: paymentPublicKeyBase64)
    }

    func paymentSignatureData() -> Data? {
        Data(base64Encoded: paymentSignatureBase64)
    }
}

