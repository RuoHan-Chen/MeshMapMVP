# MeshChat MVP (CoreBluetooth mesh scaffold)

Bare-bones **BitChat-style** idea (envelope + TTL + dedup + relay) using **CoreBluetooth only** — no MultipeerConnectivity, Nostr, Noise, or fragmentation.

Aligned conceptually with [`bitchat_architecture.md`](../bitchat_architecture.md): one envelope, announce + chat payloads, TTL flood, in-memory dedup.

---

## Architecture summary

| Piece | Role |
|-------|------|
| **DeviceIdentity** | Stable `deviceID` + `nickname` in UserDefaults |
| **MeshEnvelope** | JSON on the wire: `id`, `type`, `senderID`, `senderName`, `timestamp`, `ttl`, `payload` |
| **MessageType** | `.announce` (nickname JSON), `.message` (chat JSON) |
| **BluetoothMeshService** | Dual role: `CBPeripheralManager` (advertise + GATT server) + `CBCentralManager` (scan + connect + GATT client) |
| **GATT** | One service `6E400001-…`, one characteristic `6E400002-…` — **write** (central → peripheral) + **notify** (peripheral → subscribed centrals) |
| **Send** | Encode envelope → write to every connected remote characteristic → `updateValue` to all subscribed centrals |
| **Connect** | Uses the **same `CBPeripheral` instance from discovery** (manual Connect used `retrievePeripherals`, which is often **empty** until a prior session — that’s why connect failed before). **Auto-connect** runs when a peer is discovered during a scan window. |
| **Scan** | **Periodic**: scan ON (default 12s) then OFF (default 40s) to save battery; **Scan now** forces a window. |
| **Receive** | Peripheral `didReceiveWrite` or central `didUpdateValue` (notify) → decode → dedup by `envelope.id` → UI → if `ttl > 1`, decrement + jitter + rebroadcast (exclude immediate source) |

---

## File tree

```
MeshChatMVP/
├── README.md
├── MeshChatMVP.xcodeproj/
│   └── project.pbxproj
└── MeshChatMVP/
    ├── MeshChatApp.swift
    ├── ContentView.swift (tabs: Chat / Dashboard / You)
    ├── ChatView.swift
    ├── DebugDashboardView.swift
    ├── BluetoothMeshService.swift
    ├── MeshEnvelope.swift
    ├── MessageType.swift
    ├── DeviceIdentity.swift
    ├── ChatPayload.swift
    ├── AnnouncementPayload.swift
    ├── ChatMessage.swift
    └── Assets.xcassets/
```

---

## Info.plist / permissions

- **NSBluetoothAlwaysUsageDescription** — set in Xcode build settings as  
  `INFOPLIST_KEY_NSBluetoothAlwaysUsageDescription`  
  (already in `project.pbxproj`).

No background modes required for foreground demo.

---

## Run on two physical iPhones

1. Open `MeshChatMVP.xcodeproj` in Xcode.
2. Set **Team** + unique **Bundle ID** (e.g. `com.yourname.MeshChatMVP`) for each device if needed.
3. Build & run on **Phone A**, then **Phone B** (Bluetooth must be on; grant permission).
4. Wait until both show **Bluetooth: On** and **Discovered** lists populate (same room, ~10 m).
5. On **A**, tap **Connect** next to **B** (and optionally on **B** connect to **A** for symmetric links — see limitations).
6. Type a message and **Send**; open **Log** to see send/relay lines.

**Three-device relay (A–B–C):** Connect A↔B and B↔C (B must be central to both). A sends → B relays toward C with lower TTL. Reliability depends on iOS connection limits and who is peripheral/central.

---

## Simulator vs device

| | Simulator | Two real devices |
|--|-----------|------------------|
| CoreBluetooth central/peripheral | **Unreliable / often non-functional** for real BLE mesh | **Required** for discovery, connect, notify |
| Compile | Yes | Yes |
| Proof of relay + TTL + dedup | No | Yes |

---

## Known iOS CoreBluetooth limitations (honest)

- **Simulator:** BLE is not a substitute for device testing.
- **Connection model:** Each link is central ↔ peripheral; a **full mesh** needs many simultaneous connections — iOS limits how many centrals/peripherals you can hold (~7 central links often cited; behavior varies).
- **Not symmetric by default:** If only A connects to B, B might not have an outbound central link to A unless B also taps Connect on A (both sides advertising + both scanning helps discovery; **both may need to connect** to get bidirectional notify+write depending on topology).
- **ATT MTU:** Keep JSON envelopes small (app caps at 512 bytes).
- **Background:** Without background modes + entitlements, **no guarantee** of relay when app is suspended.
- **No production claims:** Jitter + dedup reduce loops but do not make a robust production mesh.

---

## Stubbed / later phases

- Persistent chat history
- Fragmentation, compression, signing
- Source routing / topology graph
- Background relay + queue
- Android interop
- Bonding / security

---

## Self-review (compilation)

- Swift 5, iOS 16+ deployment target.
- `MessageType` is `Codable`; `MeshEnvelope` uses JSON `Data` (base64 in JSON).
- `CBManagerState` used in SwiftUI — **import CoreBluetooth** in `ContentView.swift` (done).
- Set your **Development Team** in Xcode if signing fails.
