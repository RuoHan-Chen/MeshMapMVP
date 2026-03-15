import Foundation

private let kNickname = "meshchat.nickname"
private let kShareLocation = "meshchat.shareLocation"
private let kLegacyDeviceID = "meshchat.deviceID"

/// Local identity. **deviceID** is stable URL-safe base64 of **Curve25519 public key** (Keychain-backed keypair).
struct DeviceIdentity: Codable, Equatable {
    var deviceID: String
    var nickname: String
    var shareLocation: Bool

    static func load() -> DeviceIdentity {
        let defaults = UserDefaults.standard
        let deviceID = KeyManager.publicKeyBase64DeviceID
        if defaults.string(forKey: kLegacyDeviceID) != nil {
            defaults.removeObject(forKey: kLegacyDeviceID)
        }
        let name = defaults.string(forKey: kNickname) ?? defaultNickname(fingerprint: KeyManager.fingerprint(KeyManager.publicKeyData, length: 6))
        if defaults.string(forKey: kNickname) == nil {
            defaults.set(name, forKey: kNickname)
        }
        let share = (defaults.object(forKey: kShareLocation) as? Bool) ?? true
        return DeviceIdentity(deviceID: deviceID, nickname: name, shareLocation: share)
    }

    func save() {
        let defaults = UserDefaults.standard
        defaults.set(nickname, forKey: kNickname)
        defaults.set(shareLocation, forKey: kShareLocation)
    }

    private static func defaultNickname(fingerprint: String) -> String {
        "Peer-\(fingerprint)"
    }
}
