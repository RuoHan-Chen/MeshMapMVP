package com.meshchat.mvp.ui.dashboard

import androidx.compose.foundation.*
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.meshchat.mvp.bluetooth.BluetoothMeshService
import com.meshchat.mvp.crypto.KeyManager
import com.meshchat.mvp.database.DatabaseManager
import com.meshchat.mvp.database.SavedContactEntity
import com.meshchat.mvp.model.DiscoveredPeer
import kotlinx.coroutines.launch
import java.util.UUID

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun DashboardScreen(mesh: BluetoothMeshService) {
    val peers by mesh.discoveredPeers.collectAsState()
    val connectedCount by mesh.connectedPeerCount.collectAsState()
    val subscribedCount by mesh.subscribedCentralCount.collectAsState()
    val isScanning by mesh.isScanning.collectAsState()
    val secondsUntilScan by mesh.secondsUntilNextScan.collectAsState()
    val debugLines by mesh.debugLines.collectAsState()
    val bluetoothOn by mesh.bluetoothOn.collectAsState()
    val gattServerActive by mesh.gattServerActive.collectAsState()
    val advertisingActive by mesh.advertisingActive.collectAsState()
    val autoConnect by mesh.autoConnectEnabled.collectAsState()
    val autoReconnect by mesh.autoReconnectEnabled.collectAsState()
    val scanWindow by mesh.scanWindowSeconds.collectAsState()
    val scanIdle by mesh.scanIdleSeconds.collectAsState()

    var editorPeer by remember { mutableStateOf<DiscoveredPeer?>(null) }
    val scope = rememberCoroutineScope()

    LazyColumn(
        modifier = Modifier.fillMaxSize(),
        contentPadding = PaddingValues(bottom = 24.dp)
    ) {
        item {
            TopAppBar(title = { Text("Dashboard") })
        }

        // ── Bluetooth status ──────────────────────────────────────────────────
        item {
            SectionHeader("Bluetooth")
            LabeledRow("Adapter") {
                Text(if (bluetoothOn) "On" else "Off",
                    color = if (bluetoothOn) Color(0xFF4CAF50) else MaterialTheme.colorScheme.error)
            }
            LabeledRow("Peripheral (GATT server)") {
                Text(if (gattServerActive) "Running" else "Off",
                    color = if (gattServerActive) Color(0xFF4CAF50) else MaterialTheme.colorScheme.error)
            }
            LabeledRow("Advertising") {
                Text(if (advertisingActive) "On" else "Off",
                    color = if (advertisingActive) Color(0xFF4CAF50) else MaterialTheme.colorScheme.error)
            }
            LabeledRow("Central (scanning)") {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    Box(Modifier.size(10.dp).background(
                        if (isScanning) Color(0xFF4CAF50) else Color(0xFFFF9800),
                        shape = androidx.compose.foundation.shape.CircleShape
                    ))
                    Text(if (isScanning) "Scanning" else if (secondsUntilScan > 0) "Idle (${secondsUntilScan.toInt()}s)" else "Idle")
                }
            }
            LabeledRow("Subscribers (others linked to you)") { Text("$subscribedCount") }
            LabeledRow("Outbound links ready") { Text("$connectedCount") }
        }

        // ── Scan cycle ────────────────────────────────────────────────────────
        item {
            SectionHeader("Scan cycle (saves battery)")
            ListItem(
                headlineContent = { Text("Auto-connect when a peer is seen") },
                trailingContent = {
                    Switch(checked = autoConnect,
                        onCheckedChange = { mesh.autoConnectEnabled.value = it })
                }
            )
            ListItem(
                headlineContent = { Text("Auto-reconnect after drop (off = calmer)") },
                trailingContent = {
                    Switch(checked = autoReconnect,
                        onCheckedChange = { mesh.autoReconnectEnabled.value = it })
                }
            )
            Column(Modifier.padding(horizontal = 16.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text("Scan ON", Modifier.width(70.dp), style = MaterialTheme.typography.bodySmall)
                    Slider(
                        value = scanWindow.toFloat(),
                        onValueChange = { mesh.scanWindowSeconds.value = it.toDouble() },
                        valueRange = 4f..30f, steps = 25,
                        modifier = Modifier.weight(1f)
                    )
                    Text("${scanWindow.toInt()}s", Modifier.width(36.dp),
                        style = MaterialTheme.typography.bodySmall)
                }
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text("Scan OFF", Modifier.width(70.dp), style = MaterialTheme.typography.bodySmall)
                    Slider(
                        value = scanIdle.toFloat(),
                        onValueChange = { mesh.scanIdleSeconds.value = it.toDouble() },
                        valueRange = 15f..120f, steps = 20,
                        modifier = Modifier.weight(1f)
                    )
                    Text("${scanIdle.toInt()}s", Modifier.width(36.dp),
                        style = MaterialTheme.typography.bodySmall)
                }
            }
            ListItem(
                headlineContent = { },
                trailingContent = {
                    OutlinedButton(onClick = { mesh.syncScanTimingFromUI() }) {
                        Text("Apply timing (next cycle)")
                    }
                }
            )
            if (!isScanning && secondsUntilScan > 0) {
                LabeledRow("Next scan in") { Text("${secondsUntilScan.toInt()}s") }
            }
            ListItem(
                headlineContent = { },
                trailingContent = {
                    OutlinedButton(onClick = { mesh.scanNow() }) { Text("Scan now") }
                }
            )
        }

        // ── Peers ─────────────────────────────────────────────────────────────
        item { SectionHeader("Peers (tap fingerprint to save contact)") }
        if (peers.isEmpty()) {
            item {
                ListItem(headlineContent = {
                    Text("No peers — both apps open, wait for scan.",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant)
                })
            }
        } else {
            items(peers) { peer ->
                PeerRow(peer = peer, onTap = { if (peer.publicKey != null) editorPeer = peer })
            }
        }

        // ── Maintenance ───────────────────────────────────────────────────────
        item {
            SectionHeader("Maintenance (local only)")
            ListItem(headlineContent = {
                TextButton(onClick = { mesh.clearChatMessages() }) {
                    Text("Clear chat messages", color = MaterialTheme.colorScheme.error)
                }
            })
            ListItem(headlineContent = {
                TextButton(onClick = { mesh.clearLocalEvents() }) {
                    Text("Clear map events", color = MaterialTheme.colorScheme.error)
                }
            })
            ListItem(headlineContent = {
                TextButton(onClick = { mesh.clearDebugLog() }) {
                    Text("Clear log", color = MaterialTheme.colorScheme.error)
                }
            })
        }

        // ── Log ───────────────────────────────────────────────────────────────
        item {
            SectionHeader("Log")
            Surface(
                modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp),
                shape = MaterialTheme.shapes.small,
                color = MaterialTheme.colorScheme.surfaceVariant
            ) {
                Text(
                    text = debugLines.joinToString("\n"),
                    modifier = Modifier.padding(8.dp),
                    style = MaterialTheme.typography.labelSmall.copy(
                        fontFamily = FontFamily.Monospace, fontSize = 10.sp
                    )
                )
            }
        }
    }

    // ── Contact editor sheet ──────────────────────────────────────────────────
    editorPeer?.let { peer ->
        val pk = peer.publicKey!!
        ContactEditorBottomSheet(
            publicKey = pk,
            onDismiss = { editorPeer = null },
            onSaved = { mesh.bumpContactsVersion(); editorPeer = null }
        )
    }
}

