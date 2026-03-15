package com.meshchat.mvp.ui.map

import android.content.Intent
import android.graphics.BitmapFactory
import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.*
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.*
import androidx.compose.foundation.BorderStroke
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.google.android.gms.maps.model.*
import com.google.maps.android.compose.*
import com.meshchat.mvp.bluetooth.BluetoothMeshService
import com.meshchat.mvp.database.DatabaseManager
import com.meshchat.mvp.database.NodeSightingEntity
import com.meshchat.mvp.model.*
import com.meshchat.mvp.ui.chat.MeshImageUtilsAndroid
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.text.SimpleDateFormat
import java.util.*

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun MapScreen(mesh: BluetoothMeshService) {
    val mapLabels     by mesh.mapLabels.collectAsState()
    val labelVotes    by mesh.labelVotes.collectAsState()
    val senderCoords  by mesh.senderCoordinates.collectAsState()
    val myLocation    by mesh.lastKnownLocation.collectAsState()
    val announceNicks by mesh.announceNicknames.collectAsState()
    val thumbnails    by mesh.thumbnails.collectAsState()
    val cooldown      by mesh.mapLabelCooldownRemaining.collectAsState()
    val identity      by mesh.identityFlow.collectAsState()
    val context       = LocalContext.current
    val scope         = rememberCoroutineScope()

    val defaultPos = LatLng(-33.8688, 151.2093)
    val cameraPositionState = rememberCameraPositionState {
        position = CameraPosition.fromLatLngZoom(defaultPos, 14f)
    }

    // Trust data loaded off main thread
    var labelRelationships by remember { mutableStateOf<Map<String, String>>(emptyMap()) }
    var labelSightings     by remember { mutableStateOf<Map<String, NodeSightingEntity>>(emptyMap()) }

    var showAddLabel       by remember { mutableStateOf(false) }
    var showCooldownAlert  by remember { mutableStateOf(false) }
    var showTooFarAlert    by remember { mutableStateOf(false) }
    var showOfflineInfo    by remember { mutableStateOf(false) }
    var showSOSAlert       by remember { mutableStateOf(false) }
    var selectedLabel      by remember { mutableStateOf<MapLabelRecord?>(null) }
    var selectedCluster    by remember { mutableStateOf<LabelCluster?>(null) }

    // Load trust data from DB whenever labels change
    fun loadTrustData() {
        scope.launch(Dispatchers.IO) {
            val contacts = DatabaseManager.listContacts()
            val rels = contacts.associate {
                DatabaseManager.canonicalSenderID(it.publicKey) to it.relationship
            }
            val nodeIDs = buildSet {
                mapLabels.values.forEach { add(it.senderID) }
                labelVotes.values.forEach { addAll(it.keys) }
            }
            val sightings: Map<String, NodeSightingEntity> = nodeIDs.mapNotNull { id ->
                val s = DatabaseManager.recentSightings(id, 1).firstOrNull()
                if (s != null) id to s else null
            }.toMap()
            withContext(Dispatchers.Main) {
                labelRelationships = rels
                labelSightings = sightings
            }
        }
    }

    // Build scored records with AlertTrustEngine
    val labelRecords = remember(mapLabels, labelVotes, myLocation, labelRelationships, labelSightings) {
        buildLabelRecords(mapLabels, labelVotes, myLocation, labelRelationships, labelSightings, identity.deviceID)
    }
    val labelClusters = remember(labelRecords) { clusterLabels(labelRecords) }

    LaunchedEffect(mapLabels.size) {
        loadTrustData()
        val coords = buildAllCoords(senderCoords, myLocation, identity)
        if (coords.isNotEmpty()) {
            val avgLat = coords.map { it.latitude }.average()
            val avgLon = coords.map { it.longitude }.average()
            cameraPositionState.position = CameraPosition.fromLatLngZoom(LatLng(avgLat, avgLon), 14f)
        }
    }

    Box(Modifier.fillMaxSize()) {
        GoogleMap(
            modifier = Modifier.fillMaxSize(),
            cameraPositionState = cameraPositionState,
            uiSettings = MapUiSettings(myLocationButtonEnabled = false, zoomControlsEnabled = true)
        ) {
            // Remote transmitter pins
            for ((senderID, coords) in senderCoords) {
                val name = announceNicks[senderID] ?: senderID.take(8)
                Marker(
                    state = rememberMarkerState(position = LatLng(coords.first, coords.second)),
                    title = name,
                    icon = BitmapDescriptorFactory.defaultMarker(BitmapDescriptorFactory.HUE_ORANGE)
                )
            }
            // My location
            if (identity.shareLocation && myLocation != null) {
                Marker(
                    state = rememberMarkerState(position = LatLng(myLocation!!.first, myLocation!!.second)),
                    title = identity.nickname,
                    icon = BitmapDescriptorFactory.defaultMarker(BitmapDescriptorFactory.HUE_BLUE)
                )
            }
            // Label clusters
            for (cluster in labelClusters) {
                val top = cluster.records.maxByOrNull { it.trustScore }!!
                val label = if (top.voteCount == 0)
                    "${top.displayName} — Unverified"
                else
                    "${top.displayName} (${cluster.records.size}) · score ${"%.1f".format(top.trustScore)}"
                Marker(
                    state = rememberMarkerState(position = LatLng(cluster.latitude, cluster.longitude)),
                    title = label,
                    onClick = {
                        if (cluster.records.size == 1) selectedLabel = cluster.records.first()
                        else selectedCluster = cluster
                        true
                    }
                )
            }
        }

        // Empty state
        if (senderCoords.isEmpty() && labelClusters.isEmpty() &&
            (myLocation == null || !identity.shareLocation)) {
            Column(
                Modifier.align(Alignment.TopCenter).padding(top = 80.dp, start = 24.dp, end = 24.dp),
                horizontalAlignment = Alignment.CenterHorizontally
            ) {
                Surface(shape = RoundedCornerShape(12.dp),
                    color = MaterialTheme.colorScheme.surface.copy(alpha = 0.92f)) {
                    Column(Modifier.padding(16.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                        Text("No positions or labels yet", style = MaterialTheme.typography.titleSmall)
                        Spacer(Modifier.height(4.dp))
                        Text("Turn on \"Share location\" to show your position. Tap + to place an incident label.",
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                }
            }
        }

        // Top controls
        Surface(
            modifier = Modifier.align(Alignment.TopStart).padding(12.dp),
            shape = RoundedCornerShape(10.dp),
            color = MaterialTheme.colorScheme.surface.copy(alpha = 0.92f),
            tonalElevation = 4.dp
        ) {
            Row(
                Modifier.padding(horizontal = 8.dp, vertical = 6.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(4.dp)
            ) {
                // Share location toggle
                FilterChip(
                    selected = identity.shareLocation,
                    onClick = {
                        val updated = identity.copy(shareLocation = !identity.shareLocation)
                        mesh.updateIdentity(updated)
                    },
                    label = { Text("Share location", style = MaterialTheme.typography.labelSmall) },
                    leadingIcon = { Icon(Icons.Filled.LocationOn, null, Modifier.size(14.dp)) }
                )
                // Recenter
                IconButton(onClick = {
                    myLocation?.let { loc ->
                        cameraPositionState.position =
                            CameraPosition.fromLatLngZoom(LatLng(loc.first, loc.second), 15f)
                    }
                }, modifier = Modifier.size(36.dp)) {
                    Icon(Icons.Filled.MyLocation, "Recenter", Modifier.size(20.dp))
                }
                // Add label
                IconButton(onClick = {
                    when {
                        cooldown > 0 -> showCooldownAlert = true
                        !isWithinRange(cameraPositionState.position.target, myLocation) -> showTooFarAlert = true
                        else -> showAddLabel = true
                    }
                }, modifier = Modifier.size(36.dp)) {
                    if (cooldown > 0) Text("${cooldown.toInt()}s", style = MaterialTheme.typography.labelSmall)
                    else Icon(Icons.Filled.AddLocationAlt, "Add label", Modifier.size(20.dp))
                }
                // SOS button
                Surface(
                    shape = RoundedCornerShape(8.dp),
                    color = Color.Red,
                    modifier = Modifier.clickable { showSOSAlert = true }
                ) {
                    Text("SOS", Modifier.padding(horizontal = 10.dp, vertical = 6.dp),
                        style = MaterialTheme.typography.labelMedium,
                        fontWeight = FontWeight.Bold, color = Color.White)
                }
                // Share map
                IconButton(onClick = { shareMap(context, mesh, labelRecords) },
                    modifier = Modifier.size(36.dp)) {
                    Icon(Icons.Filled.Share, "Share map", Modifier.size(20.dp))
                }
                // Offline info
                IconButton(onClick = { showOfflineInfo = true }, Modifier.size(36.dp)) {
                    Icon(Icons.Filled.Map, "Offline maps", Modifier.size(20.dp))
                }
            }
        }
    }

    // ── Dialogs ───────────────────────────────────────────────────────────────

    if (showCooldownAlert) {
        AlertDialog(onDismissRequest = { showCooldownAlert = false },
            title = { Text("Label cooldown") },
            text = { Text("Please wait ${cooldown.toInt()} seconds before placing another label.") },
            confirmButton = { TextButton(onClick = { showCooldownAlert = false }) { Text("OK") } })
    }

    if (showTooFarAlert) {
        AlertDialog(onDismissRequest = { showTooFarAlert = false },
            title = { Text("Too far") },
            text = { Text("Place event labels within 5 km of your location. Enable Share location and move closer.") },
            confirmButton = { TextButton(onClick = { showTooFarAlert = false }) { Text("OK") } })
    }

    if (showSOSAlert) {
        AlertDialog(
            onDismissRequest = { showSOSAlert = false },
            title = { Text("Contact emergency services?") },
            text = { Text("This is a prototype SOS button. It does not call emergency services.") },
            confirmButton = { TextButton(onClick = { showSOSAlert = false }) { Text("OK") } },
            dismissButton = { TextButton(onClick = { showSOSAlert = false }) { Text("Cancel") } }
        )
    }

    if (showOfflineInfo) {
        AlertDialog(onDismissRequest = { showOfflineInfo = false },
            title = { Text("Offline maps") },
            text = { Text("Map tiles cache as you pan. For full offline use, download regions via Google Maps → profile → Offline Maps.") },
            confirmButton = { TextButton(onClick = { showOfflineInfo = false }) { Text("Done") } })
    }

    if (showAddLabel) {
        AddLabelSheet(
            onDismiss = { showAddLabel = false },
            onPlace = { category, customName, customDesc, customIcon, thumbData ->
                val center = cameraPositionState.position.target
                if (thumbData != null) {
                    mesh.sendMapLabelWithThumbnail(category, center.latitude, center.longitude,
                        customName, customDesc, customIcon, thumbData)
                } else {
                    mesh.sendMapLabel(category, center.latitude, center.longitude,
                        customName, customDesc, customIcon)
                }
                showAddLabel = false
            }
        )
    }

    selectedLabel?.let { record ->
        LabelVoteSheet(
            record = record,
            myVote = labelVotes[record.id]?.get(identity.deviceID),
            myDeviceID = identity.deviceID,
            thumbnails = thumbnails,
            onVote = { up -> mesh.voteForLabel(record.id, up) },
            onDelete = { mesh.removeMapLabel(record.id); selectedLabel = null },
            onDismiss = { selectedLabel = null }
        )
    }

    selectedCluster?.let { cluster ->
        ClusterListSheet(
            cluster = cluster,
            onSelectRecord = { record -> selectedCluster = null; selectedLabel = record },
            onDismiss = { selectedCluster = null }
        )
    }
}

// ── Trust-engine helpers ──────────────────────────────────────────────────────

private fun buildLabelRecords(
    mapLabels: Map<UUID, MapLabelPayload>,
    labelVotes: Map<UUID, Map<String, Int>>,
    myLocation: Pair<Double, Double>?,
    relationships: Map<String, String>,
    sightings: Map<String, NodeSightingEntity>,
    myDeviceID: String
): List<MapLabelRecord> {
    val now = System.currentTimeMillis()
    return mapLabels.values.mapNotNull { payload ->
        if (now - payload.timestamp > MapLabelRecord.EVENT_EXPIRATION_MS) return@mapNotNull null
        if (myLocation != null) {
            val dist = BluetoothMeshService.haversineMeters(
                myLocation.first, myLocation.second, payload.lat, payload.lon)
            if (dist > BluetoothMeshService.MAX_EVENT_PLACEMENT_DISTANCE_METERS) return@mapNotNull null
        }
        val votes = labelVotes[payload.id] ?: emptyMap()
        val score = AlertTrustEngine.scoreLabel(
            authorID = payload.senderID, lat = payload.lat, lon = payload.lon,
            timestampMs = payload.timestamp, votes = votes,
            relationships = relationships, sightings = sightings,
            myDeviceID = myDeviceID, nowMs = now
        )
        MapLabelRecord(
            id = payload.id, category = LabelCategory.from(payload.category),
            latitude = payload.lat, longitude = payload.lon,
            senderID = payload.senderID, senderName = payload.senderName,
            date = payload.timestamp, trustScore = score, voteCount = votes.size,
            customLabelName = payload.customLabelName,
            customDescription = payload.customDescription,
            customSystemImage = payload.customSystemImage
        )
    }
}

private fun clusterLabels(records: List<MapLabelRecord>): List<LabelCluster> {
    val clusters = mutableListOf<LabelCluster>()
    for (record in records) {
        var placed = false
        for (cluster in clusters) {
            val dist = BluetoothMeshService.haversineMeters(
                cluster.latitude, cluster.longitude, record.latitude, record.longitude)
            if (dist <= 60.0) {
                cluster.records.add(record)
                cluster.latitude = cluster.records.map { it.latitude }.average()
                cluster.longitude = cluster.records.map { it.longitude }.average()
                placed = true; break
            }
        }
        if (!placed) clusters.add(LabelCluster(record.id, record.latitude, record.longitude, mutableListOf(record)))
    }
    return clusters
}

private fun buildAllCoords(
    senderCoords: Map<String, Pair<Double, Double>>,
    myLocation: Pair<Double, Double>?,
    identity: com.meshchat.mvp.model.DeviceIdentity
): List<LatLng> {
    val list = senderCoords.values.map { LatLng(it.first, it.second) }.toMutableList()
    if (identity.shareLocation && myLocation != null)
        list.add(LatLng(myLocation.first, myLocation.second))
    return list
}

private fun isWithinRange(target: LatLng, myLocation: Pair<Double, Double>?): Boolean {
    myLocation ?: return true
    return BluetoothMeshService.haversineMeters(
        myLocation.first, myLocation.second, target.latitude, target.longitude
    ) <= BluetoothMeshService.MAX_EVENT_PLACEMENT_DISTANCE_METERS
}

/** Trust-score → pin color: green = trusted, red = denied, orange = unverified. */
private fun trustColor(record: MapLabelRecord): Color {
    if (record.voteCount == 0) return Color(0xFFFF9800)  // orange = unverified
    val normalized = (record.trustScore / 10.0).coerceIn(0.0, 1.0)
    val red   = minOf(1.0, (1 - normalized) * 2).toFloat()
    val green = minOf(1.0, normalized * 2).toFloat()
    return Color(red, green, 0.2f)
}

// ── Map HTML export ───────────────────────────────────────────────────────────

private fun shareMap(
    context: android.content.Context,
    mesh: BluetoothMeshService,
    labelRecords: List<MapLabelRecord>
) {
    val identity = mesh.identity
    val senderCoords = mesh.senderCoordinates.value
    val nicknames = mesh.announceNicknames.value
    val thumbs = mesh.thumbnails.value

    val membersJson = buildString {
        append("[")
        val members = senderCoords.entries.mapIndexed { i, (id, coords) ->
            val name = nicknames[id] ?: id.take(8)
            """{"id":"$id","name":"${name.replace("\"", "\\\"")}","latitude":${coords.first},"longitude":${coords.second}}"""
        }.toMutableList()
        if (identity.shareLocation) {
            val loc = mesh.lastKnownLocation.value
            if (loc != null) {
                members += """{"id":"${identity.deviceID}","name":"${identity.nickname.replace("\"", "\\\"")}","latitude":${loc.first},"longitude":${loc.second}}"""
            }
        }
        append(members.joinToString(","))
        append("]")
    }

    val eventsJson = buildString {
        append("[")
        val items = labelRecords.map { r ->
            val thumb = thumbs[r.id]
            val thumbStr = if (thumb != null)
                ",\"thumbnailDataURI\":\"data:image/jpeg;base64,${android.util.Base64.encodeToString(thumb, android.util.Base64.NO_WRAP)}\""
            else ""
            val desc = r.customDescription?.replace("\"", "\\\"") ?: ""
            val name = r.displayName.replace("\"", "\\\"")
            val date = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss'Z'", Locale.US).also { it.timeZone = java.util.TimeZone.getTimeZone("UTC") }.format(Date(r.date))
            val scoreStr = if (r.voteCount == 0) "Unverified" else "${"%.1f".format(r.trustScore)}"
            """{"id":"${r.id}","name":"$name","category":"${r.category.rawValue}","latitude":${r.latitude},"longitude":${r.longitude},"description":"$desc","date":"$date","score":"$scoreStr"$thumbStr}"""
        }
        append(items.joinToString(","))
        append("]")
    }

    val exporterName = identity.nickname.replace("\"", "\\\"")
    val exportDate   = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss'Z'", Locale.US).also { it.timeZone = java.util.TimeZone.getTimeZone("UTC") }.format(Date())

    val html = """<!DOCTYPE html>
<html><head>
  <meta charset="utf-8"/>
  <title>MeshMap Export</title>
  <meta name="viewport" content="width=device-width,initial-scale=1.0"/>
  <link rel="stylesheet" href="https://unpkg.com/leaflet@1.9.4/dist/leaflet.css"/>
  <style>html,body,#map{height:100%;margin:0;padding:0}.popup-img{max-width:220px;display:block;margin-top:4px;border-radius:6px}</style>
</head><body>
  <div id="map"></div>
  <script id="mesh-data" type="application/json">{"exporter":"$exporterName","exportDate":"$exportDate","members":$membersJson,"events":$eventsJson}</script>
  <script src="https://unpkg.com/leaflet@1.9.4/dist/leaflet.js"></script>
  <script>
    (function(){
      var data=JSON.parse(document.getElementById('mesh-data').textContent);
      var map=L.map('map'); var bounds=null;
      function ext(lat,lon){bounds=bounds?bounds.extend([lat,lon]):L.latLngBounds([lat,lon],[lat,lon]);}
      (data.members||[]).forEach(function(m){L.marker([m.latitude,m.longitude]).addTo(map).bindPopup('<strong>'+m.name+'</strong>');ext(m.latitude,m.longitude);});
      (data.events||[]).forEach(function(e){
        var h='<strong>'+(e.name||e.category)+'</strong><br/><em>'+e.category+'</em>';
        if(e.description)h+='<br/>'+e.description;
        if(e.score)h+='<br/>Trust: '+e.score;
        if(e.thumbnailDataURI)h+='<br/><img class="popup-img" src="'+e.thumbnailDataURI+'"/>';
        if(e.date)h+='<br/><small>'+e.date+'</small>';
        L.marker([e.latitude,e.longitude]).addTo(map).bindPopup(h);ext(e.latitude,e.longitude);
      });
      if(bounds)map.fitBounds(bounds.pad(0.2));else map.setView([0,0],2);
      L.tileLayer('https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png',{maxZoom:19,attribution:'&copy; OpenStreetMap contributors'}).addTo(map);
    })();
  </script>
</body></html>"""

    val fileName = "meshmap-export-${System.currentTimeMillis()}.html"
    val temp = java.io.File(context.cacheDir, fileName)
    temp.writeText(html)
    val uri = androidx.core.content.FileProvider.getUriForFile(context, "${context.packageName}.fileprovider", temp)
    val intent = Intent(Intent.ACTION_SEND).apply {
        type = "text/html"
        putExtra(Intent.EXTRA_STREAM, uri)
        addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
    }
    context.startActivity(Intent.createChooser(intent, "Share map"))
}

// ── Add Label Sheet ───────────────────────────────────────────────────────────

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun AddLabelSheet(
    onDismiss: () -> Unit,
    onPlace: (LabelCategory, String?, String?, String?, ByteArray?) -> Unit
) {
    val context = LocalContext.current
    var selectedCategory by remember { mutableStateOf<LabelCategory?>(null) }
    var customName by remember { mutableStateOf("") }
    var customDesc by remember { mutableStateOf("") }
    var selectedIcon by remember { mutableStateOf<String?>(null) }
    var thumbnailData by remember { mutableStateOf<ByteArray?>(null) }

    val pickImageLauncher = rememberLauncherForActivityResult(ActivityResultContracts.GetContent()) { uri: Uri? ->
        uri ?: return@rememberLauncherForActivityResult
        val stream = context.contentResolver.openInputStream(uri) ?: return@rememberLauncherForActivityResult
        val raw = stream.readBytes(); stream.close()
        thumbnailData = MeshImageUtilsAndroid.prepareThumbnailData(raw)
    }

    ModalBottomSheet(onDismissRequest = onDismiss) {
        LazyColumn(contentPadding = PaddingValues(bottom = 32.dp)) {
            item {
                Text("Add label", style = MaterialTheme.typography.titleMedium,
                    modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp))
                Text("Place a label at the map center. Others can vote on validity.",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(horizontal = 16.dp, vertical = 4.dp))
                Spacer(Modifier.height(8.dp))
                Text("Event type", style = MaterialTheme.typography.labelMedium,
                    modifier = Modifier.padding(horizontal = 16.dp))
            }
            items(LabelCategory.configurableEventTypes) { cat ->
                ListItem(
                    headlineContent = { Text(cat.displayName) },
                    leadingContent = { Icon(categoryIcon(cat), null) },
                    trailingContent = {
                        if (selectedCategory == cat) Icon(Icons.Filled.CheckCircle, null,
                            tint = MaterialTheme.colorScheme.primary)
                    },
                    modifier = Modifier.clickable { selectedCategory = cat }
                )
            }
            if (selectedCategory != null) {
                item {
                    HorizontalDivider(Modifier.padding(vertical = 8.dp))

                    // Icon picker — values are iOS SF Symbol names so they round-trip cross-platform.
                    // Android renders them as equivalent Material icons via sfSymbolToMaterialIcon().
                    Text("Icon (optional)", style = MaterialTheme.typography.labelMedium,
                        modifier = Modifier.padding(horizontal = 16.dp))
                    Spacer(Modifier.height(4.dp))
                    LazyRow(
                        contentPadding = PaddingValues(horizontal = 16.dp),
                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                        modifier = Modifier.padding(bottom = 8.dp)
                    ) {
                        items(SF_SYMBOL_ICON_OPTIONS) { sfName ->
                            val isSelected = selectedIcon == sfName
                            Surface(
                                shape = RoundedCornerShape(8.dp),
                                border = BorderStroke(
                                    if (isSelected) 2.dp else 1.dp,
                                    if (isSelected) MaterialTheme.colorScheme.primary
                                    else MaterialTheme.colorScheme.outline.copy(alpha = 0.4f)
                                ),
                                color = if (isSelected)
                                    MaterialTheme.colorScheme.primaryContainer
                                else MaterialTheme.colorScheme.surface,
                                modifier = Modifier
                                    .size(48.dp)
                                    .clickable { selectedIcon = if (isSelected) null else sfName }
                            ) {
                                Box(contentAlignment = Alignment.Center, modifier = Modifier.fillMaxSize()) {
                                    Icon(sfSymbolToMaterialIcon(sfName), sfName,
                                        Modifier.size(24.dp),
                                        tint = if (isSelected) MaterialTheme.colorScheme.primary
                                        else MaterialTheme.colorScheme.onSurface)
                                }
                            }
                        }
                    }

                    OutlinedTextField(value = customName, onValueChange = { customName = it },
                        label = { Text("Label name (optional)") },
                        modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp))
                    Spacer(Modifier.height(8.dp))
                    OutlinedTextField(value = customDesc, onValueChange = { customDesc = it },
                        label = { Text("Description (optional)") },
                        modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp),
                        minLines = 2, maxLines = 4)
                    Spacer(Modifier.height(8.dp))
                    Row(Modifier.padding(horizontal = 16.dp)) {
                        OutlinedButton(onClick = { pickImageLauncher.launch("image/*") }) {
                            Icon(Icons.Filled.Photo, null, Modifier.size(16.dp))
                            Spacer(Modifier.width(4.dp))
                            Text(if (thumbnailData == null) "Add photo" else "Change photo")
                        }
                    }
                    thumbnailData?.let { data ->
                        val bmp = remember(data) { BitmapFactory.decodeByteArray(data, 0, data.size) }
                        bmp?.let {
                            Spacer(Modifier.height(8.dp))
                            Image(it.asImageBitmap(), null,
                                Modifier.padding(horizontal = 16.dp).height(100.dp).clip(RoundedCornerShape(8.dp)))
                        }
                    }
                    Spacer(Modifier.height(16.dp))
                    Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp),
                        horizontalArrangement = Arrangement.spacedBy(8.dp, Alignment.End)) {
                        TextButton(onClick = onDismiss) { Text("Cancel") }
                        Button(onClick = {
                            val cat = selectedCategory ?: return@Button
                            onPlace(cat, customName.takeIf { it.isNotBlank() },
                                customDesc.takeIf { it.isNotBlank() }, selectedIcon, thumbnailData)
                        }, enabled = selectedCategory != null) { Text("Place") }
                    }
                    Spacer(Modifier.height(16.dp))
                }
            } else {
                item {
                    Row(Modifier.fillMaxWidth().padding(16.dp), horizontalArrangement = Arrangement.End) {
                        TextButton(onClick = onDismiss) { Text("Cancel") }
                    }
                }
            }
        }
    }
}

