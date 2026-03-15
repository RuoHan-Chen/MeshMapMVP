package com.meshchat.mvp.ui.profile

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ContentCopy
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.meshchat.mvp.bluetooth.BluetoothMeshService
import com.meshchat.mvp.crypto.KeyManager

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ProfileScreen(mesh: BluetoothMeshService) {
    val identity by mesh.identityFlow.collectAsState()
    var nicknameEditor by remember { mutableStateOf(identity.nickname) }
    var shareLocation by remember { mutableStateOf(identity.shareLocation) }
    val clipboard = LocalClipboardManager.current

    LaunchedEffect(Unit) {
        nicknameEditor = identity.nickname
        shareLocation = identity.shareLocation
    }

    Column(Modifier.fillMaxSize()) {
        TopAppBar(title = { Text("You") })

        LazyColumn(contentPadding = PaddingValues(vertical = 8.dp)) {
            // ── Identity ──────────────────────────────────────────────────────
            item {
                SectionLabel("Identity")
                OutlinedTextField(
                    value = nicknameEditor,
                    onValueChange = { nicknameEditor = it },
                    label = { Text("Nickname") },
                    modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp)
                )
                Spacer(Modifier.height(8.dp))
                Button(
                    onClick = {
                        val id = identity.copy(nickname = nicknameEditor.trim().takeIf { it.isNotEmpty() } ?: identity.nickname)
                        mesh.updateIdentity(id)
                    },
                    modifier = Modifier.padding(horizontal = 16.dp),
                    enabled = nicknameEditor.trim().isNotEmpty()
                ) { Text("Save nickname") }
                Spacer(Modifier.height(12.dp))

                // Public key fingerprint
                ListItem(
                    headlineContent = { Text("Public key (mesh id)") },
                    supportingContent = {
                        Column {
                            Text(
                                KeyManager.fingerprint(KeyManager.publicKeyData, 12),
                                style = MaterialTheme.typography.bodySmall.copy(fontFamily = FontFamily.Monospace)
                            )
                            Text(identity.deviceID,
                                style = MaterialTheme.typography.labelSmall.copy(fontFamily = FontFamily.Monospace),
                                color = MaterialTheme.colorScheme.onSurfaceVariant)
                        }
                    },
                    trailingContent = {
                        IconButton(onClick = {
                            clipboard.setText(AnnotatedString(identity.deviceID))
                        }) { Icon(Icons.Filled.ContentCopy, "Copy device ID") }
                    }
                )
                HorizontalDivider()
            }

            // ── Privacy ───────────────────────────────────────────────────────
            item {
                SectionLabel("Privacy")
                ListItem(
                    headlineContent = { Text("Share my location with peers") },
                    trailingContent = {
                        Switch(
                            checked = shareLocation,
                            onCheckedChange = { newVal ->
                                shareLocation = newVal
                                val updated = identity.copy(shareLocation = newVal)
                                mesh.updateIdentity(updated)
                            }
                        )
                    }
                )
                Text(
                    "When on, your coordinates are included in messages so others can see approximate distance. You can turn this off anytime.",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(horizontal = 16.dp, vertical = 4.dp)
                )
                HorizontalDivider()
            }

            // ── Tips ──────────────────────────────────────────────────────────
            item {
                SectionLabel("Tips")
                Text(
                    "Open Chat on both phones. Dashboard shows scan windows and auto-connect. Keep apps in foreground for best results.",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(horizontal = 16.dp, vertical = 4.dp)
                )
            }
        }
    }
}

@Composable
private fun SectionLabel(text: String) {
    Text(
        text, modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp),
        style = MaterialTheme.typography.labelSmall,
        color = MaterialTheme.colorScheme.primary,
        fontWeight = FontWeight.Bold
    )
}
