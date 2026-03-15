# MeshChat MVP

**Off-grid, peer-to-peer mesh networking for chat, alerts, and crisis reporting.** No central server: devices form a Bluetooth Low Energy mesh, relay messages with Time-to-Live and deduplication, and support end-to-end encrypted direct messages and image transfer. Optional integration with a web-based **MeshNews** app turns mesh-derived data into local news-style stories and recommendations.

---

## What’s in this repo

| Project | Description |
|--------|-------------|
| **[MeshMapIOS](MeshMapIOS/)** | iOS app (Swift, SwiftUI, CoreBluetooth). BLE mesh, E2E DMs (AES-GCM), image chunking, alerts/map, contacts. |
| **[MeshMapAndroid](MeshMapAndroid/MeshChatAndroid/)** | Android app (Kotlin, Jetpack Compose). Same mesh protocol: dual-role BLE, TTL relay, dedup, E2E DMs, map/chat. |
| **[News](News/)** | Web app (Next.js, TypeScript, Tailwind). Consumes mesh export / SOS-style payloads; generates stories, recommendations, optional Twilio escalation. Deploy to Vercel. |
| **[DevelopmentDocs](DevelopmentDocs/)** | Architecture, features, and diagram notes (e.g. [FeaturesAndArchitecture.md](DevelopmentDocs/FeaturesAndArchitecture.md)). |

---

## How the mesh works (iOS & Android)

- **Dual-role BLE:** Every device is both a **broadcaster** (advertise, GATT server) and a **receiver** (scan, GATT client). No central infrastructure.
- **Message propagation:** Messages are sent in **envelopes** (id, TTL, payload). Each peer that receives an envelope decrements TTL and relays to others; **deduplication by envelope ID** prevents infinite loops.
- **Images:** Photos are compressed and **chunked into small BLE-sized packets** (e.g. 40-byte), sent as multiple envelopes, and **reassembled** on the receiving device.
- **Direct messages:** **End-to-end encrypted** with AES-GCM (X25519 ECDH + HKDF-SHA256 for key agreement). Only the intended recipient can decrypt.

---

## Quick start

### iOS (MeshMapIOS)

```bash
cd MeshMapIOS
# Open MeshChatMVP.xcodeproj in Xcode, or:
xcodebuild -project MeshChatMVP.xcodeproj -scheme MeshChatMVP -sdk iphonesimulator build
```

Use **two physical devices** for real BLE; simulators have limited Bluetooth support. See [MeshMapIOS/README.md](MeshMapIOS/README.md).

### Android (MeshMapAndroid)

```bash
cd MeshMapAndroid/MeshChatAndroid
# Open in Android Studio, or use Gradle
./gradlew assembleDebug
```

Set a **Google Maps API key** in `AndroidManifest.xml`. See [MeshMapAndroid/MeshChatAndroid/README.md](MeshMapAndroid/MeshChatAndroid/README.md).

### News (web)

```bash
cd News
npm install
npm run dev
```

Open [http://localhost:3000](http://localhost:3000). Optional: `CLAUDE_API_KEY` for AI-generated stories, Twilio for SMS. See [News/README.md](News/README.md).

---

## Tech stack (summary)

| Layer | iOS | Android | News |
|------|-----|---------|------|
| **App** | Swift, SwiftUI | Kotlin, Jetpack Compose | Next.js 16, React 19, TypeScript |
| **BLE** | CoreBluetooth | BluetoothManager (BLE API) | — |
| **Crypto** | CryptoKit (X25519, AES-GCM, HKDF) | javax.crypto (ECDH, AES-GCM) | — |
| **Storage** | Keychain + GRDB (SQLite) | Keystore + Room | IndexedDB / optional Supabase |
| **Maps** | MapKit | Google Maps Compose | Leaflet |
| **Deploy** | App Store | Play Store | Vercel |

---

## License

See repository license (if any). MeshChat MVP is an MVP/demo codebase for off-grid mesh and crisis reporting.