// ── Label Vote Sheet ──────────────────────────────────────────────────────────

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun LabelVoteSheet(
    record: MapLabelRecord,
    myVote: Int?,
    myDeviceID: String,
    thumbnails: Map<UUID, ByteArray>,
    onVote: (Boolean) -> Unit,
    onDelete: () -> Unit,
    onDismiss: () -> Unit
) {
    var confirmDelete by remember { mutableStateOf(false) }
    ModalBottomSheet(onDismissRequest = onDismiss) {
        Column(Modifier.padding(horizontal = 16.dp, vertical = 8.dp).navigationBarsPadding()) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(categoryIcon(record.category), null, tint = MaterialTheme.colorScheme.primary)
                Spacer(Modifier.width(8.dp))
                Text(record.displayName, style = MaterialTheme.typography.titleMedium, modifier = Modifier.weight(1f))
                IconButton(onClick = { confirmDelete = true }) {
                    Icon(Icons.Filled.Delete, "Delete", tint = MaterialTheme.colorScheme.error)
                }
            }
            thumbnails[record.id]?.let { data ->
                val bmp = remember(data) { BitmapFactory.decodeByteArray(data, 0, data.size) }
                bmp?.let {
                    Spacer(Modifier.height(8.dp))
                    Image(it.asImageBitmap(), null,
                        Modifier.fillMaxWidth().height(160.dp).clip(RoundedCornerShape(8.dp)))
                }
            }
            record.customDescription?.takeIf { it.isNotBlank() }?.let {
                Spacer(Modifier.height(8.dp))
                Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            Spacer(Modifier.height(4.dp))
            Text("By ${record.senderName}", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            Spacer(Modifier.height(12.dp))
            HorizontalDivider()
            Spacer(Modifier.height(8.dp))
            Text("Trust Score", style = MaterialTheme.typography.labelMedium)
            Spacer(Modifier.height(4.dp))
            Row {
                Text("Score: ", style = MaterialTheme.typography.bodySmall)
                if (record.voteCount == 0) {
                    Text("Unverified", style = MaterialTheme.typography.bodySmall,
                        fontWeight = FontWeight.Medium, color = Color(0xFFFF9800))
                } else {
                    Text("${"%.1f".format(record.trustScore)} (${record.voteCount} votes)",
                        style = MaterialTheme.typography.bodySmall, fontWeight = FontWeight.Medium)
                }
            }
            Spacer(Modifier.height(12.dp))
            Text("Your vote", style = MaterialTheme.typography.labelMedium)
            Spacer(Modifier.height(8.dp))
            if (record.senderID == myDeviceID) {
                Text("You can't vote on your own post.", style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant)
            } else {
                Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    OutlinedButton(onClick = { onVote(true) },
                        colors = ButtonDefaults.outlinedButtonColors(
                            containerColor = if (myVote == 1) Color(0xFF4CAF50).copy(alpha = 0.15f) else Color.Transparent)) {
                        Icon(Icons.Filled.ThumbUp, null, Modifier.size(16.dp),
                            tint = if (myVote == 1) Color(0xFF4CAF50) else MaterialTheme.colorScheme.onSurface)
                        Spacer(Modifier.width(4.dp)); Text("Valid")
                    }
                    OutlinedButton(onClick = { onVote(false) },
                        colors = ButtonDefaults.outlinedButtonColors(
                            containerColor = if (myVote == -1) MaterialTheme.colorScheme.error.copy(alpha = 0.15f) else Color.Transparent)) {
                        Icon(Icons.Filled.ThumbDown, null, Modifier.size(16.dp),
                            tint = if (myVote == -1) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurface)
                        Spacer(Modifier.width(4.dp)); Text("Not valid")
                    }
                }
            }
            Spacer(Modifier.height(8.dp))
            TextButton(onClick = onDismiss, Modifier.align(Alignment.End)) { Text("Done") }
        }
    }
    if (confirmDelete) {
        AlertDialog(onDismissRequest = { confirmDelete = false },
            title = { Text("Delete label?") },
            text = { Text("Removes it from your device only.") },
            confirmButton = { TextButton(onClick = { confirmDelete = false; onDelete() }) {
                Text("Delete", color = MaterialTheme.colorScheme.error) } },
            dismissButton = { TextButton(onClick = { confirmDelete = false }) { Text("Cancel") } })
    }
}

