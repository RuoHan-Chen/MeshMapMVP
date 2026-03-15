package com.meshchat.mvp.ui.contacts

import androidx.compose.foundation.*
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.meshchat.mvp.bluetooth.BluetoothMeshService
import com.meshchat.mvp.crypto.KeyManager
import com.meshchat.mvp.database.DatabaseManager
import com.meshchat.mvp.database.SavedContactEntity
import com.meshchat.mvp.model.ContactActivityState
import com.meshchat.mvp.ui.dashboard.ContactEditorBottomSheet
import kotlinx.coroutines.launch

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ContactsScreen(
    mesh: BluetoothMeshService,
    onNavigateToPrivateChat: (String, String) -> Unit
) {
    val contactsVersion by mesh.contactsVersion.collectAsState()
    val contactActivity by mesh.contactActivity.collectAsState()
    val activityRevision by mesh.contactActivityRevision.collectAsState()
    val scope = rememberCoroutineScope()

    var contacts by remember { mutableStateOf<List<SavedContactEntity>>(emptyList()) }
    var editingContact by remember { mutableStateOf<SavedContactEntity?>(null) }

    LaunchedEffect(contactsVersion, activityRevision) {
        contacts = DatabaseManager.listContacts()
    }

    val sorted = contacts.sortedWith(compareByDescending<SavedContactEntity> {
        val pid = DatabaseManager.canonicalSenderID(it.publicKey)
        contactActivity[pid]?.lastDate ?: 0L
    }.thenBy { it.nickname.lowercase() })

    Column(Modifier.fillMaxSize()) {
        TopAppBar(title = { Text("Contacts") })

        if (contacts.isEmpty()) {
            Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Icon(Icons.Filled.PersonAdd, null, Modifier.size(48.dp),
                        tint = MaterialTheme.colorScheme.onSurfaceVariant)
                    Text("No contacts yet", style = MaterialTheme.typography.titleMedium)
                    Text(
                        "Dashboard or group chat → add contact, then open private chat here.",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.padding(horizontal = 32.dp)
                    )
                }
            }
        } else {
            LazyColumn(Modifier.fillMaxSize()) {
                items(sorted, key = { it.id }) { c ->
                    val peerID = DatabaseManager.canonicalSenderID(c.publicKey)
                    val act = contactActivity[peerID]
                    ContactRow(
                        contact = c,
                        act = act,
                        onClick = { onNavigateToPrivateChat(peerID, c.nickname) },
                        onEdit = { editingContact = c }
                    )
                    HorizontalDivider()
                }
            }
        }
    }

    editingContact?.let { c ->
        val peerID = DatabaseManager.canonicalSenderID(c.publicKey)
        ContactEditorBottomSheet(
            publicKey = c.publicKey,
            onDismiss = { editingContact = null },
            onSaved = {
                mesh.bumpContactsVersion()
                scope.launch { contacts = DatabaseManager.listContacts() }
                editingContact = null
            }
        )
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun ContactRow(
    contact: SavedContactEntity,
    act: ContactActivityState?,
    onClick: () -> Unit,
    onEdit: () -> Unit
) {
    val unread = act?.unread ?: 0
    val fingerprint = KeyManager.fingerprint(contact.publicKey, 8)

    ListItem(
        headlineContent = {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(contact.nickname, fontWeight = FontWeight.SemiBold)
                if (unread > 0) {
                    Spacer(Modifier.width(8.dp))
                    Surface(shape = CircleShape, color = MaterialTheme.colorScheme.error) {
                        Text(
                            if (unread > 99) "99+" else "$unread",
                            Modifier.padding(horizontal = 6.dp, vertical = 2.dp),
                            style = MaterialTheme.typography.labelSmall, color = Color.White
                        )
                    }
                }
            }
        },
        supportingContent = {
            Column {
                Text(
                    if (act?.lastText?.isNotEmpty() == true) act.lastText else "No messages yet",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 2
                )
                Text("$fingerprint · ${contact.relationship}",
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.6f))
            }
        },
        trailingContent = {
            Icon(Icons.Filled.ChevronRight, null,
                tint = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.4f))
        },
        modifier = Modifier
            .combinedClickable(onClick = onClick, onLongClick = onEdit)
    )
}
