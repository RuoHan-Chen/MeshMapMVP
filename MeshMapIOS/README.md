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
2. Wait for link / announce so each learns the other’s **encryption** key.
3. Add/save contact if your UI requires it; open **private chat** and send — payload on the wire is **ciphertext** when encrypted.

## Main files

| File | Role |
|------|------|
| `MeshChatMVP/BluetoothMeshService.swift` | BLE mesh, relay, DM send/receive |
| `MeshChatMVP/ChatCrypto.swift` | AES-GCM + X25519 DM crypto |
| `MeshChatMVP/KeyManager.swift` | Signing + encryption keypairs (Keychain) |
| `MeshChatMVP/AnnouncementPayload.swift` | Nickname + signing key + **encryption** key |
| `MeshChatMVP/ChatPayload.swift` | DM JSON (`encrypted` + `ciphertextB64` or `text`) |
