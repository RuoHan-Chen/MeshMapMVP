import Foundation
import CoreBluetooth

// MARK: - GATT UUIDs (single service + single characteristic)
private let kMeshServiceUUID = CBUUID(string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E")
private let kMeshCharUUID = CBUUID(string: "6E400002-B5A3-F393-E0A9-E50E24DCCA9E")

/// Discovered peripheral shown in UI.
struct DiscoveredPeer: Identifiable, Equatable {
    let id: UUID
    var name: String
    var rssi: Int
    var nickname: String?
    /// Best-effort: auto / manual / connected
    var linkState: String
}

/// One row for the debug dashboard.
struct MeshDebugConnectionRow: Identifiable, Equatable {
    let id: UUID
    var name: String
    var rssi: Int
    var state: String
}

/// CoreBluetooth dual-role mesh: advertise + scan, connect, write + notify, TTL relay + dedup.
final class BluetoothMeshService: NSObject, ObservableObject {
    @Published private(set) var bluetoothState: CBManagerState = .unknown
    @Published private(set) var discoveredPeers: [DiscoveredPeer] = []
    @Published private(set) var connectedPeerNames: [String] = []
    @Published private(set) var debugConnectionRows: [MeshDebugConnectionRow] = []
    @Published var chatMessages: [ChatMessage] = []
    @Published var debugLines: [String] = []
    @Published var identity: DeviceIdentity
    @Published var announceNicknames: [String: String] = [:]

    /// Battery-friendly: scan only during windows; idle between.
    @Published var isScanning: Bool = false
    @Published var scanWindowSeconds: Double = 12
    @Published var scanIdleSeconds: Double = 40
    @Published var secondsUntilNextScan: Double = 0
    @Published var autoConnectEnabled: Bool = true
    /// If false, a dropped link stays down until next scan / manual connect (less churn).
    @Published var autoReconnectEnabled: Bool = true

    @Published private(set) var subscribedCentralCount: Int = 0
    @Published private(set) var readyRemoteCount: Int = 0

    private let central: CBCentralManager
    private let peripheral: CBPeripheralManager
    private let bleQueue = DispatchQueue(label: "meshchat.ble")

    private var meshCharacteristic: CBMutableCharacteristic?
    private var subscribedCentrals: [CBCentral] = []

    private var remoteCharacteristics: [UUID: CBCharacteristic] = [:]
    private var connectedRemotes: [CBPeripheral] = []

    /// CRITICAL: connect must use the same CBPeripheral instance from discovery.
    /// retrievePeripherals(withIdentifiers:) is often empty until a prior connection existed.
    private var discoveredPeripheralRefs: [UUID: CBPeripheral] = [:]
    private var connectingIds: Set<UUID> = []
    private var lastReconnectAttempt: [UUID: Date] = [:]
    /// Avoid repeated removeAllServices() — that drops every central subscribed to us (disconnect loop).
    private var gattServicePublished: Bool = false

    private var dedupIds: Set<UUID> = []
    private var dedupQueue: [UUID] = []
    private let maxDedupEntries = 500
    private var pruneTimer: Timer?

    private var scanIdleWorkItem: DispatchWorkItem?
    private var scanCountdownTimer: Timer?
    private var nextScanDeadline: Date?
    /// Read on bleQueue only (UI copies in via syncScanTimingFromUI).
    private var bleScanWindow: Double = 12
    private var bleScanIdle: Double = 40

    private let defaultTTL: UInt8 = 5

    override init() {
        identity = DeviceIdentity.load()
        central = CBCentralManager(delegate: nil, queue: bleQueue, options: [CBCentralManagerOptionShowPowerAlertKey: true])
        peripheral = CBPeripheralManager(delegate: nil, queue: bleQueue)
        super.init()
        central.delegate = self
        peripheral.delegate = self
        startPruneTimer()
    }

    deinit {
        pruneTimer?.invalidate()
        scanCountdownTimer?.invalidate()
        scanIdleWorkItem?.cancel()
    }

    func updateIdentity(_ id: DeviceIdentity) {
        identity = id
        id.save()
        log("Identity saved; advertising name updated.")
        bleQueue.async { [weak self] in self?.restartAdvertisingOnly() }
    }

    func start() {
        bleQueue.async { [weak self] in
            self?.setupPeripheralIfPowered()
            self?.scheduleScanCycle()
        }
    }

    func stop() {
        bleQueue.async { [weak self] in
            guard let self else { return }
            self.cancelScanSchedule()
            self.central.stopScan()
            for p in self.connectedRemotes {
                self.central.cancelPeripheralConnection(p)
            }
            self.peripheral.stopAdvertising()
        }
    }

    /// Copy UI scan sliders into BLE thread (call after editing).
    func syncScanTimingFromUI() {
        let w = max(4, scanWindowSeconds)
        let i = max(10, scanIdleSeconds)
        bleQueue.async { [weak self] in
            self?.bleScanWindow = w
            self?.bleScanIdle = i
            self?.log("Scan timing: ON \(w)s / OFF \(i)s (next cycle)")
        }
    }

    /// Force an immediate scan window (does not reset idle timer mid-window).
    func scanNow() {
        bleQueue.async { [weak self] in
            self?.beginScanWindow()
        }
    }

    /// Connect using retained peripheral from discovery (fixes empty retrievePeripherals).
    func connect(to peerId: UUID) {
        bleQueue.async { [weak self] in
            guard let self else { return }
            let p: CBPeripheral?
            if let ref = self.discoveredPeripheralRefs[peerId] {
                p = ref
            } else {
                p = self.central.retrievePeripherals(withIdentifiers: [peerId]).first
            }
            guard let peripheral = p else {
                self.log("Connect failed: no peripheral ref for \(peerId) — wait for next scan")
                return
            }
            self.connectPeripheral(peripheral, reason: "manual")
        }
    }

    private func connectPeripheral(_ peripheral: CBPeripheral, reason: String) {
        let id = peripheral.identifier
        if connectedRemotes.contains(where: { $0.identifier == id }) {
            log("Already connected \(id)")
            return
        }
        if connectingIds.contains(id) {
            return
        }
        connectingIds.insert(id)
        peripheral.delegate = self
        central.connect(peripheral, options: [
            CBConnectPeripheralOptionNotifyOnConnectionKey: true,
            CBConnectPeripheralOptionNotifyOnDisconnectionKey: true,
        ])
        log("connect(\(reason)) → \(id)")
    }

    func sendChat(text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let payloadData: Data
        do {
            payloadData = try JSONEncoder().encode(ChatPayload(text: trimmed))
        } catch {
            log("Encode chat payload failed")
            return
        }
        let env = MeshEnvelope(
            id: UUID(),
            type: .message,
            senderID: identity.deviceID,
            senderName: identity.nickname,
            timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
            ttl: defaultTTL,
            payload: payloadData
        )
        appendLocalChat(envelope: env, text: trimmed)
        broadcastEnvelope(env, excludeCentral: nil, excludePeripheral: nil)
    }

    func clearDebugLog() {
        DispatchQueue.main.async { [weak self] in
            self?.debugLines = []
        }
    }

    // MARK: - Periodic scan (low duty cycle)

    private func cancelScanSchedule() {
        scanIdleWorkItem?.cancel()
        scanIdleWorkItem = nil
        central.stopScan()
        DispatchQueue.main.async { [weak self] in
            self?.isScanning = false
            self?.scanCountdownTimer?.invalidate()
            self?.scanCountdownTimer = nil
            self?.secondsUntilNextScan = 0
        }
    }

    private func scheduleScanCycle() {
        cancelScanSchedule()
        guard central.state == .poweredOn else { return }
        beginScanWindow()
    }

    private func beginScanWindow() {
        scanIdleWorkItem?.cancel()
        scanIdleWorkItem = nil
        guard central.state == .poweredOn else { return }

        central.scanForPeripherals(
            withServices: [kMeshServiceUUID],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
        )
        let window = bleScanWindow
        let idle = bleScanIdle
        log("Scan ON (\(window)s window)")

        DispatchQueue.main.async { [weak self] in
            self?.isScanning = true
            self?.nextScanDeadline = Date().addingTimeInterval(window)
            self?.secondsUntilNextScan = 0
            self?.scanCountdownTimer?.invalidate()
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.central.stopScan()
            self.log("Scan OFF — next in \(idle)s")
            DispatchQueue.main.async {
                self.isScanning = false
                self.nextScanDeadline = Date().addingTimeInterval(idle)
            }
            self.startCountdownUntilNextScan(idle: idle)
            let idleWork = DispatchWorkItem { [weak self] in
                self?.beginScanWindow()
            }
            self.scanIdleWorkItem = idleWork
            self.bleQueue.asyncAfter(deadline: .now() + idle, execute: idleWork)
        }
        scanIdleWorkItem = work
        bleQueue.asyncAfter(deadline: .now() + window, execute: work)
    }

    private func startCountdownUntilNextScan(idle: Double) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.scanCountdownTimer?.invalidate()
            var remaining = idle
            self.secondsUntilNextScan = remaining
            self.scanCountdownTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] t in
                guard let self else { t.invalidate(); return }
                remaining -= 1
                if remaining <= 0 {
                    self.secondsUntilNextScan = 0
                    t.invalidate()
                } else {
                    self.secondsUntilNextScan = remaining
                }
            }
            RunLoop.main.add(self.scanCountdownTimer!, forMode: .common)
        }
    }

    // MARK: - Peripheral setup (GATT server)

    /// Publish GATT **once**. Calling `removeAllServices()` again disconnects all subscribed centrals.
    private func setupPeripheralIfPowered() {
        guard peripheral.state == .poweredOn else { return }
        if !gattServicePublished {
            peripheral.removeAllServices()
            let char = CBMutableCharacteristic(
                type: kMeshCharUUID,
                properties: [.write, .notify],
                value: nil,
                permissions: [.writeable]
            )
            meshCharacteristic = char
            let service = CBMutableService(type: kMeshServiceUUID, primary: true)
            service.characteristics = [char]
            peripheral.add(service)
            gattServicePublished = true
            log("GATT service published (stable — no teardown on repeat)")
        }
        restartAdvertisingOnly()
    }

    private func restartAdvertisingOnly() {
        guard peripheral.state == .poweredOn else { return }
        peripheral.stopAdvertising()
        peripheral.startAdvertising([
            CBAdvertisementDataServiceUUIDsKey: [kMeshServiceUUID],
            CBAdvertisementDataLocalNameKey: String(identity.nickname.prefix(12)),
        ])
        log("Advertising (name=\(identity.nickname.prefix(12)))")
    }

    // MARK: - Dedup

    private func markSeen(_ id: UUID) -> Bool {
        if dedupIds.contains(id) { return false }
        dedupIds.insert(id)
        dedupQueue.append(id)
        while dedupQueue.count > maxDedupEntries, let old = dedupQueue.first {
            dedupQueue.removeFirst()
            dedupIds.remove(old)
        }
        return true
    }

    private func startPruneTimer() {
        DispatchQueue.main.async { [weak self] in
            self?.pruneTimer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in
                self?.pruneOldDedup()
            }
        }
    }

    private func pruneOldDedup() {
        bleQueue.async { [weak self] in
            guard let self else { return }
            while self.dedupQueue.count > self.maxDedupEntries / 2, let old = self.dedupQueue.first {
                self.dedupQueue.removeFirst()
                self.dedupIds.remove(old)
            }
        }
    }

    // MARK: - Send / relay

    private func broadcastEnvelope(
        _ envelope: MeshEnvelope,
        excludeCentral: CBCentral?,
        excludePeripheral: CBPeripheral?
    ) {
        guard let data = MeshEnvelope.encodeJSON(envelope), data.count <= 512 else {
            log("Envelope too large or encode failed")
            return
        }
        if let char = meshCharacteristic, !subscribedCentrals.isEmpty {
            if let ex = excludeCentral {
                let others = subscribedCentrals.filter { $0.identifier != ex.identifier }
                if !others.isEmpty {
                    _ = peripheral.updateValue(data, for: char, onSubscribedCentrals: others)
                }
            } else {
                _ = peripheral.updateValue(data, for: char, onSubscribedCentrals: nil)
            }
        }
        for remote in connectedRemotes where remote !== excludePeripheral {
            guard let c = remoteCharacteristics[remote.identifier] else { continue }
            remote.writeValue(data, for: c, type: .withResponse)
        }
        log("Sent/relay \(envelope.id) ttl=\(envelope.ttl)")
    }

    private func handleIncomingData(_ data: Data, sourceCentral: CBCentral?, sourcePeripheral: CBPeripheral?) {
        guard let env = MeshEnvelope.decodeJSON(data) else {
            log("Drop: decode failed")
            return
        }
        guard markSeen(env.id) else {
            log("Drop dedup \(env.id)")
            return
        }
        switch env.type {
        case .announce:
            if let a = try? JSONDecoder().decode(AnnouncementPayload.self, from: env.payload) {
                DispatchQueue.main.async { [weak self] in
                    self?.announceNicknames[env.senderID] = a.nickname
                }
                log("Announce \(a.nickname)")
            }
        case .message:
            if let chat = try? JSONDecoder().decode(ChatPayload.self, from: env.payload) {
                DispatchQueue.main.async { [weak self] in
                    self?.chatMessages.append(
                        ChatMessage(
                            id: UUID(),
                            envelopeId: env.id,
                            senderID: env.senderID,
                            senderName: env.senderName,
                            text: chat.text,
                            date: Date(),
                            isLocal: env.senderID == self?.identity.deviceID
                        )
                    )
                }
            }
        }
        if env.ttl > 1 {
            var relay = env
            relay.ttl = env.ttl - 1
            let delay = TimeInterval(Double.random(in: 0.05...0.15))
            bleQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.broadcastEnvelope(relay, excludeCentral: sourceCentral, excludePeripheral: sourcePeripheral)
            }
        }
    }

    private func appendLocalChat(envelope: MeshEnvelope, text: String) {
        DispatchQueue.main.async { [weak self] in
            self?.chatMessages.append(
                ChatMessage(
                    id: UUID(),
                    envelopeId: envelope.id,
                    senderID: envelope.senderID,
                    senderName: envelope.senderName,
                    text: text,
                    date: Date(),
                    isLocal: true
                )
            )
        }
    }

    private func sendAnnounce(to centrals: [CBCentral]? = nil) {
        guard let nickData = try? JSONEncoder().encode(AnnouncementPayload(nickname: identity.nickname)) else { return }
        let env = MeshEnvelope(
            id: UUID(),
            type: .announce,
            senderID: identity.deviceID,
            senderName: identity.nickname,
            timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
            ttl: 2,
            payload: nickData
        )
        guard let data = MeshEnvelope.encodeJSON(env) else { return }
        if let char = meshCharacteristic {
            if let centrals {
                _ = peripheral.updateValue(data, for: char, onSubscribedCentrals: centrals)
            } else {
                _ = peripheral.updateValue(data, for: char, onSubscribedCentrals: nil)
            }
        }
    }

    private func log(_ s: String) {
        let line = "[\(Self.timestamp())] \(s)"
        DispatchQueue.main.async { [weak self] in
            self?.debugLines.append(line)
            if (self?.debugLines.count ?? 0) > 120 {
                self?.debugLines.removeFirst((self?.debugLines.count ?? 121) - 120)
            }
        }
    }

    private static func timestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: Date())
    }

    private func refreshConnectedNames() {
        let names = connectedRemotes.map { $0.name ?? $0.identifier.uuidString }
        let rows = connectedRemotes.map { p in
            MeshDebugConnectionRow(
                id: p.identifier,
                name: p.name ?? p.identifier.uuidString,
                rssi: 0,
                state: remoteCharacteristics[p.identifier] != nil ? "notify on" : "connecting…"
            )
        }
        DispatchQueue.main.async { [weak self] in
            self?.connectedPeerNames = names
            self?.debugConnectionRows = rows
            self?.readyRemoteCount = self?.remoteCharacteristics.count ?? 0
        }
    }

    private func publishDiscoveredPeer(id: UUID, name: String, rssi: Int, linkState: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if let idx = self.discoveredPeers.firstIndex(where: { $0.id == id }) {
                self.discoveredPeers[idx].name = name
                self.discoveredPeers[idx].rssi = rssi
                self.discoveredPeers[idx].linkState = linkState
            } else {
                self.discoveredPeers.append(DiscoveredPeer(id: id, name: name, rssi: rssi, nickname: nil, linkState: linkState))
            }
        }
    }
}