@Composable
private fun PeerRow(peer: DiscoveredPeer, onTap: () -> Unit) {
    val fingerprint = peer.publicKey?.let { KeyManager.fingerprint(it, 8) } ?: "—"
    ListItem(
        headlineContent = {
            Column {
                Text(peer.name, fontWeight = FontWeight.Medium)
                Text("RSSI ${peer.rssi} · ${peer.linkState}",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant)
                Text(fingerprint,
                    style = MaterialTheme.typography.labelSmall.copy(fontFamily = FontFamily.Monospace),
                    color = if (peer.publicKey != null) MaterialTheme.colorScheme.primary
                    else MaterialTheme.colorScheme.onSurfaceVariant)
                Text(
                    if (peer.publicKey == null) "Connect to receive public key"
                    else "Tap to add or edit contact",
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.6f)
                )
            }
        },
        modifier = Modifier.clickable(enabled = peer.publicKey != null, onClick = onTap)
    )
}

@Composable
private fun SectionHeader(text: String) {
    Text(
        text, modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp),
        style = MaterialTheme.typography.labelSmall,
        color = MaterialTheme.colorScheme.primary,
        fontWeight = FontWeight.Bold
    )
    HorizontalDivider()
}

@Composable
private fun LabeledRow(label: String, content: @Composable () -> Unit) {
    ListItem(
        headlineContent = { Text(label) },
        trailingContent = content
    )
}

