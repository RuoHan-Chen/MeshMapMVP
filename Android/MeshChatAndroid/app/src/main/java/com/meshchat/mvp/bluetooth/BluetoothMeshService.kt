package com.meshchat.mvp.bluetooth

import android.Manifest
import android.annotation.SuppressLint
import android.bluetooth.*
import android.bluetooth.le.*
import android.content.*
import android.content.pm.PackageManager
import android.os.Build
import android.os.ParcelUuid
import android.util.Base64
import android.util.Log
import androidx.core.content.ContextCompat
import com.meshchat.mvp.MainActivity
import com.meshchat.mvp.crypto.KeyManager
import com.meshchat.mvp.database.*
import com.meshchat.mvp.model.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import java.util.*
import kotlin.math.*

private const val TAG = "BlesMesh"
private val MESH_SERVICE_UUID: UUID = UUID.fromString("6E400001-B5A3-F393-E0A9-E50E24DCCA9E")
private val MESH_CHAR_UUID: UUID = UUID.fromString("6E400002-B5A3-F393-E0A9-E50E24DCCA9E")
private val CCCD_UUID: UUID = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")

@SuppressLint("MissingPermission")
class BluetoothMeshService(private val context: Context) {

    private val scope = CoroutineScope(Dispatchers.IO + SupervisorJob())
    private val mainScope = CoroutineScope(Dispatchers.Main + SupervisorJob())

    // ── Published state ───────────────────────────────────────────────────────

    private val _chatMessages = MutableStateFlow<List<ChatMessage>>(emptyList())
    val chatMessages: StateFlow<List<ChatMessage>> = _chatMessages.asStateFlow()

    private val _directThreadMessages = MutableStateFlow<Map<String, List<ChatMessage>>>(emptyMap())
    val directThreadMessages: StateFlow<Map<String, List<ChatMessage>>> = _directThreadMessages.asStateFlow()

    private val _discoveredPeers = MutableStateFlow<List<DiscoveredPeer>>(emptyList())
    val discoveredPeers: StateFlow<List<DiscoveredPeer>> = _discoveredPeers.asStateFlow()

    private val _connectedPeerCount = MutableStateFlow(0)
    val connectedPeerCount: StateFlow<Int> = _connectedPeerCount.asStateFlow()

    private val _subscribedCentralCount = MutableStateFlow(0)
    val subscribedCentralCount: StateFlow<Int> = _subscribedCentralCount.asStateFlow()

    private val _isScanning = MutableStateFlow(false)
    val isScanning: StateFlow<Boolean> = _isScanning.asStateFlow()

    /** True once the GATT server is open and the mesh characteristic is registered (peripheral role). */
    private val _gattServerActive = MutableStateFlow(false)
    val gattServerActive: StateFlow<Boolean> = _gattServerActive.asStateFlow()

    /** True while the BLE advertiser is broadcasting (peripheral role). */
    private val _advertisingActive = MutableStateFlow(false)
    val advertisingActive: StateFlow<Boolean> = _advertisingActive.asStateFlow()

    private val _secondsUntilNextScan = MutableStateFlow(0.0)
    val secondsUntilNextScan: StateFlow<Double> = _secondsUntilNextScan.asStateFlow()

    private val _debugLines = MutableStateFlow<List<String>>(emptyList())
    val debugLines: StateFlow<List<String>> = _debugLines.asStateFlow()

    private val _mapLabels = MutableStateFlow<Map<UUID, MapLabelPayload>>(emptyMap())
    val mapLabels: StateFlow<Map<UUID, MapLabelPayload>> = _mapLabels.asStateFlow()

    private val _labelVotes = MutableStateFlow<Map<UUID, Map<String, Int>>>(emptyMap())
    val labelVotes: StateFlow<Map<UUID, Map<String, Int>>> = _labelVotes.asStateFlow()

    private val _thumbnails = MutableStateFlow<Map<UUID, ByteArray>>(emptyMap())
    val thumbnails: StateFlow<Map<UUID, ByteArray>> = _thumbnails.asStateFlow()

    private val _mapLabelCooldownRemaining = MutableStateFlow(0.0)
    val mapLabelCooldownRemaining: StateFlow<Double> = _mapLabelCooldownRemaining.asStateFlow()

    private val _lastKnownLocation = MutableStateFlow<Pair<Double, Double>?>(null)
    val lastKnownLocation: StateFlow<Pair<Double, Double>?> = _lastKnownLocation.asStateFlow()

    private val _senderCoordinates = MutableStateFlow<Map<String, Pair<Double, Double>>>(emptyMap())
    val senderCoordinates: StateFlow<Map<String, Pair<Double, Double>>> = _senderCoordinates.asStateFlow()

    private val _announceNicknames = MutableStateFlow<Map<String, String>>(emptyMap())
    val announceNicknames: StateFlow<Map<String, String>> = _announceNicknames.asStateFlow()

    private val _contactActivity = MutableStateFlow<Map<String, ContactActivityState>>(emptyMap())
    val contactActivity: StateFlow<Map<String, ContactActivityState>> = _contactActivity.asStateFlow()

    private val _contactActivityRevision = MutableStateFlow(0)
    val contactActivityRevision: StateFlow<Int> = _contactActivityRevision.asStateFlow()

    private val _contactsVersion = MutableStateFlow(UUID.randomUUID())
    val contactsVersion: StateFlow<UUID> = _contactsVersion.asStateFlow()

    private val _bluetoothOn = MutableStateFlow(btAdapter?.isEnabled == true)
    val bluetoothOn: StateFlow<Boolean> = _bluetoothOn.asStateFlow()

    /** BroadcastReceiver that tracks Bluetooth adapter state changes. */
    private val btStateReceiver = object : android.content.BroadcastReceiver() {
        override fun onReceive(ctx: android.content.Context, intent: android.content.Intent) {
            if (intent.action != android.bluetooth.BluetoothAdapter.ACTION_STATE_CHANGED) return
            val state = intent.getIntExtra(
                android.bluetooth.BluetoothAdapter.EXTRA_STATE,
                android.bluetooth.BluetoothAdapter.ERROR
            )
            val isOn = state == android.bluetooth.BluetoothAdapter.STATE_ON
            mainScope.launch { _bluetoothOn.value = isOn }
            log("Bluetooth state changed → ${if (isOn) "ON" else "OFF"} ($state)")
            if (isOn) {
                // BT just turned on — start all roles
                mainScope.launch {
                    setupGattServer()
                    startAdvertising()
                    if (scanJob == null || scanJob?.isActive == false) scheduleScanCycle()
                }
            } else {
                // BT turned off — cancel scan loop, close connections
                scanJob?.cancel(); scanJob = null
                mainScope.launch {
                    _isScanning.value = false
                    _gattServerActive.value = false
                    _advertisingActive.value = false
                }
            }
        }
    }

    // ── Scan settings ─────────────────────────────────────────────────────────
    var autoConnectEnabled = MutableStateFlow(true)
    var autoReconnectEnabled = MutableStateFlow(true)
    var scanWindowSeconds = MutableStateFlow(12.0)
    var scanIdleSeconds = MutableStateFlow(40.0)

    // ── Identity ──────────────────────────────────────────────────────────────
    // Exposed as StateFlow so Composables collect it reactively (no direct Keystore hits in UI)
    private fun loadIdentityFromPrefs(): DeviceIdentity {
        val prefs = context.getSharedPreferences("meshchat.identity", Context.MODE_PRIVATE)
        val nickname = prefs.getString("nickname", null)
            ?: "Peer-${KeyManager.fingerprint(KeyManager.publicKeyData, 6)}"
        val share = prefs.getBoolean("shareLocation", true)
        return DeviceIdentity(
            deviceID = KeyManager.publicKeyBase64DeviceID,
            nickname = nickname,
            shareLocation = share
        )
    }

    private val _identityFlow = MutableStateFlow(
        DeviceIdentity(deviceID = "", nickname = "…", shareLocation = false)
    )
    val identityFlow: StateFlow<DeviceIdentity> = _identityFlow.asStateFlow()

    // Synchronous accessor for internal service use (safe after KeyManager.init in init{})
    val identity: DeviceIdentity get() = _identityFlow.value.let {
        if (it.deviceID.isEmpty()) loadIdentityFromPrefs().also { id -> _identityFlow.value = id }
        else it
    }