// ── Cluster List Sheet ────────────────────────────────────────────────────────

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun ClusterListSheet(
    cluster: LabelCluster,
    onSelectRecord: (MapLabelRecord) -> Unit,
    onDismiss: () -> Unit
) {
    val sorted = cluster.records.sortedByDescending { it.trustScore }
    ModalBottomSheet(onDismissRequest = onDismiss) {
        Column(Modifier.padding(horizontal = 16.dp)) {
            Text("Nearby events", style = MaterialTheme.typography.titleMedium)
            Spacer(Modifier.height(8.dp))
        }
        LazyColumn(contentPadding = PaddingValues(bottom = 32.dp)) {
            items(sorted) { record ->
                ListItem(
                    headlineContent = { Text(record.displayName) },
                    supportingContent = {
                        Column {
                            record.customDescription?.takeIf { it.isNotBlank() }?.let { Text(it) }
                            val scoreStr = if (record.voteCount == 0) "Unverified"
                            else "score ${"%.1f".format(record.trustScore)}"
                            Text("${relativeTime(record.date)} · $scoreStr",
                                style = MaterialTheme.typography.labelSmall)
                        }
                    },
                    leadingContent = { Icon(categoryIcon(record.category), null, tint = trustColor(record)) },
                    modifier = Modifier.clickable { onSelectRecord(record) }
                )
            }
        }
    }
}