// ── Contact editor (reused from ContactsScreen) ───────────────────────────────

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ContactEditorBottomSheet(
    publicKey: ByteArray,
    existingId: String? = null,
    onDismiss: () -> Unit,
    onSaved: () -> Unit
) {
    val scope = rememberCoroutineScope()
    var nickname by remember { mutableStateOf("") }
    var relationship by remember { mutableStateOf(SavedContactEntity.ASSOCIATE) }
    var existing by remember { mutableStateOf<SavedContactEntity?>(null) }
    var confirmDelete by remember { mutableStateOf(false) }
    val fingerprint = KeyManager.fingerprint(publicKey, 8)

    LaunchedEffect(publicKey) {
        existing = DatabaseManager.findContactByPublicKey(publicKey)
        existing?.let { nickname = it.nickname; relationship = it.relationship }
    }

    ModalBottomSheet(onDismissRequest = onDismiss) {
        Column(Modifier.padding(horizontal = 16.dp).navigationBarsPadding()) {
            Text(
                if (existing == null) "Add contact" else "Edit contact",
                style = MaterialTheme.typography.titleMedium
            )
            Spacer(Modifier.height(12.dp))

            Text("Public key", style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant)
            Text(fingerprint, style = MaterialTheme.typography.bodyMedium.copy(fontFamily = FontFamily.Monospace))
            Text("${publicKey.size} bytes · cannot change",
                style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant)

            Spacer(Modifier.height(12.dp))
            OutlinedTextField(
                value = nickname, onValueChange = { nickname = it },
                label = { Text("Nickname") }, modifier = Modifier.fillMaxWidth()
            )
            Spacer(Modifier.height(8.dp))
            Text("Relationship", style = MaterialTheme.typography.labelSmall)
            Spacer(Modifier.height(4.dp))
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                listOf(SavedContactEntity.ASSOCIATE to "Associate", SavedContactEntity.FRIEND to "Friend")
                    .forEach { (value, label) ->
                        FilterChip(
                            selected = relationship == value,
                            onClick = { relationship = value },
                            label = { Text(label) }
                        )
                    }
            }

            if (existing != null) {
                Spacer(Modifier.height(8.dp))
                TextButton(onClick = { confirmDelete = true }) {
                    Icon(Icons.Filled.Delete, null, tint = MaterialTheme.colorScheme.error, modifier = Modifier.size(16.dp))
                    Spacer(Modifier.width(4.dp))
                    Text("Delete contact", color = MaterialTheme.colorScheme.error)
                }
            }

            Spacer(Modifier.height(12.dp))
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp, Alignment.End)) {
                TextButton(onClick = onDismiss) { Text("Cancel") }
                Button(
                    onClick = {
                        val name = nickname.trim()
                        if (name.isEmpty()) return@Button
                        scope.launch {
                            val now = System.currentTimeMillis() / 1000
                            val ex = existing
                            if (ex != null) {
                                DatabaseManager.updateContact(ex.copy(nickname = name, relationship = relationship, lastSeen = now))
                            } else {
                                DatabaseManager.createContact(SavedContactEntity(
                                    id = UUID.randomUUID().toString(), nickname = name,
                                    relationship = relationship, firstSeen = now, lastSeen = now, publicKey = publicKey
                                ))
                            }
                            onSaved()
                        }
                    },
                    enabled = nickname.trim().isNotEmpty()
                ) { Text("Save") }
            }
            Spacer(Modifier.height(8.dp))
        }
    }

    if (confirmDelete) {
        AlertDialog(
            onDismissRequest = { confirmDelete = false },
            title = { Text("Delete this contact?") },
            text = { Text("You can add them again later from Dashboard or chat.") },
            confirmButton = {
                TextButton(onClick = {
                    confirmDelete = false
                    scope.launch {
                        existing?.let { DatabaseManager.deleteContact(it) }
                        onSaved()
                    }
                }) { Text("Delete", color = MaterialTheme.colorScheme.error) }
            },
            dismissButton = { TextButton(onClick = { confirmDelete = false }) { Text("Cancel") } }
        )
    }
}