// MARK: - CBCentralManagerDelegate

extension BluetoothMeshService: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        DispatchQueue.main.async { [weak self] in
            self?.bluetoothState = central.state
        }
        log("Central state \(central.state.rawValue)")
        switch central.state {
        case .poweredOn:
            setupPeripheralIfPowered()
            scheduleScanCycle()
        case .poweredOff, .unauthorized, .unsupported:
            stop()
        default:
            break
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = peripheral.name ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? "Mesh peer"
        let id = peripheral.identifier
        discoveredPeripheralRefs[id] = peripheral

        let connected = connectedRemotes.contains(where: { $0.identifier == id })
        let connecting = connectingIds.contains(id)
        let linkState: String
        if connected { linkState = "connected" }
        else if connecting { linkState = "connecting" }
        else { linkState = "discovered" }

        publishDiscoveredPeer(id: id, name: name, rssi: RSSI.intValue, linkState: linkState)

        if autoConnectEnabled, !connected, !connecting {
            connectPeripheral(peripheral, reason: "auto")
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        connectingIds.remove(peripheral.identifier)
        log("Connected \(peripheral.identifier)")
        if !connectedRemotes.contains(where: { $0.identifier == peripheral.identifier }) {
            connectedRemotes.append(peripheral)
        }
        peripheral.delegate = self
        peripheral.discoverServices([kMeshServiceUUID])
        publishDiscoveredPeer(
            id: peripheral.identifier,
            name: peripheral.name ?? "Mesh peer",
            rssi: 0,
            linkState: "connected"
        )
        refreshConnectedNames()
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        connectingIds.remove(peripheral.identifier)
        log("Fail connect \(peripheral.identifier) \(error?.localizedDescription ?? "")")
        publishDiscoveredPeer(
            id: peripheral.identifier,
            name: peripheral.name ?? "?",
            rssi: 0,
            linkState: "failed"
        )
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        connectingIds.remove(peripheral.identifier)
        log("Disconnected \(peripheral.identifier) \(error?.localizedDescription ?? "")")
        remoteCharacteristics.removeValue(forKey: peripheral.identifier)
        connectedRemotes.removeAll { $0.identifier == peripheral.identifier }
        publishDiscoveredPeer(
            id: peripheral.identifier,
            name: peripheral.name ?? "?",
            rssi: 0,
            linkState: "disconnected"
        )
        refreshConnectedNames()
        guard autoConnectEnabled, autoReconnectEnabled else { return }
        let id = peripheral.identifier
        if let p = discoveredPeripheralRefs[id] {
            let minGap: TimeInterval = 8
            if let last = lastReconnectAttempt[id], Date().timeIntervalSince(last) < minGap { return }
            lastReconnectAttempt[id] = Date()
            bleQueue.asyncAfter(deadline: .now() + 5) { [weak self] in
                guard let self else { return }
                if self.connectedRemotes.contains(where: { $0.identifier == id }) { return }
                self.connectPeripheral(p, reason: "reconnect")
            }
        }
    }
}

