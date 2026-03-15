# MeshChat MVP — Iteration 2 fixes

Summary of changes from iteration 1: **no double send**, **no duplicate peers in UI**, **local notifications** for incoming messages when not in foreground, **chat history persisted** with a **20-minute TTL**.

---

## 1. UI double sending

**Causes**

- Same chat envelope could be shown twice: once from `appendLocalChat` and again when the packet **echoed back** over BLE (relay / multiple paths). Dedup ran only on receive; the sender never marked their own `envelope.id` as seen before broadcast.
- Fast **double tap** on Send could fire twice.

**Fixes**

- On send, **`markSeen(envelope.id)` on the BLE queue before `broadcastEnvelope`**, so any copy of that envelope that comes back into `handleIncomingData` hits dedup and does not append again.
- In `handleIncomingData` for `.message`, **do not append** when `senderID == identity.deviceID` (only relay if TTL allows; append already happened locally).
- Chat send button: **350ms cooldown** + disabled state so double tap does not send twice.

Files: `BluetoothMeshService.swift` (`sendChat`, `handleIncomingData`), `ChatView.swift`.

---

## 2. Peers showing up twice (discovered list)

**Causes**

- **Race on main queue**: many `didDiscover` callbacks (scan uses `AllowDuplicatesKey: true`) each did `async { append if not found }`; two blocks could append the same logical peer before either updated the array → duplicate rows.
- **Dashboard UX**: the same device appeared under **“Peers (discovery)”** and again under **“Connected (you are central)”**.

**Fixes**

- **`discoveredPeerById: [UUID: DiscoveredPeer]`** on the main thread: every update **upserts by `peripheral.identifier`**, then **`discoveredPeers = sorted(values)`**. One row per BLE peripheral id.
- Dashboard: **single section** “Peers (one row per device)” with optional GATT state merged into the subtitle (removed duplicate Connected-only list).

Files: `BluetoothMeshService.swift` (`publishDiscoveredPeer`), `DebugDashboardView.swift`.

---

## 3. Notifications

- **`UserNotifications`**: request **alert + sound** on startup.
- When a **remote** chat message is appended and **`UIApplication.shared.applicationState != .active`**, post a **local notification** (title = sender name, body = message text).

Files: `BluetoothMeshService.swift` (`requestNotificationAuthIfNeeded`, `notifyIncomingIfNeeded`).

**Note:** User must allow notifications in the system prompt. BLE delivery still depends on app/foreground behavior; notifications only fire when a message is actually received and decoded.

---

## 4. History persistence (20-minute TTL)

- **`ChatMessage` conforms to `Codable`**.
- History stored at  
  `Application Support/MeshChatMVP/chat_history.json`.
- **On launch:** load JSON, **drop messages older than 20 minutes**, set `chatMessages`. Any legacy rows with embedded photos are **stripped to `[photo]`** (no image bytes reloaded).
- **On each save:** **only text metadata** is written — **`imageJPEGBase64` is never stored** on disk.
- **Timer every 60s:** prune + save so old lines disappear even if idle.

Constant: `chatHistoryTTLSeconds = 20 * 60` (easy to change later).

Files: `ChatMessage.swift`, `BluetoothMeshService.swift` (`loadChatHistory`, `saveChatHistory`, `pruneChatByTTL`, `startChatHistoryPruneTimer`).

---

## File touch list

| File | Change |
|------|--------|
| `BluetoothMeshService.swift` | Dedup-before-send, skip self-append, peer map, notifications, history I/O + TTL |
| `ChatView.swift` | Send cooldown |
| `ChatMessage.swift` | `Codable` |
| `DebugDashboardView.swift` | Single peer section, no duplicate Connected block |

---

## 5. Simple image upload (iteration 3)

- **Photos** button → `PhotosPicker` → JPEG resized (~320px) + compressed (≤12KB), same idea as BitChat’s `ImageUtils` but smaller for BLE.
- Wire uses **`MessageType.imageChunk`**: each BLE envelope stays **≤512 B** (same as text), so the JPEG is split into **40-byte** chunks with a shared `transferId`; peers reassemble and show one bubble.
- **`ChatMessage.imageJPEGBase64`** is **in-memory only**; history on disk stores **`[photo]`** placeholders, not JPEG data.

Files: `MessageType.swift`, `ImageChunkPayload.swift`, `MeshImageUtils.swift`, `ChatMessage.swift`, `BluetoothMeshService.swift` (`sendImage`, `mergeImageChunk`), `ChatView.swift`.

---

## Still out of scope (same as iteration 1)

- Background BLE relay guarantees
- E2E encryption / fragmentation
- Cross-platform Android

See `iteration1.md` for architecture baseline.
