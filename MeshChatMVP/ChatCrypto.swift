import CryptoKit
import Foundation

/// ECDH (X25519) + HKDF + AES-GCM for direct messages. Peers exchange **encryption** public keys in announce.
enum ChatCrypto {
    private static let hkdfSalt = Data("MeshChatMVP-DM-v1".utf8)
    private static let hkdfInfo = Data("dm".utf8)

    static func deriveKey(myPrivate: Curve25519.KeyAgreement.PrivateKey, theirPublic: Data) throws -> SymmetricKey {
        let pub = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: theirPublic)
        let secret = try myPrivate.sharedSecretFromKeyAgreement(with: pub)
        let ikm = secret.withUnsafeBytes { SymmetricKey(data: Data($0)) }
        return HKDF<SHA256>.deriveKey(inputKeyMaterial: ikm, salt: hkdfSalt, info: hkdfInfo, outputByteCount: 32)
    }

    /// Returns nonce(12) || ciphertext || tag(16), base64-safe as whole Data.
    static func seal(plaintext: String, myPrivate: Curve25519.KeyAgreement.PrivateKey, theirPublic: Data, aad: Data) throws -> Data {
        let key = try deriveKey(myPrivate: myPrivate, theirPublic: theirPublic)
        let plain = Data(plaintext.utf8)
        let nonce = AES.GCM.Nonce()
        let box = try AES.GCM.seal(plain, using: key, nonce: nonce, authenticating: aad)
        return Data(nonce) + box.ciphertext + box.tag
    }

    static func open(combined: Data, myPrivate: Curve25519.KeyAgreement.PrivateKey, theirPublic: Data, aad: Data) throws -> String {
        let key = try deriveKey(myPrivate: myPrivate, theirPublic: theirPublic)
        guard combined.count > 12 + 16 else { throw NSError(domain: "ChatCrypto", code: 1) }
        let nonce = try AES.GCM.Nonce(data: combined.prefix(12))
        let tag = combined.suffix(16)
        let ct = combined.dropFirst(12).dropLast(16)
        let box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ct, tag: tag)
        let out = try AES.GCM.open(box, using: key, authenticating: aad)
        guard let s = String(data: out, encoding: .utf8) else { throw NSError(domain: "ChatCrypto", code: 2) }
        return s
    }

    static func aad(senderID: String, recipientID: String, timestampMs: UInt64) -> Data {
        var d = Data("\(senderID)|\(recipientID)|".utf8)
        d.append(contentsOf: withUnsafeBytes(of: timestampMs.bigEndian) { Data($0) })
        return d
    }
}