// ── Icon & time helpers ───────────────────────────────────────────────────────

internal fun categoryIcon(cat: LabelCategory) = when (cat) {
    LabelCategory.HAZARD -> Icons.Filled.Warning
    LabelCategory.HELP -> Icons.Filled.PanTool
    LabelCategory.OTHER -> Icons.Filled.HelpOutline
    LabelCategory.ARMED_CONFLICT -> Icons.Filled.FlashOn
    LabelCategory.EXPLOSION -> Icons.Filled.LocalFireDepartment
    LabelCategory.DRONE -> Icons.Filled.Flight
    LabelCategory.MILITARY_MOVEMENT -> Icons.Filled.DirectionsWalk
    LabelCategory.POLICE_CRACKDOWN -> Icons.Filled.Shield
    LabelCategory.ARRESTS -> Icons.Filled.BackHand
    LabelCategory.CHECKPOINT -> Icons.Filled.MergeType
}

/** Resolves the best icon for a label — uses custom SF Symbol if set, else falls back to category default. */
internal fun labelIcon(record: MapLabelRecord) =
    record.customSystemImage?.let { sfSymbolToMaterialIcon(it) } ?: categoryIcon(record.category)

private fun relativeTime(dateMs: Long): String {
    val s = (System.currentTimeMillis() - dateMs) / 1000
    return when {
        s < 60    -> "now"
        s < 3600  -> "${s / 60}m ago"
        s < 86400 -> "${s / 3600}h ago"
        else      -> "${s / 86400}d ago"
    }
}