    fun updateIdentity(id: DeviceIdentity) {
        _identityFlow.value = id
        context.getSharedPreferences("meshchat.identity", Context.MODE_PRIVATE).edit()
            .putString("nickname", id.nickname)
            .putBoolean("shareLocation", id.shareLocation)
            .apply()
        if (id.shareLocation) startLocationUpdates() else stopLocationUpdates()
        mainScope.launch { restartAdvertising() }
        log("Identity saved")
    }

    // ── BLE infrastructure ───────────────────────────────────────────────────

    private val btManager: BluetoothManager? =
        context.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager
    private val btAdapter: BluetoothAdapter? get() = btManager?.adapter
    private val bleScanner: BluetoothLeScanner? get() = btAdapter?.bluetoothLeScanner
    private val bleAdvertiser: BluetoothLeAdvertiser? get() = btAdapter?.bluetoothLeAdvertiser

    private var gattServer: BluetoothGattServer? = null

    private fun getOrOpenGattServer(): BluetoothGattServer? {
        if (gattServer != null) return gattServer
        return try {
            btManager?.openGattServer(context, gattServerCallback)?.also { gattServer = it }
        } catch (e: Exception) {
            log("openGattServer failed: ${e.message}")
            null
        }
    }
    private var meshCharacteristic: BluetoothGattCharacteristic? = null
    private val subscribedDevices = mutableSetOf<BluetoothDevice>()
    private val connectedGattClients = mutableMapOf<String, BluetoothGatt>() // addr → gatt
    private val discoveredPeerMap = mutableMapOf<String, DiscoveredPeer>()
    private val peerCharacteristics = mutableMapOf<String, BluetoothGattCharacteristic>()
    private val connectingAddrs = mutableSetOf<String>()

    // ── Dedup ─────────────────────────────────────────────────────────────────
    private val dedupIds = mutableSetOf<UUID>()
    private val dedupQueue = ArrayDeque<UUID>()
    private val maxDedupEntries = 500

    // ── Pending image chunks ──────────────────────────────────────────────────
    private data class PendingImageBuffer(
        val total: Int, val parts: MutableMap<Int, ByteArray>,
        val senderID: String, val senderName: String
    )
    private val pendingImages = mutableMapOf<UUID, PendingImageBuffer>()
    private data class ThumbnailChunkBuffer(
        val labelId: UUID, val total: Int,
        var compressed: Boolean = false,
        val chunks: MutableMap<Int, ByteArray>
    )
    private val thumbnailBuffers = mutableMapOf<UUID, ThumbnailChunkBuffer>()

    // ── Timing ───────────────────────────────────────────────────────────────
    private val defaultTTL = 5
    private var scanJob: Job? = null
    private var cooldownJob: Job? = null
    private var pruneJob: Job? = null
    private var lastMapLabelSendTime: Long? = null
    private val mapLabelCooldownSeconds = 30.0
    private val dmTTLSeconds = 20 * 60L
    private val ignoredLabelIds = mutableSetOf<UUID>()

    // ── Encryption keys ───────────────────────────────────────────────────────
    private val encryptionPublicKeyByDeviceID = mutableMapOf<String, ByteArray>()

    companion object {
        const val MESH_ENVELOPE_MAX_BYTES = 512
        const val IMAGE_CHUNK_BYTE_SIZE = 40
        const val MAX_EVENT_PLACEMENT_DISTANCE_METERS = 5_000.0

        fun dmChannelId(myID: String, peerID: String): String =
            "dm:" + listOf(myID, peerID).sorted().joinToString("|")

        fun haversineMeters(lat1: Double, lon1: Double, lat2: Double, lon2: Double): Double {
            val R = 6_371_000.0
            val toRad = { d: Double -> d * PI / 180 }
            val dLat = toRad(lat2 - lat1)
            val dLon = toRad(lon2 - lon1)
            val a = sin(dLat / 2).pow(2) +
                    cos(toRad(lat1)) * cos(toRad(lat2)) * sin(dLon / 2).pow(2)
            return R * 2 * atan2(sqrt(a), sqrt(1 - a))
        }
    }

    // ── Init ──────────────────────────────────────────────────────────────────

    init {
        try {
            // KeyManager uses SharedPreferences only — safe on all API levels, fast.
            KeyManager.init(context)
            loadContactActivity()
            startPruneTimer()
        } catch (e: Exception) {
            Log.e(TAG, "BluetoothMeshService init failed", e)
        }
    }

    fun start() {
        // Register for Bluetooth state changes so UI updates and BLE roles restart when BT turns on
        val btFilter = android.content.IntentFilter(android.bluetooth.BluetoothAdapter.ACTION_STATE_CHANGED)
        context.registerReceiver(btStateReceiver, btFilter)

        // Sync current BT state immediately (in case it changed between init and start)
        val currentlyOn = btAdapter?.isEnabled == true
        mainScope.launch { _bluetoothOn.value = currentlyOn }
        log("BT state at start: ${if (currentlyOn) "ON" else "OFF"}")

        // DB init on IO — doesn't need BLE permissions
        scope.launch {
            DatabaseManager.init(context)
            loadPersistedMessages()
            // Seed the nickname cache so contact names resolve on startup before any announce arrives
            val contacts = DatabaseManager.listContacts()
            val cacheEntries = contacts.associate {
                DatabaseManager.canonicalSenderID(it.publicKey) to it.nickname
            }
            mainScope.launch { savedContactNicknameCache.putAll(cacheEntries) }
        }
        // BLE + location setup on main thread (requires Looper; permissions checked inside each fn)
        mainScope.launch {
            if (identity.shareLocation) startLocationUpdates()
            setupGattServer()
            startAdvertising()
            scheduleScanCycle()
        }
    }

    /**
     * Called by MainActivity after the user grants (or re-grants) BLE+location permissions.
     * Restarts any BLE roles that silently no-oped during [start] due to missing permissions.
     */
    fun onPermissionsGranted() {
        mainScope.launch {
            // Sync current BT state in case it changed while permissions were being requested
            val isOn = btAdapter?.isEnabled == true
            _bluetoothOn.value = isOn
            log("onPermissionsGranted — BT is ${if (isOn) "ON" else "OFF"}")

            if (!isOn) {
                log("BT not yet on — BroadcastReceiver will trigger setup when it turns on")
                return@launch
            }

            // (Re)start any BLE roles that silently no-oped at startup
            if (meshCharacteristic == null) setupGattServer()
            startAdvertising()
            if (scanJob == null || scanJob?.isActive == false) scheduleScanCycle()
            if (identity.shareLocation) startLocationUpdates()
        }
    }

    fun stop() {
        try { context.unregisterReceiver(btStateReceiver) } catch (_: Exception) {}
        scanJob?.cancel()
        try {
            bleScanner?.stopScan(scanCallback)
            bleAdvertiser?.stopAdvertising(advertiseCallback)
            connectedGattClients.values.forEach { it.close() }
        } catch (_: Exception) {}
    }

    // ── Location (via Android FusedLocation) ─────────────────────────────────

    private var fusedLocationClient: com.google.android.gms.location.FusedLocationProviderClient? = null

    private fun startLocationUpdates() {
        if (!hasLocationPermission()) return
        try {
            fusedLocationClient = com.google.android.gms.location.LocationServices
                .getFusedLocationProviderClient(context)
            val req = com.google.android.gms.location.LocationRequest.Builder(30_000L)
                .setPriority(com.google.android.gms.location.Priority.PRIORITY_BALANCED_POWER_ACCURACY)
                .setMinUpdateDistanceMeters(50f)
                .build()
            fusedLocationClient?.requestLocationUpdates(req, locationCallback, android.os.Looper.getMainLooper())
        } catch (_: Exception) { }
    }

    private fun stopLocationUpdates() {
        fusedLocationClient?.removeLocationUpdates(locationCallback)
        mainScope.launch { _lastKnownLocation.value = null }
    }

    private val locationCallback = object : com.google.android.gms.location.LocationCallback() {
        override fun onLocationResult(r: com.google.android.gms.location.LocationResult) {
            val loc = r.lastLocation ?: return
            mainScope.launch { _lastKnownLocation.value = loc.latitude to loc.longitude }
        }
    }

    private fun hasLocationPermission() = ContextCompat.checkSelfPermission(
        context, Manifest.permission.ACCESS_FINE_LOCATION
    ) == PackageManager.PERMISSION_GRANTED

