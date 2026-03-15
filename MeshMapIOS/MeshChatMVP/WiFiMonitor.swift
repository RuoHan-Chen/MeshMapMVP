import Foundation
import Network

/// Observes network path and exposes whether the device is on WiFi (for MeshNews publish, etc.).
/// On the ai branch, BluetoothMeshService uses a path monitor and `localHasInternet`; this is a standalone version for the You tab.
final class WiFiMonitor: ObservableObject {
    @Published private(set) var isOnWifi = false

    private let monitor = NWPathMonitor(requiredInterfaceType: .wifi)
    private let queue = DispatchQueue(label: "MeshChat.WiFiMonitor")

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                self?.isOnWifi = path.status == .satisfied
            }
        }
        monitor.start(queue: queue)
    }

    deinit {
        monitor.cancel()
    }
}