/**
 * iOS SF Symbol name strings for the icon picker.
 * These exact strings are stored in [MapLabelPayload.customSystemImage] and sent over the wire,
 * so they must match iOS's AddLabelSheet icon list for cross-platform round-tripping.
 */
private val SF_SYMBOL_ICON_OPTIONS = listOf(
    "exclamationmark.triangle.fill",  // Hazard / warning
    "flame.fill",                      // Fire / explosion
    "car.fill",                        // Vehicle
    "bandage.fill",                    // Medical / injury
    "cross.case.fill",                 // Medical kit
    "phone.fill",                      // Phone / call
    "questionmark.circle.fill",        // Unknown / other
    "figure.wave"                      // Person waving / help
)

/**
 * Maps iOS SF Symbol names → closest Material icon.
 * This is display-only on Android — the stored value is always the SF Symbol string.
 */
internal fun sfSymbolToMaterialIcon(sfName: String): androidx.compose.ui.graphics.vector.ImageVector = when (sfName) {
    "exclamationmark.triangle.fill" -> Icons.Filled.Warning
    "flame.fill"                    -> Icons.Filled.LocalFireDepartment
    "car.fill"                      -> Icons.Filled.DirectionsCar
    "bandage.fill"                  -> Icons.Filled.MedicalServices
    "cross.case.fill"               -> Icons.Filled.MedicalServices
    "phone.fill"                    -> Icons.Filled.Phone
    "questionmark.circle.fill"      -> Icons.Filled.HelpOutline
    "figure.wave"                   -> Icons.Filled.DirectionsWalk
    // Category defaults (for labels that arrived from iOS with their default systemImage)
    "hand.raised.fill"              -> Icons.Filled.PanTool
    "bolt.fill"                     -> Icons.Filled.FlashOn
    "airplane"                      -> Icons.Filled.Flight
    "figure.march"                  -> Icons.Filled.DirectionsWalk
    "shield.fill"                   -> Icons.Filled.Shield
    "road.lanes"                    -> Icons.Filled.MergeType
    else                            -> Icons.Filled.Place
}
