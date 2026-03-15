package com.meshchat.mvp.ui.alerts

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
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.meshchat.mvp.bluetooth.BluetoothMeshService
import com.meshchat.mvp.database.DatabaseManager
import com.meshchat.mvp.database.NodeSightingEntity
import com.meshchat.mvp.model.*
import com.meshchat.mvp.ui.map.categoryIcon
import com.meshchat.mvp.ui.map.sfSymbolToMaterialIcon
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.util.UUID

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun AlertFeedScreen(mesh: BluetoothMeshService) {
    val mapLabels  by mesh.mapLabels.collectAsState()
    val labelVotes by mesh.labelVotes.collectAsState()
    val identity   by mesh.identityFlow.collectAsState()
    val scope      = rememberCoroutineScope()

    var clusters by remember { mutableStateOf<List<LabelEventCluster>>(emptyList()) }
    var myVotes  by remember { mutableStateOf<Map<UUID, Int>>(emptyMap()) }

    fun reload() {
        scope.launch(Dispatchers.IO) {
            val contacts = DatabaseManager.listContacts()
            val relationships = contacts.associate {
                DatabaseManager.canonicalSenderID(it.publicKey) to it.relationship
            }
            val nodeIDs = buildSet {
                mapLabels.values.forEach { add(it.senderID) }
                labelVotes.values.forEach { addAll(it.keys) }
            }
            val sightings: Map<String, NodeSightingEntity> = nodeIDs.mapNotNull { id ->
                DatabaseManager.recentSightings(id, 1).firstOrNull()?.let { s -> id to s }
            }.toMap()

            val now = System.currentTimeMillis()
            val scored = mapLabels.values.mapNotNull { payload ->
                if (now - payload.timestamp > MapLabelRecord.EVENT_EXPIRATION_MS) return@mapNotNull null
                val votes = labelVotes[payload.id] ?: emptyMap()
                val score = AlertTrustEngine.scoreLabel(
                    authorID = payload.senderID, lat = payload.lat, lon = payload.lon,
                    timestampMs = payload.timestamp, votes = votes,
                    relationships = relationships, sightings = sightings,
                    myDeviceID = identity.deviceID, nowMs = now
                )
                ScoredLabel(payload = payload, score = score, voteCount = votes.size)
            }

            val newClusters = AlertTrustEngine.clusterLabels(scored)
            val newMyVotes = buildMap {
                for ((id, voteMap) in labelVotes) {
                    if (mapLabels.containsKey(id)) {
                        voteMap[identity.deviceID]?.let { put(id, it) }
                    }
                }
            }
            withContext(Dispatchers.Main) {
                clusters = newClusters
                myVotes  = newMyVotes
            }
        }
    }

    LaunchedEffect(mapLabels.size, labelVotes.size) { reload() }
    LaunchedEffect(Unit) {
        while (isActive) { delay(60_000); reload() }
    }

    Column(Modifier.fillMaxSize()) {
        TopAppBar(title = { Text("Alerts") })

        if (clusters.isEmpty()) {
            Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                Column(horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Icon(Icons.Filled.NotificationsNone, null, Modifier.size(48.dp),
                        tint = MaterialTheme.colorScheme.onSurfaceVariant)
                    Text("No Active Alerts", style = MaterialTheme.typography.titleMedium)
                    Text("Alerts from the mesh will appear here.",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            }
        } else {
            LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(vertical = 8.dp)) {
                items(clusters, key = { it.id.toString() }) { cluster ->
                    LabelEventClusterRow(
                        cluster    = cluster,
                        myVotes    = myVotes,
                        myDeviceID = identity.deviceID,
                        onVote     = { labelID, confirms ->
                            mesh.voteForLabel(labelID, confirms)
                            reload()
                        }
                    )
                    HorizontalDivider()
                }
            }
        }
    }
}

// ── Cluster row ───────────────────────────────────────────────────────────────

