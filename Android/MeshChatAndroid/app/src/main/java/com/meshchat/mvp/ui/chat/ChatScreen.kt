package com.meshchat.mvp.ui.chat

import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.*
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.*
import androidx.compose.foundation.shape.*
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import coil.compose.AsyncImage
import com.meshchat.mvp.bluetooth.BluetoothMeshService
import com.meshchat.mvp.crypto.KeyManager
import com.meshchat.mvp.database.DatabaseManager
import com.meshchat.mvp.database.SavedContactEntity
import com.meshchat.mvp.model.ChatMessage
import java.text.SimpleDateFormat
import java.util.*

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ChatScreen(
    mesh: BluetoothMeshService,
    onNavigateToPrivateChat: (String, String) -> Unit
) {
    val messages by mesh.chatMessages.collectAsState()
    val contactActivity by mesh.contactActivity.collectAsState()
    val contactsVersion by mesh.contactsVersion.collectAsState()
    val isScanning by mesh.isScanning.collectAsState()
    val secondsUntilScan by mesh.secondsUntilNextScan.collectAsState()
    val connectedCount by mesh.connectedPeerCount.collectAsState()
    val subscribedCount by mesh.subscribedCentralCount.collectAsState()
    val context = LocalContext.current

    var draft by remember { mutableStateOf("") }
    var savedContacts by remember { mutableStateOf<List<SavedContactEntity>>(emptyList()) }
    var imageBusy by remember { mutableStateOf(false) }
    var showPhotoInfo by remember { mutableStateOf(false) }
    val listState = rememberLazyListState()
    // Public key of an unknown sender the user tapped — opens the Add Contact sheet
    var pendingContactKey by remember { mutableStateOf<ByteArray?>(null) }

    // Load contacts
    LaunchedEffect(contactsVersion) {
        savedContacts = DatabaseManager.listContacts()
    }

    val visible = messages.filter { !it.isExpired }
    LaunchedEffect(visible.size) {
        if (visible.isNotEmpty()) listState.animateScrollToItem(visible.size - 1)
    }

    val pickImageLauncher = rememberLauncherForActivityResult(ActivityResultContracts.GetContent()) { uri: Uri? ->
        uri ?: return@rememberLauncherForActivityResult
        imageBusy = true
        val inputStream = context.contentResolver.openInputStream(uri) ?: return@rememberLauncherForActivityResult
        val rawBytes = inputStream.readBytes()
        inputStream.close()
        // Simple resize to ~320px JPEG
        val compressed = MeshImageUtilsAndroid.compressForMesh(context, rawBytes)
        if (compressed != null) {
            mesh.sendImage(compressed) { _ -> imageBusy = false }
        } else {
            imageBusy = false
        }
    }

    val unreadTotal = contactActivity.values.sumOf { it.unread }
    val identity by mesh.identityFlow.collectAsState()
    val titleText = if (unreadTotal > 0) "Chat · $unreadTotal unread" else identity.nickname

    Column(Modifier.fillMaxSize()) {
        // Top bar
        TopAppBar(
            title = { Text(titleText, style = MaterialTheme.typography.titleMedium) },
            actions = {
                IconButton(onClick = { showPhotoInfo = true }) {
                    Icon(Icons.Filled.Info, "Photo info")
                }
            }
        )

        // Status strip
        StatusStrip(isScanning = isScanning, secondsUntilScan = secondsUntilScan,
            linked = connectedCount > 0 || subscribedCount > 0)

        // Contacts quick section
        if (savedContacts.isNotEmpty()) {
            ContactsQuickRow(
                contacts = savedContacts,
                contactActivity = contactActivity,
                onTap = { contact ->
                    val peerID = DatabaseManager.canonicalSenderID(contact.publicKey)
                    onNavigateToPrivateChat(peerID, contact.nickname)
                }
            )
            HorizontalDivider()
        }

        if (imageBusy) {
            LinearProgressIndicator(modifier = Modifier.fillMaxWidth())
        }

        // Group chat label
        Row(Modifier.padding(horizontal = 16.dp, vertical = 6.dp)) {
            Text("Group chat", style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant)
        }

        HorizontalDivider()

        // Message list
        LazyColumn(state = listState, modifier = Modifier.weight(1f).padding(horizontal = 12.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
            contentPadding = PaddingValues(vertical = 8.dp)) {
            items(visible, key = { it.id }) { msg ->
                ChatBubble(
                    msg = msg,
                    mesh = mesh,
                    savedContacts = savedContacts,
                    onTapKnownContact = { senderID, displayName ->
                        onNavigateToPrivateChat(senderID, displayName)
                    },
                    onTapUnknownSender = { publicKey ->
                        pendingContactKey = publicKey
                    }
                )
            }
        }

        HorizontalDivider()

        // Input bar
        Row(
            Modifier.padding(8.dp).navigationBarsPadding(),
            verticalAlignment = Alignment.Bottom
        ) {
            IconButton(onClick = { pickImageLauncher.launch("image/*") }, enabled = !imageBusy) {
                Icon(Icons.Filled.Photo, "Send photo",
                    tint = if (imageBusy) MaterialTheme.colorScheme.onSurfaceVariant else MaterialTheme.colorScheme.primary)
            }
            OutlinedTextField(
                value = draft,
                onValueChange = { draft = it },
                modifier = Modifier.weight(1f),
                placeholder = { Text("Message") },
                maxLines = 4
            )
            Spacer(Modifier.width(4.dp))
            IconButton(
                onClick = {
                    val t = draft.trim()
                    if (t.isNotEmpty()) { mesh.sendChat(t); draft = "" }
                },
                enabled = draft.trim().isNotEmpty()
            ) {
                Icon(Icons.Filled.Send, "Send", tint = MaterialTheme.colorScheme.primary)
            }
        }
    }

    if (showPhotoInfo) {
        AlertDialog(
            onDismissRequest = { showPhotoInfo = false },
            title = { Text("How photos send") },
            text = {
                Text("Photos are sent as many small mesh packets over BLE. Keep both apps in range. Group chat is broadcast. Contacts are direct threads.")
            },
            confirmButton = { TextButton(onClick = { showPhotoInfo = false }) { Text("Done") } }
        )
    }

    // Contact editor sheet — shown when user taps an unknown sender's bubble
    pendingContactKey?.let { pk ->
        com.meshchat.mvp.ui.dashboard.ContactEditorBottomSheet(
            publicKey = pk,
            onDismiss = { pendingContactKey = null },
            onSaved = {
                mesh.bumpContactsVersion()
                pendingContactKey = null
            }
        )
    }
}

@Composable
private fun StatusStrip(isScanning: Boolean, secondsUntilScan: Double, linked: Boolean) {
    Surface(color = MaterialTheme.colorScheme.surfaceVariant) {
        Column(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(
                    if (linked) Icons.Filled.Link else Icons.Filled.SignalCellularAlt,
                    null,
                    tint = if (linked) Color(0xFF4CAF50) else MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.size(16.dp)
                )
                Spacer(Modifier.width(6.dp))
                Text(
                    if (linked) "Linked" else "Finding peers…",
                    style = MaterialTheme.typography.bodySmall,
                    fontWeight = FontWeight.Medium,
                    color = if (linked) Color(0xFF4CAF50) else MaterialTheme.colorScheme.onSurfaceVariant
                )
                Spacer(Modifier.weight(1f))
                if (isScanning) {
                    Surface(shape = CircleShape, color = Color(0xFF4CAF50).copy(alpha = 0.2f)) {
                        Text("Scanning", Modifier.padding(horizontal = 8.dp, vertical = 2.dp),
                            style = MaterialTheme.typography.labelSmall, color = Color(0xFF4CAF50))
                    }
                } else if (secondsUntilScan > 0) {
                    Text("Next scan ${secondsUntilScan.toInt()}s",
                        style = MaterialTheme.typography.labelSmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            }
            Text("Tap a group message sender → private chat or add contact.",
                style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.6f))
        }
    }
}

@Composable
private fun ContactsQuickRow(
    contacts: List<SavedContactEntity>,
    contactActivity: Map<String, com.meshchat.mvp.model.ContactActivityState>,
    onTap: (SavedContactEntity) -> Unit
) {
    val unreadTotal = contactActivity.values.sumOf { it.unread }
    Column(Modifier.padding(vertical = 8.dp)) {
        Row(Modifier.padding(horizontal = 16.dp, vertical = 4.dp),
            verticalAlignment = Alignment.CenterVertically) {
            Icon(Icons.Filled.People, null, Modifier.size(16.dp))
            Spacer(Modifier.width(4.dp))
            Text("Contacts", style = MaterialTheme.typography.labelMedium, fontWeight = FontWeight.SemiBold)
            Spacer(Modifier.weight(1f))
            if (unreadTotal > 0) {
                Surface(shape = CircleShape, color = MaterialTheme.colorScheme.error) {
                    Text("$unreadTotal unread", Modifier.padding(horizontal = 8.dp, vertical = 2.dp),
                        style = MaterialTheme.typography.labelSmall, color = Color.White)
                }
            }
        }
        LazyRow(contentPadding = PaddingValues(horizontal = 12.dp),
            horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            items(contacts) { c ->
                val peerID = DatabaseManager.canonicalSenderID(c.publicKey)
                val act = contactActivity[peerID]
                ContactChip(contact = c, act = act, onClick = { onTap(c) })
            }
        }
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun ContactChip(
    contact: SavedContactEntity,
    act: com.meshchat.mvp.model.ContactActivityState?,
    onClick: () -> Unit
) {
    val unread = act?.unread ?: 0
    Surface(
        modifier = Modifier.width(148.dp).combinedClickable(onClick = onClick),
        shape = RoundedCornerShape(12.dp),
        color = MaterialTheme.colorScheme.surfaceVariant
    ) {
        Column(Modifier.padding(10.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(contact.nickname, style = MaterialTheme.typography.bodySmall,
                    fontWeight = FontWeight.SemiBold, maxLines = 1, modifier = Modifier.weight(1f))
                if (unread > 0) {
                    Surface(shape = CircleShape, color = MaterialTheme.colorScheme.error,
                        modifier = Modifier.size(18.dp)) {
                        Box(contentAlignment = Alignment.Center, modifier = Modifier.fillMaxSize()) {
                            Text(if (unread > 99) "99+" else "$unread",
                                style = MaterialTheme.typography.labelSmall, color = Color.White)
                        }
                    }
                }
            }
            Spacer(Modifier.height(2.dp))
            Text(
                if (act?.lastText?.isNotEmpty() == true) act.lastText else "Open chat",
                style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 2
            )
        }
    }
}

@Composable
private fun ChatBubble(
    msg: ChatMessage,
    mesh: BluetoothMeshService,
    savedContacts: List<SavedContactEntity>,
    onTapKnownContact: (String, String) -> Unit,
    onTapUnknownSender: (ByteArray) -> Unit
) {
    val displayName = mesh.senderDisplayName(msg.senderID, msg.senderName)

    // Decode public key from senderID — same as iOS's KeyManager.decodePublicKeyBase64
    val senderPK = if (!msg.isLocal) KeyManager.decodePublicKeyBase64(msg.senderID) else null

    // Check if sender is a saved contact (match by public key bytes)
    val isSavedContact = remember(senderPK, savedContacts) {
        senderPK != null && savedContacts.any { it.publicKey.contentEquals(senderPK) }
    }

    // Trailing icon mirrors iOS: lock = saved contact (DM), person+badge = add contact
    val trailingIcon = when {
        msg.isLocal -> null
        isSavedContact -> Icons.Filled.Lock         // saved contact → open DM
        senderPK != null -> Icons.Filled.PersonAdd   // unknown → add contact
        else -> null
    }

    Row(Modifier.fillMaxWidth()) {
        if (msg.isLocal) Spacer(Modifier.weight(1f))
        Column(
            modifier = Modifier
                .widthIn(max = 280.dp)
                .then(if (!msg.isLocal && senderPK != null) Modifier.clickable {
                    if (isSavedContact) {
                        onTapKnownContact(msg.senderID, displayName)
                    } else {
                        onTapUnknownSender(senderPK)
                    }
                } else Modifier),
            horizontalAlignment = if (msg.isLocal) Alignment.End else Alignment.Start
        ) {
            // Header row
            Row(horizontalArrangement = Arrangement.spacedBy(4.dp),
                verticalAlignment = Alignment.CenterVertically) {
                if (!msg.isLocal) {
                    Text(displayName, style = MaterialTheme.typography.labelSmall,
                        fontWeight = FontWeight.SemiBold)
                    trailingIcon?.let {
                        Icon(it, null, Modifier.size(12.dp),
                            tint = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                }
                Text(SimpleDateFormat("HH:mm", Locale.getDefault()).format(Date(msg.date)),
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant)
                if (msg.isLocal) Text("You", style = MaterialTheme.typography.labelSmall,
                    fontWeight = FontWeight.SemiBold)
            }
            msg.distanceFromMe?.let { d ->
                if (!msg.isLocal) Text(distanceString(d), style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            // Bubble
            Surface(
                shape = RoundedCornerShape(16.dp),
                color = if (msg.isLocal)
                    MaterialTheme.colorScheme.primaryContainer
                else MaterialTheme.colorScheme.surfaceVariant
            ) {
                if (!msg.imageJPEGBase64.isNullOrEmpty()) {
                    AsyncImage(
                        model = android.util.Base64.decode(msg.imageJPEGBase64, android.util.Base64.DEFAULT),
                        contentDescription = null,
                        modifier = Modifier.sizeIn(maxWidth = 220.dp, maxHeight = 220.dp)
                            .clip(RoundedCornerShape(16.dp))
                    )
                } else {
                    Text(msg.text, Modifier.padding(12.dp), style = MaterialTheme.typography.bodyMedium)
                }
            }
        }
        if (!msg.isLocal) Spacer(Modifier.weight(1f))
    }
}

private fun distanceString(meters: Double) =
    if (meters < 1000) "~${meters.toInt()} m away"
    else "~${"%.1f".format(meters / 1000)} km away"
