import Foundation
import CoreBluetooth
import CoreLocation
import UserNotifications
import UIKit

// MARK: - GATT UUIDs (single service + single characteristic)
private let kMeshServiceUUID = CBUUID(string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E")
private let kMeshCharUUID = CBUUID(string: "6E400002-B5A3-F393-E0A9-E50E24DCCA9E")

/// Discovered peripheral shown in UI. **publicKey** set after direct announce (canonical contact id).
struct DiscoveredPeer: Identifiable, Equatable, Hashable {
    let id: UUID
    var name: String
    var rssi: Int
    var nickname: String?
    var linkState: String
    var publicKey: Data?
    var lastSeen: Int64
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
    /// Bump so dashboard/contacts reload after save.
    @Published var contactsVersion = UUID()
    /// Last known coordinates for distance display; updated when shareLocation is on.
    @Published private(set) var lastKnownLocation: (lat: Double, lon: Double)?
    /// Sender ID → (lat, lon) from received envelopes (only when senders share location).
    @Published var senderCoordinates: [String: (lat: Double, lon: Double)] = [:]

    /// Map labels (id → payload); shared via .mapLabel envelopes.
    @Published var mapLabels: [UUID: MapLabelPayload] = [:]
    /// Label votes: labelId → (voterID → 1 or -1); shared via .mapLabelVote envelopes.
    @Published var labelVotes: [UUID: [String: Int]] = [:]

    /// Seconds remaining before this user can post another map label (30s cooldown).
    @Published var mapLabelCooldownRemaining: Double = 0

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

    /// Group chat label: saved contact nickname if we know this sender's key; else announce / envelope name.
    func senderDisplayName(senderID: String, fallbackSenderName: String) -> String {
        if senderID == identity.deviceID { return identity.nickname }
        if let nick = DatabaseManager.shared.savedNickname(forSenderID: senderID) {
            return nick
        }
        return announceNicknames[senderID] ?? fallbackSenderName
    }

    private let central: CBCentralManager
    private let peripheral: CBPeripheralManager
    private let bleQueue = DispatchQueue(label: "meshchat.ble")
    private let locationManager = CLLocationManager()

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
    /// Single upsert map for discovered peers (avoids duplicate rows from concurrent main-queue updates).
    private var discoveredPeerById: [UUID: DiscoveredPeer] = [:]
    /// Peripheral id → peer Curve25519 public key (from announce on that link).
    private var peerPublicKeyByPeripheralId: [UUID: Data] = [:]
    private var scanIdleWorkItem: DispatchWorkItem?
    private var scanCountdownTimer: Timer?
    private var nextScanDeadline: Date?
    /// Read on bleQueue only (UI copies in via syncScanTimingFromUI).
    private var bleScanWindow: Double = 12
    private var bleScanIdle: Double = 40

    private let defaultTTL: UInt8 = 5
    /// Max JSON size per BLE write (mesh policy).
    static let meshEnvelopeMaxBytes = 512
    /// Raw JPEG bytes per `ImageChunkPayload` (whole mesh packet must stay ≤ `meshEnvelopeMaxBytes`).
    static let imageChunkByteSize = 40
    private static let imageChunkRawBytes = imageChunkByteSize
    /// Reassembly buffers (main thread).
    private var pendingImages: [UUID: PendingImageChunkBuffer] = [:]

    private struct PendingImageChunkBuffer {
        var total: UInt16
        var parts: [UInt16: Data]
        var senderID: String
        var senderName: String
    }

    private let mapLabelCooldownSeconds: TimeInterval = 30
    private var lastMapLabelSendTime: Date?
    private var mapLabelCooldownTimer: Timer?

    override init() {
        _ = KeyManager.publicKeyData
        identity = DeviceIdentity.load()
        central = CBCentralManager(delegate: nil, queue: bleQueue, options: [CBCentralManagerOptionShowPowerAlertKey: true])
        peripheral = CBPeripheralManager(delegate: nil, queue: bleQueue)
        super.init()
        central.delegate = self
        peripheral.delegate = self
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        locationManager.requestWhenInUseAuthorization()
        startPruneTimer()
        requestNotificationAuthIfNeeded()
    }

    deinit {
        pruneTimer?.invalidate()
        scanCountdownTimer?.invalidate()
        scanIdleWorkItem?.cancel()
        mapLabelCooldownTimer?.invalidate()
    }

    func updateIdentity(_ id: DeviceIdentity) {
        identity = id
        id.save()
        if id.shareLocation {
            locationManager.startUpdatingLocation()
        } else {
            locationManager.stopUpdatingLocation()
            DispatchQueue.main.async { [weak self] in
                self?.lastKnownLocation = nil
            }
        }
        log("Identity saved; advertising name updated.")
        bleQueue.async { [weak self] in self?.restartAdvertisingOnly() }
    }

    func start() {
        requestNotificationPermissionForLabels()
        DispatchQueue.main.async { [weak self] in
            UNUserNotificationCenter.current().delegate = self
        }
        if identity.shareLocation {
            locationManager.startUpdatingLocation()
        }
        loadPersistedMessages()
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

    /// Load the last 200 broadcast messages from the DB into the in-memory chat list.
    private func loadPersistedMessages() {
        let db = DatabaseManager.shared
        guard let persisted = try? db.messages(channel: "broadcast", limit: 200) else { return }
        let myID = identity.deviceID
        let loaded = persisted.map { m in
            m.toChatMessage(isLocal: m.senderID == myID)
        }
        DispatchQueue.main.async { [weak self] in
            self?.chatMessages = loaded
        }
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
        var env = MeshEnvelope(
            id: UUID(),
            type: .message,
            senderID: identity.deviceID,
            senderName: identity.nickname,
            timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
            ttl: defaultTTL,
            payload: payloadData,
            senderLatitude: nil,
            senderLongitude: nil
        )
        if identity.shareLocation, let loc = lastKnownLocation {
            env.senderLatitude = loc.lat
            env.senderLongitude = loc.lon
        }
        let persisted = PersistedMessage(
            id: env.id.uuidString,
            senderID: env.senderID,
            senderName: env.senderName,
            text: trimmed,
            timestamp: Int64(env.timestamp),
            channel: "broadcast",
            receivedAt: Int64(Date().timeIntervalSince1970)
        )
        try? DatabaseManager.shared.upsertContact(id: identity.deviceID, nickname: identity.nickname)
        try? DatabaseManager.shared.saveMessage(persisted)
        let envCopy = env
        let textCopy = trimmed
        bleQueue.async { [weak self] in
            guard let self else { return }
            _ = self.markSeen(envCopy.id)
            _ = self.broadcastEnvelope(envCopy, excludeCentral: nil, excludePeripheral: nil)
        }
        appendLocalChat(envelope: envCopy, text: textCopy, imageJPEGBase64: nil)
    }

    /// Compress, chunk, flood JPEG (no encryption). Best-effort over BLE size limit.
    /// - Parameter completion: Called on main when finished; argument is packets sent (0 if nothing sent).
    func sendImage(jpegData: Data, completion: ((Int) -> Void)? = nil) {
        guard !jpegData.isEmpty, jpegData.count <= MeshImageUtils.maxJPEGBytes else {
            log("Image send: empty or too large")
            DispatchQueue.main.async { completion?(0) }
            return
        }
        let transferId = UUID()
        let chunkSize = Self.imageChunkRawBytes
        let total = UInt16((jpegData.count + chunkSize - 1) / chunkSize)
        var envelopes: [MeshEnvelope] = []
        for i in 0..<Int(total) {
            let start = i * chunkSize
            let end = min(start + chunkSize, jpegData.count)
            let slice = jpegData.subdata(in: start..<end)
            let chunk = ImageChunkPayload(transferId: transferId, chunkIndex: UInt16(i), totalChunks: total, data: slice)
            guard let payloadData = try? JSONEncoder().encode(chunk) else { continue }
            var env = MeshEnvelope(
                id: UUID(),
                type: .imageChunk,
                senderID: identity.deviceID,
                senderName: identity.nickname,
                timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
                ttl: defaultTTL,
                payload: payloadData,
                senderLatitude: nil,
                senderLongitude: nil
            )
            if identity.shareLocation, let loc = lastKnownLocation {
                env.senderLatitude = loc.lat
                env.senderLongitude = loc.lon
            }
            envelopes.append(env)
        }
        guard !envelopes.isEmpty else {
            DispatchQueue.main.async { completion?(0) }
            return
        }
        let firstEnv = envelopes[0]
        let imageB64 = jpegData.base64EncodedString()
        let persisted = PersistedMessage(
            id: firstEnv.id.uuidString,
            senderID: firstEnv.senderID,
            senderName: firstEnv.senderName,
            text: "[photo]",
            timestamp: Int64(firstEnv.timestamp),
            channel: "broadcast",
            receivedAt: Int64(Date().timeIntervalSince1970),
            imageBase64: imageB64
        )
        try? DatabaseManager.shared.upsertContact(id: identity.deviceID, nickname: identity.nickname)
        try? DatabaseManager.shared.saveMessage(persisted)
        let n = envelopes.count
        bleQueue.async { [weak self] in
            guard let self else {
                DispatchQueue.main.async { completion?(0) }
                return
            }
            for env in envelopes {
                _ = self.markSeen(env.id)
                _ = self.broadcastEnvelope(env, excludeCentral: nil, excludePeripheral: nil)
                Thread.sleep(forTimeInterval: 0.02)
            }
            DispatchQueue.main.async { completion?(n) }
        }
        appendLocalChat(envelope: firstEnv, text: "[photo]", imageJPEGBase64: imageB64)
    }

    /// Call from main. Returns false if on cooldown (30s); true if send was queued.
    func sendMapLabel(category: LabelCategory, lat: Double, lon: Double) -> Bool {
        if mapLabelCooldownRemaining > 0 {
            log("Map label: cooldown (\(Int(mapLabelCooldownRemaining))s left)")
            return false
        }
        lastMapLabelSendTime = Date()
        mapLabelCooldownRemaining = mapLabelCooldownSeconds
        startMapLabelCooldownTimer()

        let payload = MapLabelPayload(
            id: UUID(),
            category: category.rawValue,
            lat: lat,
            lon: lon,
            senderID: identity.deviceID,
            senderName: String(identity.nickname.prefix(32)),
            timestamp: UInt64(Date().timeIntervalSince1970 * 1000)
        )
        guard let payloadData = try? JSONEncoder().encode(payload) else {
            log("Map label: encode payload failed")
            return false
        }
        var env = MeshEnvelope(
            id: UUID(),
            type: .mapLabel,
            senderID: identity.deviceID,
            senderName: String(identity.nickname.prefix(32)),
            timestamp: payload.timestamp,
            ttl: defaultTTL,
            payload: payloadData,
            senderLatitude: nil,
            senderLongitude: nil
        )
        if identity.shareLocation, let loc = lastKnownLocation {
            env.senderLatitude = loc.lat
            env.senderLongitude = loc.lon
        }
        DispatchQueue.main.async { [weak self] in
            self?.mapLabels[payload.id] = payload
        }
        bleQueue.async { [weak self] in
            if self?.broadcastEnvelope(env, excludeCentral: nil, excludePeripheral: nil) == true {
                self?.log("Map label sent \(payload.id)")
            }
        }
        return true
    }

    private func startMapLabelCooldownTimer() {
        mapLabelCooldownTimer?.invalidate()
        mapLabelCooldownTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, let last = self.lastMapLabelSendTime else { return }
            let elapsed = Date().timeIntervalSince(last)
            let remaining = self.mapLabelCooldownSeconds - elapsed
            if remaining <= 0 {
                self.mapLabelCooldownRemaining = 0
                self.mapLabelCooldownTimer?.invalidate()
                self.mapLabelCooldownTimer = nil
            } else {
                self.mapLabelCooldownRemaining = remaining
            }
        }
        RunLoop.main.add(mapLabelCooldownTimer!, forMode: .common)
    }

    /// Call early (e.g. from start()) so label notifications can be shown.
    func requestNotificationPermissionForLabels() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    private func notifyLabelReceived(categoryDisplayName: String, from senderName: String) {
        let content = UNMutableNotificationContent()
        content.title = "New map label"
        content.body = "\(categoryDisplayName) from \(senderName)"
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: UNTimeIntervalNotificationTrigger(timeInterval: 0.1, repeats: false))
        UNUserNotificationCenter.current().add(request)
    }

    func voteForLabel(labelId: UUID, up: Bool) {
        let vote = up ? 1 : -1
        let payload = MapLabelVotePayload(labelId: labelId, vote: vote, voterID: identity.deviceID)
        guard let payloadData = try? JSONEncoder().encode(payload) else { return }
        let env = MeshEnvelope(
            id: UUID(),
            type: .mapLabelVote,
            senderID: identity.deviceID,
            senderName: identity.nickname,
            timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
            ttl: defaultTTL,
            payload: payloadData,
            senderLatitude: nil,
            senderLongitude: nil
        )
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.labelVotes[labelId] == nil {
                self.labelVotes[labelId] = [:]
            }
            self.labelVotes[labelId]?[self.identity.deviceID] = vote
        }
        bleQueue.async { [weak self] in
            _ = self?.broadcastEnvelope(env, excludeCentral: nil, excludePeripheral: nil)
        }
    }

    func sendAlert(type: Alert.AlertType, severity: Int, lat: Double, lon: Double, description: String) {
        let now = Int64(Date().timeIntervalSince1970)
        let alertID = UUID().uuidString
        let payload = AlertPayload(
            alertID: alertID,
            type: type,
            severity: severity,
            lat: lat,
            lon: lon,
            description: description,
            createdAt: now,
            expiresAt: Alert.defaultExpiresAt(for: type)
        )
        guard let payloadData = try? JSONEncoder().encode(payload) else { return }
        let env = MeshEnvelope(
            id: UUID(),
            type: .alert,
            senderID: identity.deviceID,
            senderName: identity.nickname,
            timestamp: UInt64(now * 1000),
            ttl: defaultTTL,
            payload: payloadData,
            senderLatitude: identity.shareLocation ? lastKnownLocation?.lat : nil,
            senderLongitude: identity.shareLocation ? lastKnownLocation?.lon : nil
        )
        // Persist locally before broadcasting
        let alert = Alert(
            id: alertID,
            authorID: identity.deviceID,
            type: type,
            severity: severity,
            lat: lat,
            lon: lon,
            description: description,
            createdAt: now,
            expiresAt: payload.expiresAt,
            trustScore: 1.0     // author fully trusts their own alert
        )
        try? DatabaseManager.shared.upsertContact(id: identity.deviceID, nickname: identity.nickname)
        try? DatabaseManager.shared.saveAlert(alert)
        broadcastEnvelope(env, excludeCentral: nil, excludePeripheral: nil)
        log("Alert sent: \(type.rawValue) sev=\(severity)")
    }

    func sendVouch(alertID: String, confirms: Bool) {
        let value = confirms ? 1 : -1
        let payload = VouchPayload(alertID: alertID, value: value)
        guard let payloadData = try? JSONEncoder().encode(payload) else { return }
        let env = MeshEnvelope(
            id: UUID(),
            type: .vouch,
            senderID: identity.deviceID,
            senderName: identity.nickname,
            timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
            ttl: defaultTTL,
            payload: payloadData,
            senderLatitude: nil,
            senderLongitude: nil
        )
        let vouch = Vouch(alertID: alertID, voucherID: identity.deviceID,
                          value: value, timestamp: Int64(Date().timeIntervalSince1970))
        try? DatabaseManager.shared.upsertContact(id: identity.deviceID, nickname: identity.nickname)
        try? DatabaseManager.shared.saveVouch(vouch)
        try? DatabaseManager.shared.recomputeTrustScore(alertID: alertID)
        broadcastEnvelope(env, excludeCentral: nil, excludePeripheral: nil)
        log("Vouch sent: alertID=\(alertID) value=\(value)")
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

    /// Returns true if the envelope was sent (under size limit and encoded).
    private func broadcastEnvelope(
        _ envelope: MeshEnvelope,
        excludeCentral: CBCentral?,
        excludePeripheral: CBPeripheral?
    ) -> Bool {
        guard let data = MeshEnvelope.encodeJSON(envelope) else {
            log("Envelope encode failed")
            return false
        }
        guard data.count <= 512 else {
            log("Envelope too large (\(data.count) bytes, max 512)")
            return false
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
        return true
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
        // Always upsert the sender as a contact
        try? DatabaseManager.shared.upsertContact(id: env.senderID, nickname: env.senderName)

        switch env.type {
        case .announce:
            if let a = try? JSONDecoder().decode(AnnouncementPayload.self, from: env.payload) {
                var pk: Data?
                if let b64 = a.publicKeyBase64, let d = Data(base64Encoded: b64), d.count == 32 { pk = d }
                else { pk = KeyManager.decodePublicKeyBase64(env.senderID) }
                if let key = pk, let peripheral = sourcePeripheral {
                    peerPublicKeyByPeripheralId[peripheral.identifier] = key
                    try? DatabaseManager.shared.updateLastSeenForPublicKey(key)
                    DispatchQueue.main.async { [weak self] in
                        self?.publishDiscoveredPeer(
                            id: peripheral.identifier,
                            name: peripheral.name ?? a.nickname,
                            rssi: 0,
                            linkState: self?.discoveredPeerById[peripheral.identifier]?.linkState ?? "discovered",
                            publicKey: key
                        )
                    }
                }
                DispatchQueue.main.async { [weak self] in
                    self?.announceNicknames[env.senderID] = a.nickname
                }
                log("Announce \(a.nickname)")
            }
        case .message:
            if let chat = try? JSONDecoder().decode(ChatPayload.self, from: env.payload) {
                let envCopy = env
                let persisted = PersistedMessage(
                    id: env.id.uuidString,
                    senderID: env.senderID,
                    senderName: env.senderName,
                    text: chat.text,
                    timestamp: Int64(env.timestamp),
                    channel: "broadcast",
                    receivedAt: Int64(Date().timeIntervalSince1970)
                )
                try? DatabaseManager.shared.saveMessage(persisted)
                let skipAppend = envCopy.senderID == identity.deviceID
                if !skipAppend {
                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        let distance = self.distanceFromMe(senderID: envCopy.senderID)
                        self.appendChatMessage(
                            ChatMessage(
                                id: UUID(),
                                envelopeId: envCopy.id,
                                senderID: envCopy.senderID,
                                senderName: envCopy.senderName,
                                text: chat.text,
                                date: Date(),
                                isLocal: false,
                                distanceFromMe: distance,
                                imageJPEGBase64: nil
                            )
                        )
                        self.notifyIncomingIfNeeded(sender: envCopy.senderName, text: chat.text)
                    }
                }
            }
        case .imageChunk:
            if let chunk = try? JSONDecoder().decode(ImageChunkPayload.self, from: env.payload) {
                let fromSelf = env.senderID == identity.deviceID
                if !fromSelf {
                    DispatchQueue.main.async { [weak self] in
                        self?.mergeImageChunk(env: env, chunk: chunk)
                    }
                }
            }
        case .mapLabel:
            if let wire = try? JSONDecoder().decode(MapLabelPayload.self, from: env.payload) {
                let payload = MapLabelPayload(
                    id: wire.id,
                    category: wire.category,
                    lat: wire.lat,
                    lon: wire.lon,
                    senderID: env.senderID,
                    senderName: env.senderName,
                    timestamp: wire.timestamp
                )
                let categoryDisplay = LabelCategory(rawValue: wire.category)?.displayName ?? wire.category
                let senderName = env.senderName
                let senderID = env.senderID
                let isLiveBroadcast = env.ttl > 1
                DispatchQueue.main.async { [weak self] in
                    self?.mapLabels[payload.id] = payload
                    if let self, senderID != self.identity.deviceID, isLiveBroadcast {
                        self.notifyLabelReceived(categoryDisplayName: categoryDisplay, from: senderName)
                    }
                }
                log("Map label received \(payload.id) from \(env.senderName)")
            } else {
                log("Map label: decode payload failed")
            }
        case .mapLabelVote:
            if let payload = try? JSONDecoder().decode(MapLabelVotePayload.self, from: env.payload),
               payload.vote == 1 || payload.vote == -1 {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    if self.labelVotes[payload.labelId] == nil {
                        self.labelVotes[payload.labelId] = [:]
                    }
                    self.labelVotes[payload.labelId]?[payload.voterID] = payload.vote
                }
            }
        case .requestMapLabels:
            if let central = sourceCentral {
                pushMapLabelsToCentral(central)
                log("Request map labels from central \(central.identifier)")
            }
        case .alert:
            if let payload = try? JSONDecoder().decode(AlertPayload.self, from: env.payload) {
                let alert = Alert(
                    id: payload.alertID,
                    authorID: env.senderID,
                    type: payload.type,
                    severity: payload.severity,
                    lat: payload.lat,
                    lon: payload.lon,
                    description: payload.description,
                    createdAt: payload.createdAt,
                    expiresAt: payload.expiresAt,
                    trustScore: 0.0
                )
                try? DatabaseManager.shared.saveAlert(alert)
                log("Alert received: \(payload.type.rawValue) sev=\(payload.severity) from \(env.senderName)")
            }
        case .vouch:
            if let payload = try? JSONDecoder().decode(VouchPayload.self, from: env.payload) {
                let vouch = Vouch(
                    alertID: payload.alertID,
                    voucherID: env.senderID,
                    value: payload.value,
                    timestamp: Int64(Date().timeIntervalSince1970)
                )
                try? DatabaseManager.shared.saveVouch(vouch)
                try? DatabaseManager.shared.recomputeTrustScore(alertID: payload.alertID)
                log("Vouch received: alertID=\(payload.alertID) value=\(payload.value) from \(env.senderName)")
            }
        }
        if let lat = env.senderLatitude, let lon = env.senderLongitude {
            DispatchQueue.main.async { [weak self] in
                self?.senderCoordinates[env.senderID] = (lat, lon)
            }
            try? DatabaseManager.shared.recordSighting(nodeID: env.senderID, lat: lat, lon: lon, rssi: 0)
        }
        if env.ttl > 1, env.type != .requestMapLabels {
            var relay = env
            relay.ttl = env.ttl - 1
            let delay = TimeInterval(Double.random(in: 0.05...0.15))
            bleQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
                _ = self?.broadcastEnvelope(relay, excludeCentral: sourceCentral, excludePeripheral: sourcePeripheral)
            }
        }
    }

    private func appendLocalChat(envelope: MeshEnvelope, text: String, imageJPEGBase64: String?) {
        DispatchQueue.main.async { [weak self] in
            self?.appendChatMessage(
                ChatMessage(
                    id: UUID(),
                    envelopeId: envelope.id,
                    senderID: envelope.senderID,
                    senderName: envelope.senderName,
                    text: text,
                    date: Date(),
                    isLocal: true,
                    distanceFromMe: nil,
                    imageJPEGBase64: imageJPEGBase64
                )
            )
        }
    }

    private func mergeImageChunk(env: MeshEnvelope, chunk: ImageChunkPayload) {
        var buf = pendingImages[chunk.transferId] ?? PendingImageChunkBuffer(
            total: chunk.totalChunks,
            parts: [:],
            senderID: env.senderID,
            senderName: env.senderName
        )
        if buf.total != chunk.totalChunks { buf.total = chunk.totalChunks }
        buf.parts[chunk.chunkIndex] = chunk.data
        pendingImages[chunk.transferId] = buf
        guard buf.parts.count == Int(buf.total) else { return }
        var full = Data()
        for i in 0..<Int(buf.total) {
            guard let p = buf.parts[UInt16(i)] else { return }
            full.append(p)
        }
        pendingImages.removeValue(forKey: chunk.transferId)
        guard full.count > 100 else { return } // min sane JPEG
        let distance = distanceFromMe(senderID: env.senderID)
        let b64 = full.base64EncodedString()
        let persisted = PersistedMessage(
            id: env.id.uuidString,
            senderID: env.senderID,
            senderName: env.senderName,
            text: "[photo]",
            timestamp: Int64(env.timestamp),
            channel: "broadcast",
            receivedAt: Int64(Date().timeIntervalSince1970),
            imageBase64: b64
        )
        try? DatabaseManager.shared.upsertContact(id: env.senderID, nickname: env.senderName)
        try? DatabaseManager.shared.saveMessage(persisted)
        appendChatMessage(
            ChatMessage(
                id: UUID(),
                envelopeId: env.id,
                senderID: env.senderID,
                senderName: env.senderName,
                text: "[photo]",
                date: Date(),
                isLocal: false,
                distanceFromMe: distance,
                imageJPEGBase64: b64
            )
        )
        notifyIncomingIfNeeded(sender: env.senderName, text: "[Photo]")
    }

    private func appendChatMessage(_ m: ChatMessage) {
        chatMessages.append(m)
    }

    private func requestNotificationAuthIfNeeded() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    private func notifyIncomingIfNeeded(sender: String, text: String) {
        let state = UIApplication.shared.applicationState
        guard state != .active else { return }
        let content = UNMutableNotificationContent()
        content.title = sender
        content.body = text
        content.sound = .default
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }

    /// Haversine distance in meters between two WGS84 coordinates.
    private static func haversineMeters(lat1: Double, lon1: Double, lat2: Double, lon2: Double) -> Double {
        let R = 6_371_000.0 // Earth radius in meters
        let toRad = { (d: Double) in d * .pi / 180 }
        let dLat = toRad(lat2 - lat1)
        let dLon = toRad(lon2 - lon1)
        let a = sin(dLat / 2) * sin(dLat / 2) +
            cos(toRad(lat1)) * cos(toRad(lat2)) * sin(dLon / 2) * sin(dLon / 2)
        let c = 2 * atan2(sqrt(a), sqrt(1 - a))
        return R * c
    }

    /// Distance in meters from this device to the sender; nil if unknown.
    private func distanceFromMe(senderID: String) -> Double? {
        guard senderID != identity.deviceID,
              let my = lastKnownLocation,
              let other = senderCoordinates[senderID] else { return nil }
        return Self.haversineMeters(lat1: my.lat, lon1: my.lon, lat2: other.lat, lon2: other.lon)
    }

    /// Build announce envelope on main so we can include location if shareLocation is on.
    private func buildAnnounceEnvelope() -> MeshEnvelope? {
        let payload = AnnouncementPayload(
            nickname: identity.nickname,
            publicKeyBase64: KeyManager.publicKeyData.base64EncodedString()
        )
        guard let nickData = try? JSONEncoder().encode(payload) else { return nil }
        var env = MeshEnvelope(
            id: UUID(),
            type: .announce,
            senderID: identity.deviceID,
            senderName: identity.nickname,
            timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
            ttl: 2,
            payload: nickData,
            senderLatitude: nil,
            senderLongitude: nil
        )
        if identity.shareLocation, let loc = lastKnownLocation {
            env.senderLatitude = loc.lat
            env.senderLongitude = loc.lon
        }
        return env
    }

    private func broadcastAnnounce(_ envelope: MeshEnvelope, to centrals: [CBCentral]?) {
        guard let data = MeshEnvelope.encodeJSON(envelope), data.count <= 512 else { return }
        if let char = meshCharacteristic {
            if let centrals {
                _ = peripheral.updateValue(data, for: char, onSubscribedCentrals: centrals)
            } else {
                _ = peripheral.updateValue(data, for: char, onSubscribedCentrals: nil)
            }
        }
    }

    /// Send a single envelope only to the given centrals (e.g. push labels to a new subscriber).
    private func broadcastEnvelopeToCentrals(_ envelope: MeshEnvelope, centrals: [CBCentral]) {
        guard let data = MeshEnvelope.encodeJSON(envelope), data.count <= 512 else { return }
        guard let char = meshCharacteristic, !centrals.isEmpty else { return }
        _ = peripheral.updateValue(data, for: char, onSubscribedCentrals: centrals)
    }

    private func sendAnnounce(to centrals: [CBCentral]? = nil) {
        DispatchQueue.main.async { [weak self] in
            guard let self, let env = self.buildAnnounceEnvelope() else { return }
            self.bleQueue.async { [weak self] in
                self?.broadcastAnnounce(env, to: centrals)
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

    func publishDiscoveredPeer(id: UUID, name: String, rssi: Int, linkState: String, publicKey: Data? = nil) {
        let now = Int64(Date().timeIntervalSince1970)
        let pk = publicKey ?? peerPublicKeyByPeripheralId[id]
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            var p = self.discoveredPeerById[id] ?? DiscoveredPeer(
                id: id, name: name, rssi: rssi, nickname: nil, linkState: linkState, publicKey: nil, lastSeen: now
            )
            p.name = name
            p.rssi = rssi
            p.linkState = linkState
            if let k = pk { p.publicKey = k }
            p.lastSeen = now
            self.discoveredPeerById[id] = p
            self.discoveredPeers = self.discoveredPeerById.values.sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
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
            if characteristic.isNotifying {
                sendRequestMapLabels(to: peripheral, characteristic: characteristic)
            }
        }
    }

    /// As central: ask this peripheral to push its map labels to us (so new joiners get existing labels).
    private func sendRequestMapLabels(to peripheral: CBPeripheral, characteristic: CBCharacteristic) {
        let env = MeshEnvelope(
            id: UUID(),
            type: .requestMapLabels,
            senderID: identity.deviceID,
            senderName: identity.nickname,
            timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
            ttl: 0,
            payload: Data(),
            senderLatitude: nil,
            senderLongitude: nil
        )
        guard let data = MeshEnvelope.encodeJSON(env), data.count <= 512 else { return }
        peripheral.writeValue(data, for: characteristic, type: .withResponse)
        log("Requested map labels from \(peripheral.identifier)")
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
        pushMapLabelsToCentral(central)
    }

    /// Push our known map labels to a newly subscribed central so they see existing labels.
    private func pushMapLabelsToCentral(_ central: CBCentral) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let labels = Array(self.mapLabels.values).suffix(50)
            for (index, payload) in labels.enumerated() {
                guard let payloadData = try? JSONEncoder().encode(payload) else { continue }
                var env = MeshEnvelope(
                    id: UUID(),
                    type: .mapLabel,
                    senderID: payload.senderID,
                    senderName: payload.senderName,
                    timestamp: payload.timestamp,
                    ttl: 1,
                    payload: payloadData,
                    senderLatitude: nil,
                    senderLongitude: nil
                )
                let delay = Double(index) * 0.12
                self.bleQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
                    self?.broadcastEnvelopeToCentrals(env, centrals: [central])
                }
            }
        }
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

// MARK: - CLLocationManagerDelegate

extension BluetoothMeshService: CLLocationManagerDelegate {
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        DispatchQueue.main.async { [weak self] in
            self?.lastKnownLocation = (loc.coordinate.latitude, loc.coordinate.longitude)
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            if identity.shareLocation {
                locationManager.startUpdatingLocation()
            }
        default:
            break
        }
    }
}

// MARK: - UNUserNotificationCenterDelegate

extension BluetoothMeshService: UNUserNotificationCenterDelegate {
    /// Show label notifications even when the app is in the foreground.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound, .badge])
    }
}
