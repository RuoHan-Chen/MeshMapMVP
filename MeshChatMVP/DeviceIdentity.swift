import Foundation

private let kDeviceID = "meshchat.deviceID"
private let kNickname = "meshchat.nickname"
private let kShareLocation = "meshchat.shareLocation"

/// Local identity persisted in UserDefaults.
struct DeviceIdentity: Codable, Equatable {
    var deviceID: String
    var nickname: String
    /// When true, envelopes include sender coordinates so peers can show distance. User can opt out.
    var shareLocation: Bool

    static func load() -> DeviceIdentity {
        let defaults = UserDefaults.standard
        let id = defaults.string(forKey: kDeviceID) ?? UUID().uuidString
        if defaults.string(forKey: kDeviceID) == nil {
            defaults.set(id, forKey: kDeviceID)
        }
        let name = defaults.string(forKey: kNickname) ?? defaultNickname(for: id)
        if defaults.string(forKey: kNickname) == nil {
            defaults.set(name, forKey: kNickname)
        }
        let share = (defaults.object(forKey: kShareLocation) as? Bool) ?? true
        return DeviceIdentity(deviceID: id, nickname: name, shareLocation: share)
    }

    func save() {
        let defaults = UserDefaults.standard
        defaults.set(deviceID, forKey: kDeviceID)
        defaults.set(nickname, forKey: kNickname)
        defaults.set(shareLocation, forKey: kShareLocation)
    }

    private static func defaultNickname(for deviceID: String) -> String {
        let short = String(deviceID.prefix(6))
        return "Peer-\(short)"
    }
}