// MARK: - CBPeripheralDelegate

extension BluetoothMeshService: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            log("Discover services \(error.localizedDescription)")
            return
        }
        guard let svc = peripheral.services?.first(where: { $0.uuid == kMeshServiceUUID }) else {
            log("Service missing — retry discover")
            peripheral.discoverServices(nil)
            return
        }
        peripheral.discoverCharacteristics([kMeshCharUUID], for: svc)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error {
            log("Discover chars \(error.localizedDescription)")
            return
        }
        guard let c = service.characteristics?.first(where: { $0.uuid == kMeshCharUUID }) else { return }
        remoteCharacteristics[peripheral.identifier] = c
        peripheral.setNotifyValue(true, for: c)
        log("Notify enabled \(peripheral.identifier)")
        refreshConnectedNames()
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            log("Notify state \(error.localizedDescription)")
        } else {
            log("Notify state OK \(peripheral.identifier) isNotifying=\(characteristic.isNotifying)")
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            log("Notify value \(error.localizedDescription)")
            return
        }
        guard let data = characteristic.value else { return }
        handleIncomingData(data, sourceCentral: nil, sourcePeripheral: peripheral)
    }
}

// MARK: - CBPeripheralManagerDelegate

extension BluetoothMeshService: CBPeripheralManagerDelegate {
    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        DispatchQueue.main.async { [weak self] in
            self?.bluetoothState = peripheral.state
        }
        log("Peripheral mgr \(peripheral.state.rawValue)")
        if peripheral.state != .poweredOn {
            gattServicePublished = false
            meshCharacteristic = nil
            subscribedCentrals = []
            DispatchQueue.main.async { [weak self] in self?.subscribedCentralCount = 0 }
        } else {
            setupPeripheralIfPowered()
            if central.state == .poweredOn { scheduleScanCycle() }
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        if let error { log("Add service \(error.localizedDescription)") }
    }

    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        if let error { log("Advertise \(error.localizedDescription)") }
        else { log("Advertising OK") }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didSubscribeTo characteristic: CBCharacteristic) {
        if !subscribedCentrals.contains(where: { $0.identifier == central.identifier }) {
            subscribedCentrals.append(central)
        }
        DispatchQueue.main.async { [weak self] in
            self?.subscribedCentralCount = self?.subscribedCentrals.count ?? 0
        }
        log("Central subscribed (\(subscribedCentrals.count))")
        sendAnnounce(to: [central])
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didUnsubscribeFrom characteristic: CBCharacteristic) {
        subscribedCentrals.removeAll { $0.identifier == central.identifier }
        DispatchQueue.main.async { [weak self] in
            self?.subscribedCentralCount = self?.subscribedCentrals.count ?? 0
        }
    }

    func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
        log("Ready update subscribers")
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        for req in requests {
            if req.characteristic.uuid == kMeshCharUUID, let data = req.value {
                handleIncomingData(data, sourceCentral: req.central, sourcePeripheral: nil)
            }
            peripheral.respond(to: req, withResult: .success)
        }
    }
}
