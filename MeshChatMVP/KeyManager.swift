import Foundation
import CryptoKit
import Security

/// Persists Curve25519 signing keypair: **private key in Keychain**, public key derivable. Mesh `deviceID` = stable base64(publicKey).
enum KeyManager {
    private static let keychainService = "meshchat.device.signing"
    private static let keychainAccount = "private"
    private static let keychainEncAccount = "encryption-x25519"

    /// Load or create keypair. Thread-safe enough for app use (call from main at launch).
    static func loadOrCreateKeypair() -> (publicKey: Data, privateKey: Curve25519.Signing.PrivateKey) {
        if let priv = loadPrivateKey() {
            let pub = priv.publicKey
            return (pub.rawRepresentation, priv)
        }
        let priv = Curve25519.Signing.PrivateKey()
        savePrivateKey(priv)
        return (priv.publicKey.rawRepresentation, priv)
    }

    static var publicKeyData: Data {
        loadOrCreateKeypair().publicKey
    }

    /// URL-safe base64, no padding — stable device id for mesh envelopes.
    static var publicKeyBase64DeviceID: String {
        publicKeyData.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func fingerprint(_ publicKey: Data, length: Int = 8) -> String {
        let h = SHA256.hash(data: publicKey)
        let hex = h.map { String(format: "%02x", $0) }.joined()
        return String(hex.prefix(length))
    }

    private static func savePrivateKey(_ key: Curve25519.Signing.PrivateKey) {
        let data = key.rawRepresentation
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        SecItemDelete(query as CFDictionary)
        SecItemAdd(query as CFDictionary, nil)
    }

    private static func loadPrivateKey() -> Curve25519.Signing.PrivateKey? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var out: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data,
              let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: data) else { return nil }
        return key
    }

    static func decodePublicKeyBase64(_ s: String) -> Data? {
        var base64 = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64.append("=") }
        guard let data = Data(base64Encoded: base64), data.count == 32 else { return nil }
        return data
    }

    // MARK: - Encryption (X25519) for E2E DMs

    static func loadOrCreateEncryptionKeypair() -> (publicKey: Data, privateKey: Curve25519.KeyAgreement.PrivateKey) {
        if let priv = loadEncryptionPrivate() {
            return (priv.publicKey.rawRepresentation, priv)
        }
        let priv = Curve25519.KeyAgreement.PrivateKey()
        saveEncryptionPrivate(priv)
        return (priv.publicKey.rawRepresentation, priv)
    }

    private static func saveEncryptionPrivate(_ key: Curve25519.KeyAgreement.PrivateKey) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainEncAccount,
            kSecValueData as String: key.rawRepresentation,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        SecItemDelete(query as CFDictionary)
        SecItemAdd(query as CFDictionary, nil)
    }

    private static func loadEncryptionPrivate() -> Curve25519.KeyAgreement.PrivateKey? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainEncAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var out: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data,
              let key = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: data) else { return nil }
        return key
    }
}