    private fun hasBluetoothPermission(): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            ContextCompat.checkSelfPermission(context, Manifest.permission.BLUETOOTH_SCAN) == PackageManager.PERMISSION_GRANTED &&
            ContextCompat.checkSelfPermission(context, Manifest.permission.BLUETOOTH_ADVERTISE) == PackageManager.PERMISSION_GRANTED &&
            ContextCompat.checkSelfPermission(context, Manifest.permission.BLUETOOTH_CONNECT) == PackageManager.PERMISSION_GRANTED
        } else {
            ContextCompat.checkSelfPermission(context, Manifest.permission.BLUETOOTH) == PackageManager.PERMISSION_GRANTED
        }
    }

    // ── GATT server (peripheral role) ────────────────────────────────────────

    private fun setupGattServer() {
        if (!hasBluetoothPermission()) { log("setupGattServer: no BT permission"); return }
        try {
            val char = BluetoothGattCharacteristic(
                MESH_CHAR_UUID,
                BluetoothGattCharacteristic.PROPERTY_WRITE or BluetoothGattCharacteristic.PROPERTY_NOTIFY,
                BluetoothGattCharacteristic.PERMISSION_WRITE
            )
            char.addDescriptor(BluetoothGattDescriptor(
                CCCD_UUID,
                BluetoothGattDescriptor.PERMISSION_READ or BluetoothGattDescriptor.PERMISSION_WRITE
            ))
            meshCharacteristic = char

            val service = BluetoothGattService(MESH_SERVICE_UUID, BluetoothGattService.SERVICE_TYPE_PRIMARY)
            service.addCharacteristic(char)

            val srv = getOrOpenGattServer() ?: return
            srv.clearServices()
            srv.addService(service)
            mainScope.launch { _gattServerActive.value = true }
            log("GATT server set up")
        } catch (e: Exception) {
            log("setupGattServer failed: ${e.message}")
        }
    }

    private fun startAdvertising() {
        if (!hasBluetoothPermission()) return
        val settings = AdvertiseSettings.Builder()
            .setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_LOW_LATENCY)
            .setConnectable(true)
            .setTimeout(0)
            .build()
        // Include the service UUID in the primary advertisement packet
        val data = AdvertiseData.Builder()
            .addServiceUuid(ParcelUuid(MESH_SERVICE_UUID))
            .setIncludeDeviceName(false) // keep packet small; name in scan response below
            .build()
        // Scan response carries the local device name (set via BluetoothAdapter)
        val scanResponse = AdvertiseData.Builder()
            .setIncludeDeviceName(true)  // standard API, available on all supported versions
            .build()
        bleAdvertiser?.startAdvertising(settings, data, scanResponse, advertiseCallback)
        log("Advertising started")
    }

    private fun restartAdvertising() {
        if (!hasBluetoothPermission()) return
        bleAdvertiser?.stopAdvertising(advertiseCallback)
        startAdvertising()
    }

    private val advertiseCallback = object : AdvertiseCallback() {
        override fun onStartSuccess(settingsInEffect: AdvertiseSettings?) {
            mainScope.launch { _advertisingActive.value = true }
            log("Advertise OK")
        }
        override fun onStartFailure(errorCode: Int) {
            mainScope.launch { _advertisingActive.value = false }
            log("Advertise fail $errorCode")
        }
    }

    private val gattServerCallback = object : BluetoothGattServerCallback() {
        override fun onConnectionStateChange(device: BluetoothDevice, status: Int, newState: Int) {
            if (newState == BluetoothProfile.STATE_DISCONNECTED) {
                subscribedDevices.remove(device)
                mainScope.launch { _subscribedCentralCount.value = subscribedDevices.size }
            }
        }

        override fun onDescriptorWriteRequest(
            device: BluetoothDevice, requestId: Int, descriptor: BluetoothGattDescriptor,
            preparedWrite: Boolean, responseNeeded: Boolean, offset: Int, value: ByteArray?
        ) {
            if (descriptor.uuid == CCCD_UUID) {
                val enabled = value?.contentEquals(BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE) == true
                if (enabled) {
                    subscribedDevices.add(device)
                    mainScope.launch { _subscribedCentralCount.value = subscribedDevices.size }
                    log("Central subscribed (${subscribedDevices.size})")
                    sendAnnounce(to = listOf(device))
                    pushMapLabelsToCentral(device)
                } else {
                    subscribedDevices.remove(device)
                    mainScope.launch { _subscribedCentralCount.value = subscribedDevices.size }
                }
            }
            if (responseNeeded) getOrOpenGattServer()?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, 0, null)
        }

        override fun onCharacteristicWriteRequest(
            device: BluetoothDevice, requestId: Int, characteristic: BluetoothGattCharacteristic,
            preparedWrite: Boolean, responseNeeded: Boolean, offset: Int, value: ByteArray?
        ) {
            if (characteristic.uuid == MESH_CHAR_UUID && value != null) {
                handleIncomingData(value, sourceCentralAddr = device.address, sourcePeripheralAddr = null)
            }
            if (responseNeeded) getOrOpenGattServer()?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, 0, null)
        }
    }

    // ── BLE Scanner (central role) ───────────────────────────────────────────

    private fun scheduleScanCycle() {
        scanJob?.cancel()
        scanJob = mainScope.launch {   // Main thread — BLE scan APIs require a Looper
            while (isActive) {
                beginScanWindow()
                delay((scanWindowSeconds.value * 1000).toLong())
                stopScan()
                log("Scan OFF — next in ${scanIdleSeconds.value}s")
                startCountdown(scanIdleSeconds.value)
                delay((scanIdleSeconds.value * 1000).toLong())
            }
        }
    }

    private fun beginScanWindow() {
        if (!hasBluetoothPermission()) return
        val filter = ScanFilter.Builder()
            .setServiceUuid(ParcelUuid(MESH_SERVICE_UUID))
            .build()
        val settings = ScanSettings.Builder()
            .setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY)
            .build()
        bleScanner?.startScan(listOf(filter), settings, scanCallback)
        mainScope.launch { _isScanning.value = true; _secondsUntilNextScan.value = 0.0 }
        log("Scan ON (${scanWindowSeconds.value}s)")
    }

    private fun stopScan() {
        if (!hasBluetoothPermission()) return
        bleScanner?.stopScan(scanCallback)
        mainScope.launch { _isScanning.value = false }
    }

    private fun startCountdown(seconds: Double) {
        scope.launch {
            var remaining = seconds
            while (remaining > 0) {
                delay(1000)
                remaining -= 1
                mainScope.launch { _secondsUntilNextScan.value = remaining }
            }
        }
    }

    fun scanNow() { mainScope.launch { stopScan(); beginScanWindow() } }

    private val scanCallback = object : ScanCallback() {
        override fun onScanResult(callbackType: Int, result: ScanResult) {
            val device = result.device
            val addr = device.address
            val name = result.scanRecord?.deviceName ?: addr

            val existing = discoveredPeerMap[addr]
            val linkState = when {
                connectedGattClients.containsKey(addr) -> "connected"
                connectingAddrs.contains(addr) -> "connecting"
                else -> "discovered"
            }

            val peer = existing?.copy(name = name, rssi = result.rssi, linkState = linkState, lastSeen = System.currentTimeMillis())
                ?: DiscoveredPeer(id = addr, name = name, rssi = result.rssi, nickname = null, linkState = linkState, publicKey = null, lastSeen = System.currentTimeMillis())
            discoveredPeerMap[addr] = peer
            mainScope.launch { _discoveredPeers.value = discoveredPeerMap.values.sortedBy { it.name } }

            if (autoConnectEnabled.value && !connectedGattClients.containsKey(addr) && !connectingAddrs.contains(addr)) {
                connectPeripheral(device)
            }
        }
    }

    private fun connectPeripheral(device: BluetoothDevice) {
        if (!hasBluetoothPermission()) return
        connectingAddrs.add(device.address)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            device.connectGatt(context, false, gattCallback, BluetoothDevice.TRANSPORT_LE)
        } else {
            @Suppress("DEPRECATION")
            device.connectGatt(context, false, gattCallback)
        }
        log("Connecting → ${device.address}")
    }

    fun connect(peerAddress: String) {
        val device = btAdapter?.getRemoteDevice(peerAddress) ?: return
        connectPeripheral(device)
    }

    private val gattCallback = object : BluetoothGattCallback() {
        override fun onConnectionStateChange(gatt: BluetoothGatt, status: Int, newState: Int) {
            val addr = gatt.device.address
            when (newState) {
                BluetoothProfile.STATE_CONNECTED -> {
                    connectingAddrs.remove(addr)
                    connectedGattClients[addr] = gatt
                    gatt.discoverServices()
                    updatePeerLinkState(addr, "connected")
                    mainScope.launch { _connectedPeerCount.value = connectedGattClients.size }
                    log("Connected $addr")
                }
                BluetoothProfile.STATE_DISCONNECTED -> {
                    connectingAddrs.remove(addr)
                    connectedGattClients.remove(addr)
                    peerCharacteristics.remove(addr)
                    updatePeerLinkState(addr, "disconnected")
                    mainScope.launch { _connectedPeerCount.value = connectedGattClients.size }
                    gatt.close()
                    log("Disconnected $addr")
                    if (autoReconnectEnabled.value) {
                        scope.launch {
                            delay(5000)
                            if (!connectedGattClients.containsKey(addr) && hasBluetoothPermission()) {
                                connectPeripheral(btAdapter?.getRemoteDevice(addr) ?: return@launch)
                            }
                        }
                    }
                }
            }
        }

        override fun onServicesDiscovered(gatt: BluetoothGatt, status: Int) {
            val char = gatt.getService(MESH_SERVICE_UUID)
                ?.getCharacteristic(MESH_CHAR_UUID) ?: return
            peerCharacteristics[gatt.device.address] = char
            gatt.setCharacteristicNotification(char, true)
            char.getDescriptor(CCCD_UUID)?.let { desc ->
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    gatt.writeDescriptor(desc, BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE)
                } else {
                    @Suppress("DEPRECATION")
                    desc.value = BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
                    @Suppress("DEPRECATION")
                    gatt.writeDescriptor(desc)
                }
            }
            log("Services discovered ${gatt.device.address}")
            sendRequestMapLabels(gatt.device.address)
        }

        override fun onDescriptorWrite(gatt: BluetoothGatt, descriptor: BluetoothGattDescriptor, status: Int) {
            log("Notify enabled ${gatt.device.address}")
        }

        override fun onCharacteristicChanged(
            gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic, value: ByteArray
        ) {
            handleIncomingData(value, sourceCentralAddr = null, sourcePeripheralAddr = gatt.device.address)
        }

        @Suppress("DEPRECATION")
        override fun onCharacteristicChanged(gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic) {
            handleIncomingData(characteristic.value ?: return, null, gatt.device.address)
        }
    }

    // ── Announce ──────────────────────────────────────────────────────────────

    private fun buildAnnounceEnvelope(): MeshEnvelope {
        val id = identity
        // iOS expects URL-safe base64 (no padding) for publicKeyBase64 — match that format
        // so iOS decodePublicKeyBase64() can decode it correctly cross-platform
        val pubKeyUrlSafe = Base64.encodeToString(KeyManager.publicKeyData, Base64.NO_WRAP or Base64.NO_PADDING)
            .replace("+", "-").replace("/", "_")
        val payload = AnnouncementPayload(
            nickname = id.nickname,
            publicKeyBase64 = pubKeyUrlSafe,
            encryptionPublicKeyBase64 = KeyManager.encPublicKeyBase64
        ).toJSON()
        return MeshEnvelope(
            id = UUID.randomUUID(), type = MessageType.ANNOUNCE,
            senderID = id.deviceID, senderName = id.nickname,
            timestamp = System.currentTimeMillis(), ttl = 2,
            payload = payload,
            senderLatitude = if (id.shareLocation) _lastKnownLocation.value?.first else null,
            senderLongitude = if (id.shareLocation) _lastKnownLocation.value?.second else null
        )
    }

    private fun sendAnnounce(to: List<BluetoothDevice>? = null) {
        val env = buildAnnounceEnvelope()
        val data = MeshEnvelope.encodeJSON(env) ?: return
        if (data.size > MESH_ENVELOPE_MAX_BYTES) return
        val char = meshCharacteristic ?: return
        val targets = to ?: subscribedDevices.toList()
        for (device in targets) {
            char.value = data
            getOrOpenGattServer()?.notifyCharacteristicChanged(device, char, false)
        }
    }

    // ── Send chat ─────────────────────────────────────────────────────────────

    fun sendChat(text: String) {
        val trimmed = text.trim().takeIf { it.isNotEmpty() } ?: return
        val id = identity
        val payload = ChatPayload(text = trimmed).toJSON()
        val env = buildEnvelope(MessageType.MESSAGE, id, payload)
        val pm = PersistedMessageEntity(
            id = env.id.toString(), senderID = env.senderID, senderName = env.senderName,
            text = trimmed, timestamp = env.timestamp,
            channel = "broadcast", receivedAt = System.currentTimeMillis() / 1000
        )
        scope.launch {
            DatabaseManager.upsertContact(id.deviceID, id.nickname)
            DatabaseManager.saveMessage(pm)
        }
        markSeen(env.id)
        broadcastEnvelope(env)
        appendLocalChat(env, trimmed, null)
    }

    fun sendDirectChat(text: String, toPeerID: String, peerDisplayName: String) {
        val trimmed = text.trim().takeIf { it.isNotEmpty() } ?: return
        val id = identity
        val ts = System.currentTimeMillis()
        val payload = ChatPayload(text = trimmed, recipientID = toPeerID).toJSON()
        val env = buildEnvelope(MessageType.MESSAGE, id, payload, ts)
        val ch = dmChannelId(id.deviceID, toPeerID)
        val pm = PersistedMessageEntity(
            id = env.id.toString(), senderID = env.senderID, senderName = env.senderName,
            text = trimmed, timestamp = env.timestamp,
            channel = ch, receivedAt = System.currentTimeMillis() / 1000
        )
        scope.launch {
            DatabaseManager.saveMessage(pm)
            DatabaseManager.pruneDMMessages(dmTTLSeconds)
        }
        markSeen(env.id)
        broadcastEnvelope(env)
        val msg = ChatMessage(
            envelopeId = env.id, senderID = id.deviceID, senderName = id.nickname,
            text = trimmed, date = ts, isLocal = true
        )
        mainScope.launch {
            val map = _directThreadMessages.value.toMutableMap()
            val arr = map.getOrDefault(toPeerID, emptyList()).toMutableList()
            arr.add(msg)
            map[toPeerID] = arr
            _directThreadMessages.value = map
        }
        recordContactOutbound(toPeerID, trimmed)
    }

    fun loadDirectThread(peerID: String) {
        scope.launch {
            DatabaseManager.pruneDMMessages(dmTTLSeconds)
            val ch = dmChannelId(identity.deviceID, peerID)
            val persisted = DatabaseManager.messages(ch, 200)
            val myID = identity.deviceID
            val cutoff = System.currentTimeMillis() - dmTTLSeconds * 1000
            val loaded = persisted.mapNotNull { pm ->
                val date = pm.receivedAt * 1000
                if (date < cutoff) null
                else ChatMessage(
                    envelopeId = UUID.fromString(pm.id),
                    senderID = pm.senderID, senderName = pm.senderName,
                    text = pm.text, date = date, isLocal = pm.senderID == myID,
                    imageJPEGBase64 = pm.imageBase64
                )
            }
            mainScope.launch {
                val map = _directThreadMessages.value.toMutableMap()
                map[peerID] = loaded
                _directThreadMessages.value = map
            }
        }
    }

    fun sendImage(jpegData: ByteArray, completion: ((Int) -> Unit)? = null) {
        if (jpegData.isEmpty() || jpegData.size > 12 * 1024) {
            completion?.invoke(0); return
        }
        val transferId = UUID.randomUUID()
        val total = (jpegData.size + IMAGE_CHUNK_BYTE_SIZE - 1) / IMAGE_CHUNK_BYTE_SIZE
        val envelopes = (0 until total).mapNotNull { i ->
            val start = i * IMAGE_CHUNK_BYTE_SIZE
            val slice = jpegData.copyOfRange(start, minOf(start + IMAGE_CHUNK_BYTE_SIZE, jpegData.size))
            val chunk = ImageChunkPayload(transferId, i, total, slice)
            val id = identity
            buildEnvelope(MessageType.IMAGE_CHUNK, id, chunk.toJSON())
        }
        val id = identity
        val firstEnv = envelopes.firstOrNull() ?: run { completion?.invoke(0); return }
        val imageB64 = Base64.encodeToString(jpegData, Base64.NO_WRAP)
        val pm = PersistedMessageEntity(
            id = firstEnv.id.toString(), senderID = id.deviceID, senderName = id.nickname,
            text = "[photo]", timestamp = firstEnv.timestamp,
            channel = "broadcast", receivedAt = System.currentTimeMillis() / 1000,
            imageBase64 = imageB64
        )
        scope.launch {
            DatabaseManager.upsertContact(id.deviceID, id.nickname)
            DatabaseManager.saveMessage(pm)
            envelopes.forEachIndexed { idx, env ->
                if (idx > 0) delay(20)
                markSeen(env.id)
                broadcastEnvelope(env)
            }
            mainScope.launch { completion?.invoke(envelopes.size) }
        }
        appendLocalChat(firstEnv, "[photo]", imageB64)
    }

    // ── Map labels ────────────────────────────────────────────────────────────

    fun sendMapLabel(
        category: LabelCategory,
        lat: Double,
        lon: Double,
        customLabelName: String? = null,
        customDescription: String? = null,
        customSystemImage: String? = null,
        explicitId: UUID? = null
    ): Boolean {
        if (_mapLabelCooldownRemaining.value > 0) return false
        val my = _lastKnownLocation.value
        if (my != null) {
            val dist = haversineMeters(my.first, my.second, lat, lon)
            if (dist > MAX_EVENT_PLACEMENT_DISTANCE_METERS) return false
        }
        startCooldown()
        val labelId = explicitId ?: UUID.randomUUID()
        val id = identity
        val ts = System.currentTimeMillis()
        val payload = MapLabelPayload(
            id = labelId, category = category.rawValue, lat = lat, lon = lon,
            senderID = id.deviceID, senderName = id.nickname, timestamp = ts,
            customLabelName = customLabelName, customDescription = customDescription,
            customSystemImage = customSystemImage
        )
        val env = buildEnvelope(MessageType.MAP_LABEL, id, payload.toJSON(), ts)
        mainScope.launch {
            val map = _mapLabels.value.toMutableMap()
            map[payload.id] = payload
            _mapLabels.value = map
        }
        scope.launch { broadcastEnvelope(env) }
        return true
    }

    fun sendMapLabelWithThumbnail(
        category: LabelCategory, lat: Double, lon: Double,
        customLabelName: String?, customDescription: String?, customSystemImage: String?,
        jpegData: ByteArray
    ): Boolean {
        val labelId = UUID.randomUUID()
        val ok = sendMapLabel(category, lat, lon, customLabelName, customDescription, customSystemImage, labelId)
        if (ok) sendLabelThumbnail(labelId, jpegData)
        return ok
    }

    fun sendLabelThumbnail(labelId: UUID, jpegData: ByteArray) {
        val maxBytes = 8_000
        val trimmed = if (jpegData.size > maxBytes) jpegData.copyOf(maxBytes) else jpegData
        mainScope.launch { storeThumbnail(labelId, trimmed) }

        // Try LZ4 compression — produces Apple-compatible framing (4-byte LE size header)
        val compressed   = tryLz4Compress(trimmed)
        val dataToChunk  = compressed ?: trimmed
        val useCompressed = compressed != null

        val maxChunk    = 80
        val totalChunks = (dataToChunk.size + maxChunk - 1) / maxChunk
        val id = identity
        log("Thumbnail send labelId=$labelId raw=${trimmed.size}B" +
            if (useCompressed) " → lz4=${dataToChunk.size}B chunks=$totalChunks"
            else " chunks=$totalChunks (no compression gain)")

        scope.launch {
            (0 until totalChunks).forEach { index ->
                val start = index * maxChunk
                val slice = dataToChunk.copyOfRange(start, minOf(start + maxChunk, dataToChunk.size))
                val chunk = MapLabelImageChunkPayload(
                    imageId    = labelId,
                    labelId    = labelId,
                    index      = index,
                    total      = totalChunks,
                    data       = slice,
                    compressed = if (useCompressed) true else null
                )
                val env = buildEnvelope(MessageType.MAP_LABEL_IMAGE_CHUNK, id, chunk.toJSON())
                if (index > 0) delay(30)
                broadcastEnvelope(env)
            }
        }
    }

    fun voteForLabel(labelId: UUID, up: Boolean) {
        val vote = if (up) 1 else -1
        val id = identity
        val payload = MapLabelVotePayload(labelId, vote, id.deviceID)
        val env = buildEnvelope(MessageType.MAP_LABEL_VOTE, id, payload.toJSON())
        mainScope.launch {
            val votesMap = _labelVotes.value.toMutableMap()
            val inner = votesMap.getOrDefault(labelId, emptyMap()).toMutableMap()
            inner[id.deviceID] = vote
            votesMap[labelId] = inner
            _labelVotes.value = votesMap
        }
        scope.launch { broadcastEnvelope(env) }
    }

    fun removeMapLabel(id: UUID) {
        mainScope.launch {
            val m = _mapLabels.value.toMutableMap(); m.remove(id); _mapLabels.value = m
            val v = _labelVotes.value.toMutableMap(); v.remove(id); _labelVotes.value = v
            ignoredLabelIds.add(id)
        }
    }

    fun clearLocalEvents() {
        mainScope.launch {
            _mapLabels.value = emptyMap()
            _labelVotes.value = emptyMap()
            ignoredLabelIds.clear()
        }
    }

    fun clearChatMessages() { mainScope.launch { _chatMessages.value = emptyList() } }

    fun clearDebugLog() { mainScope.launch { _debugLines.value = emptyList() } }

    // ── Contact activity ──────────────────────────────────────────────────────

    val contactUnreadTotal: Int get() = _contactActivity.value.values.sumOf { it.unread }

    fun activity(forPeerID: String) = _contactActivity.value[forPeerID]

    fun markContactThreadRead(peerID: String) {
        mainScope.launch {
            val map = _contactActivity.value.toMutableMap()
            val m = map[peerID] ?: return@launch
            map[peerID] = m.copy(unread = 0)
            _contactActivity.value = map
            _contactActivityRevision.value++
            persistContactActivity()
        }
    }

    fun removeContactActivity(peerID: String) {
        mainScope.launch {
            val map = _contactActivity.value.toMutableMap()
            map.remove(peerID)
            _contactActivity.value = map
            _contactActivityRevision.value++
        }
    }

    fun bumpContactsVersion() {
        mainScope.launch {
            _contactsVersion.value = UUID.randomUUID()
            // Refresh nickname cache for all known senderIDs so display names update immediately
            _announceNicknames.value.keys.forEach { refreshNicknameCache(it) }
            savedContactNicknameCache.clear()
        }
    }

    private fun recordContactInbound(peerID: String, preview: String) {
        scope.launch {
            val isSaved = DatabaseManager.findContactByPublicKey(
                KeyManager.decodePublicKeyBase64(peerID) ?: return@launch
            ) != null
            if (!isSaved) return@launch
            mainScope.launch {
                val map = _contactActivity.value.toMutableMap()
                val m = map.getOrDefault(peerID, ContactActivityState("", 0, 0))
                map[peerID] = m.copy(
                    lastText = preview.take(120),
                    lastDate = System.currentTimeMillis(),
                    unread = m.unread + 1
                )
                _contactActivity.value = map
                _contactActivityRevision.value++
                persistContactActivity()
            }
        }
    }

    private fun recordContactOutbound(peerID: String, preview: String) {
        scope.launch {
            val isSaved = DatabaseManager.findContactByPublicKey(
                KeyManager.decodePublicKeyBase64(peerID) ?: return@launch
            ) != null
            if (!isSaved) return@launch
            mainScope.launch {
                val map = _contactActivity.value.toMutableMap()
                val m = map.getOrDefault(peerID, ContactActivityState("", 0, 0))
                map[peerID] = m.copy(lastText = preview.take(120), lastDate = System.currentTimeMillis())
                _contactActivity.value = map
                _contactActivityRevision.value++
                persistContactActivity()
            }
        }
    }

    private fun persistContactActivity() {
        val prefs = context.getSharedPreferences("meshchat.contactActivity", Context.MODE_PRIVATE)
        val json = org.json.JSONObject()
        _contactActivity.value.forEach { (k, v) ->
            json.put(k, org.json.JSONObject().apply {
                put("lastText", v.lastText)
                put("lastDate", v.lastDate)
                put("unread", v.unread)
            })
        }
        prefs.edit().putString("v1", json.toString()).apply()
    }

    private fun loadContactActivity() {
        val prefs = context.getSharedPreferences("meshchat.contactActivity", Context.MODE_PRIVATE)
        val stored = prefs.getString("v1", null) ?: return
        runCatching {
            val json = org.json.JSONObject(stored)
            val map = mutableMapOf<String, ContactActivityState>()
            json.keys().forEach { k ->
                val obj = json.getJSONObject(k)
                map[k] = ContactActivityState(
                    obj.optString("lastText", ""),
                    obj.optLong("lastDate", 0),
                    obj.optInt("unread", 0)
                )
            }
            mainScope.launch { _contactActivity.value = map }
        }
    }

    // ── Display names ─────────────────────────────────────────────────────────

    // Cache of senderID → saved contact nickname, populated on announce and contact save
    private val savedContactNicknameCache = mutableMapOf<String, String>()

    private fun refreshNicknameCache(senderID: String) {
        val pk = KeyManager.decodePublicKeyBase64(senderID) ?: return
        scope.launch {
            val saved = DatabaseManager.findContactByPublicKey(pk)
            if (saved != null) {
                mainScope.launch { savedContactNicknameCache[senderID] = saved.nickname }
            }
        }
    }

    fun senderDisplayName(senderID: String, fallbackSenderName: String): String {
        if (senderID == identity.deviceID) return identity.nickname
        // Prefer saved contact nickname (populated by refreshNicknameCache on announce/contact save)
        savedContactNicknameCache[senderID]?.let { return it }
        return _announceNicknames.value[senderID] ?: fallbackSenderName
    }

    // ── Envelope helpers ──────────────────────────────────────────────────────

    private fun buildEnvelope(type: MessageType, id: DeviceIdentity, payload: ByteArray, ts: Long = System.currentTimeMillis()): MeshEnvelope {
        val loc = _lastKnownLocation.value
        return MeshEnvelope(
            id = UUID.randomUUID(), type = type,
            senderID = id.deviceID, senderName = id.nickname,
            timestamp = ts, ttl = defaultTTL, payload = payload,
            senderLatitude = if (id.shareLocation) loc?.first else null,
            senderLongitude = if (id.shareLocation) loc?.second else null
        )
    }

    private fun markSeen(id: UUID): Boolean {
        if (dedupIds.contains(id)) return false
        dedupIds.add(id)
        dedupQueue.addLast(id)
        while (dedupQueue.size > maxDedupEntries) dedupIds.remove(dedupQueue.removeFirst())
        return true
    }

    private fun broadcastEnvelope(env: MeshEnvelope, excludeCentralAddr: String? = null, excludePeripheralAddr: String? = null) {
        val data = MeshEnvelope.encodeJSON(env) ?: run { log("Encode failed"); return }
        if (data.size > MESH_ENVELOPE_MAX_BYTES) { log("Envelope too large (${data.size}B)"); return }

        // Notify subscribed centrals (we are peripheral)
        val char = meshCharacteristic
        if (char != null && subscribedDevices.isNotEmpty()) {
            char.value = data
            for (dev in subscribedDevices) {
                if (dev.address == excludeCentralAddr) continue
                getOrOpenGattServer()?.notifyCharacteristicChanged(dev, char, false)
            }
        }

        // Write to connected peripherals (we are central)
        for ((addr, gatt) in connectedGattClients) {
            if (addr == excludePeripheralAddr) continue
            val c = peerCharacteristics[addr] ?: continue
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                gatt.writeCharacteristic(c, data, BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT)
            } else {
                @Suppress("DEPRECATION")
                c.value = data
                @Suppress("DEPRECATION")
                gatt.writeCharacteristic(c)
            }
        }
        log("Sent/relay ${env.id} ttl=${env.ttl}")
    }

    private fun sendRequestMapLabels(peripheralAddr: String) {
        val gatt = connectedGattClients[peripheralAddr] ?: return
        val char = peerCharacteristics[peripheralAddr] ?: return
        val id = identity
        val env = MeshEnvelope(
            id = UUID.randomUUID(), type = MessageType.REQUEST_MAP_LABELS,
            senderID = id.deviceID, senderName = id.nickname,
            timestamp = System.currentTimeMillis(), ttl = 0,
            payload = ByteArray(0), senderLatitude = null, senderLongitude = null
        )
        val data = MeshEnvelope.encodeJSON(env) ?: return
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            gatt.writeCharacteristic(char, data, BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT)
        } else {
            @Suppress("DEPRECATION")
            char.value = data
            @Suppress("DEPRECATION")
            gatt.writeCharacteristic(char)
        }
    }

    private fun pushMapLabelsToCentral(device: BluetoothDevice) {
        val labels = _mapLabels.value.values
            .filter { !ignoredLabelIds.contains(it.id) }
            .takeLast(50)
        val char = meshCharacteristic ?: return
        scope.launch {
            labels.forEachIndexed { idx, payload ->
                if (idx > 0) delay(120)
                val id = identity
                val env = MeshEnvelope(
                    id = UUID.randomUUID(), type = MessageType.MAP_LABEL,
                    senderID = payload.senderID, senderName = payload.senderName,
                    timestamp = payload.timestamp, ttl = 1,
                    payload = payload.toJSON(), senderLatitude = null, senderLongitude = null
                )
                val data = MeshEnvelope.encodeJSON(env) ?: return@forEachIndexed
                mainScope.launch {
                    char.value = data
                    getOrOpenGattServer()?.notifyCharacteristicChanged(device, char, false)
                }
            }
        }
    }

    // ── Incoming data handler ────────────────────────────────────────────────

    private fun handleIncomingData(data: ByteArray, sourceCentralAddr: String?, sourcePeripheralAddr: String?) {
        val env = MeshEnvelope.decodeJSON(data) ?: run { log("Drop: decode failed"); return }
        if (!markSeen(env.id)) { log("Drop dedup ${env.id}"); return }

        var dmPastTTL = false
        if (env.type == MessageType.MESSAGE) {
            val chat = ChatPayload.fromJSON(env.payload)
            if (chat?.recipientID != null) {
                val ageMs = System.currentTimeMillis() - env.timestamp
                dmPastTTL = ageMs > dmTTLSeconds * 1000
                if (dmPastTTL) log("Drop DM past TTL")
            }
        }

        scope.launch { DatabaseManager.upsertContact(env.senderID, env.senderName) }

        when (env.type) {
            MessageType.ANNOUNCE -> handleAnnounce(env, sourcePeripheralAddr)
            MessageType.MESSAGE -> if (!dmPastTTL) handleMessage(env)
            MessageType.IMAGE_CHUNK -> handleImageChunk(env)
            MessageType.MAP_LABEL -> handleMapLabel(env)
            MessageType.MAP_LABEL_VOTE -> handleMapLabelVote(env)
            MessageType.MAP_LABEL_IMAGE_CHUNK -> handleMapLabelImageChunk(env)
            MessageType.REQUEST_MAP_LABELS -> if (sourceCentralAddr != null) {
                val dev = subscribedDevices.firstOrNull { it.address == sourceCentralAddr }
                if (dev != null) pushMapLabelsToCentral(dev)
            }
            MessageType.ALERT -> handleAlert(env)
            MessageType.VOUCH -> handleVouch(env)
        }

        if (env.senderLatitude != null && env.senderLongitude != null) {
            mainScope.launch {
                val map = _senderCoordinates.value.toMutableMap()
                map[env.senderID] = env.senderLatitude to env.senderLongitude
                _senderCoordinates.value = map
            }
            scope.launch { DatabaseManager.recordSighting(env.senderID, env.senderLatitude, env.senderLongitude, 0) }
        }

        if (env.ttl > 1 && env.type != MessageType.REQUEST_MAP_LABELS && !dmPastTTL) {
            val relay = env.copy(ttl = env.ttl - 1)
            scope.launch {
                delay((50..150).random().toLong())
                broadcastEnvelope(relay, excludeCentralAddr = sourceCentralAddr, excludePeripheralAddr = sourcePeripheralAddr)
            }
        }
    }

    private fun handleAnnounce(env: MeshEnvelope, peripheralAddr: String?) {
        val a = AnnouncementPayload.fromJSON(env.payload) ?: return

        // Decode the signing public key — both iOS and Android now send URL-safe base64
        // Fall back to senderID (which is always URL-safe base64) if payload key missing
        val signingKey: ByteArray? =
            (a.publicKeyBase64?.let { KeyManager.decodePublicKeyBase64(it) })
                ?: KeyManager.decodePublicKeyBase64(env.senderID)

        mainScope.launch {
            // Store nickname
            val nicks = _announceNicknames.value.toMutableMap()
            nicks[env.senderID] = a.nickname
            _announceNicknames.value = nicks

            // Refresh saved-contact nickname cache so senderDisplayName returns correct name
            refreshNicknameCache(env.senderID)

            // Store encryption key for E2E DMs (URL-safe base64 from both iOS and Android)
            a.encryptionPublicKeyBase64?.let { b64 ->
                val key = KeyManager.decodePublicKeyBase64(b64)
                if (key != null && key.size == 32) encryptionPublicKeyByDeviceID[env.senderID] = key
            }

            // Update DiscoveredPeer with the public key so Dashboard can offer "Add contact"
            if (signingKey != null) {
                val addr = peripheralAddr ?: env.senderID
                val existing = discoveredPeerMap[addr]
                if (existing != null) {
                    discoveredPeerMap[addr] = existing.copy(
                        publicKey = signingKey,
                        nickname = a.nickname
                    )
                } else {
                    // Peer not yet in map (came via relay, not direct scan) — add by senderID key
                    // so it still shows in Dashboard with a public key
                    val relay = discoveredPeerMap[env.senderID]
                    if (relay != null) {
                        discoveredPeerMap[env.senderID] = relay.copy(
                            publicKey = signingKey,
                            nickname = a.nickname
                        )
                    } else {
                        discoveredPeerMap[env.senderID] = DiscoveredPeer(
                            id = env.senderID, name = a.nickname, rssi = 0,
                            nickname = a.nickname, linkState = "relay",
                            publicKey = signingKey, lastSeen = System.currentTimeMillis()
                        )
                    }
                }
                _discoveredPeers.value = discoveredPeerMap.values.sortedBy { it.name }

                // Update last-seen for this public key in saved contacts DB
                scope.launch { DatabaseManager.updateLastSeenForPublicKey(signingKey) }
            }
        }
        log("Announce ${a.nickname} senderID=${env.senderID} keyOk=${signingKey != null}")
    }

    private fun handleMessage(env: MeshEnvelope) {
        val chat = ChatPayload.fromJSON(env.payload) ?: return
        val me = identity.deviceID

        if (chat.recipientID != null) {
            val involved = chat.recipientID == me || env.senderID == me
            if (!involved) return
            val otherPeer = if (env.senderID == me) chat.recipientID else env.senderID
            val ch = dmChannelId(me, otherPeer)
            val pm = PersistedMessageEntity(
                id = env.id.toString(), senderID = env.senderID, senderName = env.senderName,
                text = chat.text, timestamp = env.timestamp,
                channel = ch, receivedAt = System.currentTimeMillis() / 1000
            )
            scope.launch { DatabaseManager.saveMessage(pm); DatabaseManager.pruneDMMessages(dmTTLSeconds) }
            if (env.senderID != me) {
                val msg = ChatMessage(
                    envelopeId = env.id, senderID = env.senderID, senderName = env.senderName,
                    text = chat.text, date = System.currentTimeMillis(), isLocal = false,
                    distanceFromMe = distanceFromMe(env.senderID)
                )
                mainScope.launch {
                    val map = _directThreadMessages.value.toMutableMap()
                    val arr = map.getOrDefault(otherPeer, emptyList()).toMutableList()
                    arr.add(msg)
                    map[otherPeer] = arr
                    _directThreadMessages.value = map
                }
                recordContactInbound(otherPeer, chat.text)
                postNotification(env.senderName, chat.text)
            }
        } else {
            val pm = PersistedMessageEntity(
                id = env.id.toString(), senderID = env.senderID, senderName = env.senderName,
                text = chat.text, timestamp = env.timestamp,
                channel = "broadcast", receivedAt = System.currentTimeMillis() / 1000
            )
            scope.launch { DatabaseManager.saveMessage(pm) }
            if (env.senderID != me) {
                val msg = ChatMessage(
                    envelopeId = env.id, senderID = env.senderID, senderName = env.senderName,
                    text = chat.text, date = System.currentTimeMillis(), isLocal = false,
                    distanceFromMe = distanceFromMe(env.senderID)
                )
                mainScope.launch { _chatMessages.value = _chatMessages.value + msg }
                postNotification(env.senderName, chat.text)
                recordContactInbound(env.senderID, chat.text)
            }
        }
    }

    private fun handleImageChunk(env: MeshEnvelope) {
        if (env.senderID == identity.deviceID) return
        val chunk = ImageChunkPayload.fromJSON(env.payload) ?: return
        val buf = pendingImages.getOrPut(chunk.transferId) {
            PendingImageBuffer(chunk.totalChunks, mutableMapOf(), env.senderID, env.senderName)
        }
        buf.parts[chunk.chunkIndex] = chunk.data
        if (buf.parts.size == buf.total) {
            val bos = java.io.ByteArrayOutputStream()
            for (i in 0 until buf.total) {
                val part = buf.parts[i] ?: return
                bos.write(part)
            }
            val full = bos.toByteArray()
            pendingImages.remove(chunk.transferId)
            if (full.size < 100) return
            val b64 = Base64.encodeToString(full, Base64.NO_WRAP)
            val pm = PersistedMessageEntity(
                id = env.id.toString(), senderID = env.senderID, senderName = env.senderName,
                text = "[photo]", timestamp = env.timestamp,
                channel = "broadcast", receivedAt = System.currentTimeMillis() / 1000, imageBase64 = b64
            )
            scope.launch { DatabaseManager.saveMessage(pm) }
            val msg = ChatMessage(
                envelopeId = env.id, senderID = env.senderID, senderName = env.senderName,
                text = "[photo]", date = System.currentTimeMillis(), isLocal = false,
                imageJPEGBase64 = b64
            )
            mainScope.launch { _chatMessages.value = _chatMessages.value + msg }
            postNotification(env.senderName, "[Photo]")
        }
    }

    private fun handleMapLabel(env: MeshEnvelope) {
        val wire = MapLabelPayload.fromJSON(env.payload, env.senderID, env.senderName) ?: run {
            log("Map label decode failed"); return
        }
        if (ignoredLabelIds.contains(wire.id)) return
        mainScope.launch {
            val map = _mapLabels.value.toMutableMap()
            map[wire.id] = wire
            _mapLabels.value = map
            if (env.senderID != identity.deviceID && env.ttl > 1) {
                postNotification("New map label", "${wire.category} from ${env.senderName}")
            }
        }
        log("Map label received ${wire.id}")
    }

    private fun handleMapLabelVote(env: MeshEnvelope) {
        val payload = MapLabelVotePayload.fromJSON(env.payload) ?: return
        if (payload.vote != 1 && payload.vote != -1) return
        mainScope.launch {
            val votesMap = _labelVotes.value.toMutableMap()
            val inner = votesMap.getOrDefault(payload.labelId, emptyMap()).toMutableMap()
            inner[payload.voterID] = payload.vote
            votesMap[payload.labelId] = inner
            _labelVotes.value = votesMap
        }
    }

    private fun handleMapLabelImageChunk(env: MeshEnvelope) {
        val chunk = MapLabelImageChunkPayload.fromJSON(env.payload) ?: return
        mainScope.launch {
            val buf = thumbnailBuffers.getOrPut(chunk.imageId) {
                ThumbnailChunkBuffer(chunk.labelId, chunk.total,
                    compressed = chunk.compressed == true, mutableMapOf())
            }
            buf.chunks[chunk.index] = chunk.data
            if (chunk.compressed == true) buf.compressed = true
            if (buf.chunks.size == buf.total) {
                val bos = java.io.ByteArrayOutputStream()
                for (i in 0 until buf.total) {
                    val part = buf.chunks[i] ?: return@launch
                    bos.write(part)
                }
                var data = bos.toByteArray()
                // If iOS sent LZ4-compressed, decompress before storing.
                // Android doesn't have built-in LZ4; fall back to raw display.
                // In practice iOS sends compressed=null when talking to Android-only meshes.
                if (buf.compressed) {
                    val decompressed = tryLz4Decompress(data)
                    if (decompressed != null) {
                        data = decompressed
                        log("Thumbnail LZ4 decompressed: ${bos.size()}B → ${data.size}B for label ${buf.labelId}")
                    } else {
                        log("Thumbnail LZ4 decompress failed for label ${buf.labelId} — using raw bytes")
                    }
                }
                thumbnailBuffers.remove(chunk.imageId)
                storeThumbnail(buf.labelId, data)
            }
        }
    }

    /**
     * LZ4 block decompression, compatible with Apple's Compression framework COMPRESSION_LZ4.
     *
     * Apple prepends a 4-byte little-endian uncompressed size before the raw LZ4 block data.
     * We strip that header, then decompress using lz4-java's LZ4FastDecompressor.
     *
     * Wire format (iOS sender):
     *   uncompressedSize (UInt32 LE) followed by lz4BlockData bytes
     *
     * Returns null on any failure — caller uses the original (possibly garbled) bytes.
     */
    private fun tryLz4Decompress(data: ByteArray): ByteArray? {
        return try {
            if (data.size < 4) return null

            // Read the 4-byte little-endian uncompressed size Apple prepends
            val uncompressedSize = (data[0].toInt() and 0xFF) or
                    ((data[1].toInt() and 0xFF) shl 8) or
                    ((data[2].toInt() and 0xFF) shl 16) or
                    ((data[3].toInt() and 0xFF) shl 24)

            // Sanity check: max 512KB (far larger than any thumbnail)
            if (uncompressedSize <= 0 || uncompressedSize > 512 * 1024) return null

            val lz4Block = data.copyOfRange(4, data.size)
            val output   = ByteArray(uncompressedSize)

            val factory      = net.jpountz.lz4.LZ4Factory.fastestInstance()
            val decompressor = factory.fastDecompressor()
            val written      = decompressor.decompress(lz4Block, 0, output, 0, uncompressedSize)

            if (written == uncompressedSize) output else null
        } catch (e: Exception) {
            log("LZ4 decompress failed: ${e.message}")
            null
        }
    }

    /**
     * LZ4 block compression, producing the Apple Compression-framework-compatible wire format.
     *
     * Prepends a 4-byte little-endian uncompressed size so iOS can decompress seamlessly.
     * Returns null if compression fails or doesn't reduce size (caller sends raw bytes).
     */
    private fun tryLz4Compress(data: ByteArray): ByteArray? {
        return try {
            val factory    = net.jpountz.lz4.LZ4Factory.fastestInstance()
            val compressor = factory.fastCompressor()
            val maxOut     = compressor.maxCompressedLength(data.size)
            val compressed = ByteArray(maxOut)
            val written    = compressor.compress(data, 0, data.size, compressed, 0, maxOut)

            // Only use if actually smaller
            if (written >= data.size) return null

            // Prepend 4-byte LE uncompressed size (Apple framing)
            val result = ByteArray(4 + written)
            result[0] = (data.size and 0xFF).toByte()
            result[1] = ((data.size shr 8) and 0xFF).toByte()
            result[2] = ((data.size shr 16) and 0xFF).toByte()
            result[3] = ((data.size shr 24) and 0xFF).toByte()
            compressed.copyInto(result, destinationOffset = 4, startIndex = 0, endIndex = written)
            result
        } catch (e: Exception) {
            log("LZ4 compress failed: ${e.message}")
            null
        }
    }

    private fun handleAlert(env: MeshEnvelope) {
        val payload = AlertPayload.fromJSON(env.payload) ?: return
        val alert = AlertEntity(
            id = payload.alertID, authorID = env.senderID,
            type = payload.type.value, severity = payload.severity,
            lat = payload.lat, lon = payload.lon, description = payload.description,
            createdAt = payload.createdAt, expiresAt = payload.expiresAt
        )
        scope.launch { DatabaseManager.saveAlert(alert) }
        // Alerts always notify — even in foreground — because they are safety-critical
        val typeLabel = payload.type.value.replace("_", " ")
            .replaceFirstChar { it.uppercase() }
        val desc = payload.description.takeIf { it.isNotBlank() }
        val body = if (desc != null) "$typeLabel: $desc" else "$typeLabel from ${env.senderName}"
        postNotification("⚠ Alert: ${env.senderName}", body, isAlert = true)
    }

    private fun handleVouch(env: MeshEnvelope) {
        val payload = VouchPayload.fromJSON(env.payload) ?: return
        val vouch = VouchEntity(
            alertID = payload.alertID, voucherID = env.senderID,
            value = payload.value, timestamp = System.currentTimeMillis() / 1000
        )
        scope.launch {
            DatabaseManager.saveVouch(vouch)
            DatabaseManager.recomputeTrustScore(payload.alertID)
        }
    }

    private fun storeThumbnail(labelId: UUID, data: ByteArray) {
        val map = _thumbnails.value.toMutableMap()
        if (map.size >= 20) map.remove(map.keys.first())
        map[labelId] = data
        _thumbnails.value = map
    }

    private fun appendLocalChat(env: MeshEnvelope, text: String, imageJPEGBase64: String?) {
        val msg = ChatMessage(
            envelopeId = env.id, senderID = env.senderID, senderName = env.senderName,
            text = text, date = System.currentTimeMillis(), isLocal = true,
            imageJPEGBase64 = imageJPEGBase64
        )
        mainScope.launch { _chatMessages.value = _chatMessages.value + msg }
    }

    private fun loadPersistedMessages() {
        scope.launch {
            val persisted = DatabaseManager.messages("broadcast", 200)
            val myID = identity.deviceID
            val loaded = persisted.map { pm ->
                ChatMessage(
                    envelopeId = UUID.fromString(pm.id),
                    senderID = pm.senderID, senderName = pm.senderName,
                    text = pm.text, date = pm.receivedAt * 1000,
                    isLocal = pm.senderID == myID, imageJPEGBase64 = pm.imageBase64
                )
            }
            mainScope.launch { _chatMessages.value = loaded }
        }
    }

    private fun updatePeerLinkState(addr: String, state: String) {
        discoveredPeerMap[addr]?.let { discoveredPeerMap[addr] = it.copy(linkState = state) }
        mainScope.launch { _discoveredPeers.value = discoveredPeerMap.values.sortedBy { it.name } }
    }

    private fun distanceFromMe(senderID: String): Double? {
        val my = _lastKnownLocation.value ?: return null
        val other = _senderCoordinates.value[senderID] ?: return null
        return haversineMeters(my.first, my.second, other.first, other.second)
    }

    private fun startCooldown() {
        cooldownJob?.cancel()
        lastMapLabelSendTime = System.currentTimeMillis()
        mainScope.launch { _mapLabelCooldownRemaining.value = mapLabelCooldownSeconds }
        cooldownJob = scope.launch {
            var remaining = mapLabelCooldownSeconds
            while (remaining > 0) {
                delay(1000)
                remaining -= 1
                mainScope.launch { _mapLabelCooldownRemaining.value = maxOf(0.0, remaining) }
            }
        }
    }

    private fun startPruneTimer() {
        pruneJob = scope.launch {
            while (isActive) {
                delay(120_000)
                DatabaseManager.pruneDMMessages(dmTTLSeconds)
            }
        }
    }

    /**
     * Post a notification.
     * @param isAlert  If true, uses the high-priority alert channel and fires even in foreground.
     *                 If false (chat/photo/label), suppressed when the app is foregrounded.
     */
    private fun postNotification(title: String, body: String, isAlert: Boolean = false) {
        val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as android.app.NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU && !nm.areNotificationsEnabled()) return

        // Suppress non-alert notifications when the app is in the foreground
        if (!isAlert) {
            val appInForeground = androidx.lifecycle.ProcessLifecycleOwner.get()
                .lifecycle.currentState.isAtLeast(androidx.lifecycle.Lifecycle.State.STARTED)
            if (appInForeground) return
        }

        // Tap intent — opens MainActivity (brings app to front)
        val tapIntent = android.content.Intent(context, MainActivity::class.java).apply {
            flags = android.content.Intent.FLAG_ACTIVITY_SINGLE_TOP or
                    android.content.Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val pendingFlags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M)
            android.app.PendingIntent.FLAG_UPDATE_CURRENT or android.app.PendingIntent.FLAG_IMMUTABLE
        else android.app.PendingIntent.FLAG_UPDATE_CURRENT
        val pendingIntent = android.app.PendingIntent.getActivity(
            context, 0, tapIntent, pendingFlags
        )

        val channel = if (isAlert) "mesh_alert_channel" else "mesh_channel"
        val notification = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            android.app.Notification.Builder(context, channel)
                .setContentTitle(title)
                .setContentText(body)
                .setSmallIcon(android.R.drawable.ic_dialog_info)
                .setAutoCancel(true)
                .setContentIntent(pendingIntent)
                .build()
        } else {
            @Suppress("DEPRECATION")
            android.app.Notification.Builder(context)
                .setContentTitle(title)
                .setContentText(body)
                .setSmallIcon(android.R.drawable.ic_dialog_info)
                .setAutoCancel(true)
                .setContentIntent(pendingIntent)
                .build()
        }
        nm.notify(UUID.randomUUID().hashCode(), notification)
    }

    private fun log(s: String) {
        val ts = java.text.SimpleDateFormat("HH:mm:ss", java.util.Locale.getDefault()).format(java.util.Date())
        val line = "[$ts] $s"
        Log.d(TAG, line)
        mainScope.launch {
            val lines = (_debugLines.value + line).takeLast(120)
            _debugLines.value = lines
        }
    }

    fun syncScanTimingFromUI() { /* already reactive via StateFlow */ }
}
