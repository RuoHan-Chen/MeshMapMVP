import Foundation

/// Broadcast on mesh: this device has a route to the internet (WiFi or cellular).
struct ConnectivityPayload: Codable, Equatable {
    var hasInternet: Bool
    /// `"wifi"` | `"cellular"` | `"other"` when hasInternet
    var interfaceType: String?
}
