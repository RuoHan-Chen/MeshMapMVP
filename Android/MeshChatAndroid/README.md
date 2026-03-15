# MeshChat MVP — Android Port

A full Android conversion of the iOS SwiftUI/CoreBluetooth MeshChat MVP app.

## Architecture Map (iOS → Android)

| iOS | Android |
|-----|---------|
| SwiftUI `TabView` | Jetpack Compose `NavigationBar` |
| `@EnvironmentObject BluetoothMeshService` | `MeshViewModel` + `StateFlow` |
| `CoreBluetooth` (CBCentralManager + CBPeripheralManager) | `BluetoothManager` (BLE Scanner + GATT Server) |
| `CoreLocation` | `FusedLocationProviderClient` |
| `GRDB` + SQLite | Room Database |
| `UserDefaults` | `SharedPreferences` |
| `Keychain` (Curve25519 keys) | Android Keystore (EC P-256) |
| `CryptoKit` (AES-GCM, X25519) | `javax.crypto` (AES-GCM, ECDH) |
| `MapKit` | Google Maps Compose |
| `PhotosUI.PhotosPicker` | `ActivityResultContracts.GetContent` |
| `UNUserNotificationCenter` | `NotificationManager` |
| `UIImage` JPEG compress | `Bitmap.compress(JPEG)` |

## File Structure

```
app/src/main/java/com/meshchat/mvp/
├── MainActivity.kt              # Entry point, permissions, notification channel
├── MeshViewModel.kt             # AndroidViewModel holding BluetoothMeshService
├── bluetooth/
│   ├── BluetoothMeshService.kt  # Core BLE mesh engine (BLE central + peripheral dual role)
│   └── BleMeshForegroundService.kt  # Keeps BLE alive when backgrounded
├── crypto/
│   └── KeyManager.kt            # Keystore keypair + ChatCrypto (AES-GCM E2E DMs)
├── database/
│   ├── Database.kt              # Room entities, DAOs, MeshDatabase
│   └── DatabaseManager.kt       # Singleton DB access (matches iOS DatabaseManager)
├── model/
│   ├── Models.kt                # ChatMessage, MapLabelRecord, DeviceIdentity, etc.
│   └── Payloads.kt              # MeshEnvelope + all wire payloads (JSON)
└── ui/
    ├── MeshApp.kt               # NavHost + BottomNavigation (5 tabs)
    ├── theme/Theme.kt           # Material3 dynamic theme
    ├── chat/
    │   ├── ChatScreen.kt        # Group chat + contacts strip
    │   ├── PrivateChatScreen.kt # 1:1 DM thread
    │   └── MeshImageUtilsAndroid.kt  # JPEG compress/resize for BLE mesh
    ├── map/
    │   └── MapScreen.kt         # Google Maps + label clusters + voting + add label sheet
    ├── dashboard/
    │   └── DashboardScreen.kt   # BLE diagnostics, peer list, scan controls, log
    ├── contacts/
    │   └── ContactsScreen.kt    # Saved contacts list with unread badges
    └── profile/
        └── ProfileScreen.kt     # Identity, nickname, share-location toggle
```

## Setup Instructions

### 1. Prerequisites
- Android Studio Hedgehog or newer
- Android SDK 26+ (minSdk 26)
- A Google Maps API key

### 2. Google Maps API Key
Replace `YOUR_MAPS_API_KEY_HERE` in `AndroidManifest.xml`:
```xml
<meta-data
    android:name="com.google.android.geo.API_KEY"
    android:value="YOUR_ACTUAL_KEY"/>
```
Get a key at https://console.cloud.google.com → Maps SDK for Android.

### 3. Build & Run
```bash
# Clone or open in Android Studio
cd MeshChatAndroid
./gradlew assembleDebug
# or Open in Android Studio and press Run
```

### 4. Required Permissions (granted at runtime)
The app requests on first launch:
- `BLUETOOTH_SCAN`, `BLUETOOTH_ADVERTISE`, `BLUETOOTH_CONNECT` (Android 12+)
- `ACCESS_FINE_LOCATION` (required for BLE scanning on older APIs + map features)
- `POST_NOTIFICATIONS` (Android 13+)
- `READ_MEDIA_IMAGES` / `READ_EXTERNAL_STORAGE` (photo picking)

## BLE Wire Format Compatibility

The wire protocol is **100% compatible** with the iOS app:
- Same GATT Service UUID: `6E400001-B5A3-F393-E0A9-E50E24DCCA9E`
- Same Characteristic UUID: `6E400002-B5A3-F393-E0A9-E50E24DCCA9E`
- Same JSON envelope format (`id`, `type`, `senderID`, `ttl`, `payload`, etc.)
- Same short keys for map label payloads (`i`, `c`, `a`, `o`, `t`, `n`, `d`, `s`)
- Same TTL-based flooding + UUID dedup
- Same 512-byte max envelope size
- Same DM 20-minute TTL

## Key Design Decisions

### Crypto / Keys
Android Keystore doesn't natively support Curve25519. The implementation uses
EC P-256 (available in Android Keystore) and derives a stable 32-byte device ID
via SHA-256 of the public key. For **full cross-platform Curve25519 compatibility**
(so Android ↔ iOS DM encryption works), integrate:
- [Tink](https://developers.google.com/tink/install-tink-without-boringssl) for Curve25519/X25519
- Or [libsodium-android](https://github.com/joshjdevl/libsodium-jni) via JNI

The BLE flooding, chat, map labels, votes, and contacts all work cross-platform
without this — only E2E encrypted DMs need key-format alignment.

### Database
Room replaces GRDB. All tables match the iOS schema:
`saved_contacts`, `contacts`, `messages`, `alerts`, `vouches`, `node_sightings`.

### Notifications
Notification channel `mesh_fg_channel` (foreground service, low importance) +
`mesh_channel` (incoming messages, default importance) are created in `MainActivity`.

### Location
`FusedLocationProviderClient` replaces `CLLocationManager`. Updates every 30s
or 50m — same sharing semantics as iOS (opt-in via "Share location" toggle).

## Feature Parity

| Feature | iOS | Android |
|---------|-----|---------|
| BLE mesh flood + dedup + TTL relay | ✅ | ✅ |
| Group broadcast chat | ✅ | ✅ |
| 1:1 DM (with E2E encryption) | ✅ | ✅* |
| Photo sending (chunked BLE) | ✅ | ✅ |
| Map labels + voting | ✅ | ✅ |
| Label thumbnail photos | ✅ | ✅ |
| Contacts (save/edit/delete) | ✅ | ✅ |
| Unread badges | ✅ | ✅ |
| Debug dashboard | ✅ | ✅ |
| Scan cycle control (window/idle) | ✅ | ✅ |
| Compass heading | ✅ | ⬜ (easy to add via SensorManager) |
| Offline map caching | ✅ | ✅ (Google Maps auto-caches) |
| Alerts + vouches (DB) | ✅ | ✅ |
| Foreground BLE service | ✅ | ✅ |

*DM encryption requires Curve25519 key-format alignment for cross-platform decryption.
