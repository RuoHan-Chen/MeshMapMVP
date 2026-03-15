package com.meshchat.mvp.ui.chat

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Send
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.meshchat.mvp.bluetooth.BluetoothMeshService
import com.meshchat.mvp.model.ChatMessage
import java.text.SimpleDateFormat
import java.util.*

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun PrivateChatScreen(
    mesh: BluetoothMeshService,
    peerID: String,
    displayName: String,
    onBack: () -> Unit
) {
    val threadMap by mesh.directThreadMessages.collectAsState()
    val thread = threadMap[peerID] ?: emptyList()
    var draft by remember { mutableStateOf("") }
    var sendCooldown by remember { mutableStateOf(false) }
    val listState = rememberLazyListState()

    LaunchedEffect(Unit) {
        mesh.loadDirectThread(peerID)
        mesh.markContactThreadRead(peerID)
    }

    LaunchedEffect(thread.size) {
        if (thread.isNotEmpty()) listState.animateScrollToItem(thread.size - 1)
    }

    Column(Modifier.fillMaxSize()) {
        TopAppBar(
            title = { Text(displayName) },
            navigationIcon = {
                IconButton(onClick = onBack) {
                    Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back")
                }
            }
        )

        LazyColumn(
            state = listState,
            modifier = Modifier.weight(1f).padding(horizontal = 12.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
            contentPadding = PaddingValues(vertical = 8.dp)
        ) {
            if (thread.isEmpty()) {
                item {
                    Text(
                        "No messages yet. DMs expire after 20 minutes on this device and on the mesh.",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.padding(8.dp)
                    )
                }
            }
            items(thread, key = { it.id }) { msg ->
                DmBubble(msg = msg, mesh = mesh)
            }
        }

        HorizontalDivider()

        Row(
            Modifier.padding(8.dp).navigationBarsPadding(),
            verticalAlignment = Alignment.Bottom
        ) {
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
                    if (t.isNotEmpty() && !sendCooldown) {
                        sendCooldown = true
                        mesh.sendDirectChat(t, peerID, displayName)
                        draft = ""
                        sendCooldown = false
                    }
                },
                enabled = draft.trim().isNotEmpty() && !sendCooldown
            ) {
                Icon(Icons.Filled.Send, "Send", tint = MaterialTheme.colorScheme.primary)
            }
        }
    }
}

@Composable
private fun DmBubble(msg: ChatMessage, mesh: BluetoothMeshService) {
    val displayName = mesh.senderDisplayName(msg.senderID, msg.senderName)
    Row(Modifier.fillMaxWidth()) {
        if (msg.isLocal) Spacer(Modifier.weight(1f))
        Column(
            modifier = Modifier.widthIn(max = 280.dp),
            horizontalAlignment = if (msg.isLocal) Alignment.End else Alignment.Start
        ) {
            Row(horizontalArrangement = Arrangement.spacedBy(4.dp),
                verticalAlignment = Alignment.CenterVertically) {
                if (!msg.isLocal) Text(displayName, style = MaterialTheme.typography.labelSmall,
                    fontWeight = FontWeight.SemiBold)
                Text(
                    SimpleDateFormat("HH:mm", Locale.getDefault()).format(Date(msg.date)),
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
                if (msg.isLocal) Text("You", style = MaterialTheme.typography.labelSmall,
                    fontWeight = FontWeight.SemiBold)
            }
            Surface(
                shape = RoundedCornerShape(16.dp),
                color = if (msg.isLocal) MaterialTheme.colorScheme.primaryContainer
                else MaterialTheme.colorScheme.surfaceVariant
            ) {
                Text(msg.text, Modifier.padding(12.dp), style = MaterialTheme.typography.bodyMedium)
            }
        }
        if (!msg.isLocal) Spacer(Modifier.weight(1f))
    }
}
