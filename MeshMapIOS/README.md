# MeshChat MVP

**Bluetooth LE mesh** (Core Bluetooth) + **E2E encrypted DMs** between two people.

- **Transport:** Dual-role GATT (`6E400001-…` / `6E400002-…`), scan + advertise, write + notify, TTL relay.
- **Identity:** Ed25519-style signing keypair in Keychain → stable **deviceID** (base64 public key).
- **DM encryption:** Separate **X25519** keypair → announces include `encryptionPublicKeyBase64`. Direct messages use **ECDH + HKDF-SHA256 + AES-GCM** when both sides have exchanged announces; otherwise plaintext fallback (older peers).

## Build

```bash
cd MeshChatMVP
xcodebuild -project MeshChatMVP.xcodeproj -scheme MeshChatMVP -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' build
```

Or open **`MeshChatMVP.xcodeproj`** in Xcode → Run on **two physical devices** (BLE). Simulators have limited BLE; prefer real hardware.

## Run

1. Install on two phones, Bluetooth on, app in foreground.
2. Then use the public chat, direct message, post events, see locations of other members, and receive alerts.

## Project structure

```
MeshChatMVP/
├── App/              # App entry point
│   └── MeshChatApp.swift
├── Views/            # SwiftUI screens and view hierarchy
│   ├── ContentView.swift, ChatView.swift, MapTabView.swift
│   ├── AlertFeedView.swift, ContactsListView.swift
│   ├── PrivateChatView.swift, ContactEditorView.swift
├── Models/           # Domain and data models
│   ├── Contact.swift, SavedContact.swift, ChatMessage.swift
│   ├── PersistedMessage.swift, Alert.swift, DeviceIdentity.swift
│   ├── NodeSighting.swift, Vouch.swift, MapLabelModels.swift
├── Payloads/         # Wire / mesh envelope types
│   ├── MeshEnvelope.swift, MessageType.swift
│   ├── ChatPayload.swift, AnnouncementPayload.swift
│   ├── AlertPayload.swift, VouchPayload.swift, ImageChunkPayload.swift
├── Services/         # Business logic, mesh, crypto, persistence
│   ├── BluetoothMeshService.swift, DatabaseManager.swift
│   ├── KeyManager.swift, ChatCrypto.swift
│   ├── WiFiMonitor.swift, MeshNewsPublish.swift
│   ├── SpeechManager.swift, AlertTrustEngine.swift
├── Utilities/        # Helpers and config
│   ├── MeshImageUtils.swift, EventTypesConfig.swift
└── Resources/       # Assets
    └── Assets.xcassets
```

## Main files

| File | Role |
|------|------|
| `Services/BluetoothMeshService.swift` | BLE mesh, relay, DM send/receive |
| `Services/ChatCrypto.swift` | AES-GCM + X25519 DM crypto |
| `Services/KeyManager.swift` | Signing + encryption keypairs (Keychain) |
| `Payloads/AnnouncementPayload.swift` | Nickname + signing key + **encryption** key |
| `Payloads/ChatPayload.swift` | DM JSON (`encrypted` + `ciphertextB64` or `text`) |