@Composable
private fun LabelEventClusterRow(
    cluster:    LabelEventCluster,
    myVotes:    Map<UUID, Int>,
    myDeviceID: String,
    onVote:     (UUID, Boolean) -> Unit
) {
    val lead         = cluster.leadScoredLabel
    val payload      = lead.payload
    val myVote       = myVotes[payload.id]
    val isOwn        = payload.senderID == myDeviceID
    val isUnverified = lead.voteCount == 0
    val category     = LabelCategory.from(payload.category)
    val displayName  = payload.customLabelName?.takeIf { it.isNotBlank() } ?: category.displayName

    val pinColor = when (category) {
        LabelCategory.HAZARD, LabelCategory.ARMED_CONFLICT,
        LabelCategory.EXPLOSION, LabelCategory.DRONE -> MaterialTheme.colorScheme.error
        LabelCategory.HELP -> Color(0xFF4CAF50)
        else -> Color(0xFFFF9800)
    }

    val ageSeconds = (System.currentTimeMillis() - payload.timestamp) / 1000
    val timeAgo = when {
        ageSeconds < 60    -> "just now"
        ageSeconds < 3600  -> "${ageSeconds / 60}m ago"
        else               -> "${ageSeconds / 3600}h ago"
    }

    Column(Modifier.padding(horizontal = 16.dp, vertical = 10.dp)) {
        Row(verticalAlignment = Alignment.Top) {
            Icon(
                payload.customSystemImage?.let { sfSymbolToMaterialIcon(it) } ?: categoryIcon(category),
                null, tint = pinColor
            )
            Spacer(Modifier.width(8.dp))
            Text(displayName, style = MaterialTheme.typography.bodyLarge,
                modifier = Modifier.weight(1f), maxLines = 2)
            Spacer(Modifier.width(8.dp))
            if (isUnverified) {
                Text("Unverified", style = MaterialTheme.typography.labelSmall,
                    fontWeight = FontWeight.Bold, color = Color(0xFFFF9800))
            } else {
                Text("${"%.1f".format(cluster.clusterScore)}",
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }

        payload.customDescription?.takeIf { it.isNotBlank() }?.let { desc ->
            Spacer(Modifier.height(4.dp))
            Text(desc, style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 2)
        }

        Spacer(Modifier.height(4.dp))
        Row(verticalAlignment = Alignment.CenterVertically) {
            if (cluster.labels.size > 1) {
                Text("${cluster.labels.size} reports",
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant)
                Spacer(Modifier.width(8.dp))
            }
            Spacer(Modifier.weight(1f))
            Text(timeAgo, style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant)
        }

        Spacer(Modifier.height(8.dp))
        if (isOwn) {
            Text("Your post", style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.6f))
        } else {
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                OutlinedButton(
                    onClick = { onVote(payload.id, true) },
                    enabled = myVote == null,
                    modifier = Modifier.height(32.dp),
                    colors = ButtonDefaults.outlinedButtonColors(
                        containerColor = if (myVote == 1) Color(0xFF4CAF50).copy(0.15f) else Color.Transparent),
                    contentPadding = PaddingValues(horizontal = 12.dp, vertical = 4.dp)
                ) {
                    Icon(Icons.Filled.ThumbUp, null, Modifier.size(14.dp),
                        tint = if (myVote == 1) Color(0xFF4CAF50) else MaterialTheme.colorScheme.onSurface)
                    Spacer(Modifier.width(4.dp))
                    Text("Confirm", style = MaterialTheme.typography.labelSmall)
                }
                OutlinedButton(
                    onClick = { onVote(payload.id, false) },
                    enabled = myVote == null,
                    modifier = Modifier.height(32.dp),
                    colors = ButtonDefaults.outlinedButtonColors(
                        containerColor = if (myVote == -1) MaterialTheme.colorScheme.error.copy(0.15f) else Color.Transparent),
                    contentPadding = PaddingValues(horizontal = 12.dp, vertical = 4.dp)
                ) {
                    Icon(Icons.Filled.ThumbDown, null, Modifier.size(14.dp),
                        tint = if (myVote == -1) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurface)
                    Spacer(Modifier.width(4.dp))
                    Text("Deny", style = MaterialTheme.typography.labelSmall)
                }
            }
        }
    }
}
