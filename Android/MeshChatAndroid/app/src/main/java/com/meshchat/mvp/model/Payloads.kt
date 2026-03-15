package com.meshchat.mvp.model

import org.json.JSONObject
import java.util.UUID

// ── Message types ─────────────────────────────────────────────────────────────

enum class MessageType(val value: Int) {
    ANNOUNCE(1),
    MESSAGE(2),
    MAP_LABEL(3),
    MAP_LABEL_VOTE(4),
    REQUEST_MAP_LABELS(5),
    IMAGE_CHUNK(6),
    ALERT(7),
    VOUCH(8),
    MAP_LABEL_IMAGE_CHUNK(9);

    companion object {
        fun from(value: Int) = entries.firstOrNull { it.value == value }
    }
}

// ── Mesh envelope ─────────────────────────────────────────────────────────────

data class MeshEnvelope(
    val id: UUID,
    val type: MessageType,
    val senderID: String,
    val senderName: String,
    val timestamp: Long,
    var ttl: Int,
    val payload: ByteArray,
    val senderLatitude: Double?,
    val senderLongitude: Double?
) {
    companion object {
        fun encodeJSON(env: MeshEnvelope): ByteArray? = runCatching {
            JSONObject().apply {
                put("id", env.id.toString())
                put("type", env.type.value)
                put("senderID", env.senderID)
                put("senderName", env.senderName)
                put("timestamp", env.timestamp)
                put("ttl", env.ttl)
                put("payload", android.util.Base64.encodeToString(env.payload, android.util.Base64.NO_WRAP))
                env.senderLatitude?.let { put("senderLatitude", it) }
                env.senderLongitude?.let { put("senderLongitude", it) }
            }.toString().toByteArray()
        }.getOrNull()

        fun decodeJSON(data: ByteArray): MeshEnvelope? = runCatching {
            val j = JSONObject(String(data))
            val msgType = MessageType.from(j.getInt("type")) ?: return@runCatching null
            MeshEnvelope(
                id = UUID.fromString(j.getString("id")),
                type = msgType,
                senderID = j.getString("senderID"),
                senderName = j.getString("senderName"),
                timestamp = j.getLong("timestamp"),
                ttl = j.getInt("ttl"),
                payload = android.util.Base64.decode(j.getString("payload"), android.util.Base64.NO_WRAP),
                senderLatitude = if (j.has("senderLatitude")) j.getDouble("senderLatitude") else null,
                senderLongitude = if (j.has("senderLongitude")) j.getDouble("senderLongitude") else null
            )
        }.getOrNull()
    }

    override fun equals(other: Any?) = other is MeshEnvelope && id == other.id
    override fun hashCode() = id.hashCode()
}

// ── Announcement payload ──────────────────────────────────────────────────────

data class AnnouncementPayload(
    val nickname: String,
    val publicKeyBase64: String?,
    val encryptionPublicKeyBase64: String?
) {
    fun toJSON(): ByteArray = JSONObject().apply {
        put("nickname", nickname)
        publicKeyBase64?.let { put("publicKeyBase64", it) }
        encryptionPublicKeyBase64?.let { put("encryptionPublicKeyBase64", it) }
    }.toString().toByteArray()

    companion object {
        fun fromJSON(data: ByteArray): AnnouncementPayload? = runCatching {
            val j = JSONObject(String(data))
            AnnouncementPayload(
                nickname = j.getString("nickname"),
                publicKeyBase64 = if (j.has("publicKeyBase64")) j.getString("publicKeyBase64") else null,
                encryptionPublicKeyBase64 = if (j.has("encryptionPublicKeyBase64")) j.getString("encryptionPublicKeyBase64") else null
            )
        }.getOrNull()
    }
}

// ── Chat payload ──────────────────────────────────────────────────────────────

data class ChatPayload(
    val text: String,
    val recipientID: String? = null,
    val encrypted: Boolean? = null,
    val ciphertextB64: String? = null
) {
    fun toJSON(): ByteArray = JSONObject().apply {
        put("text", text)
        recipientID?.let { put("recipientID", it) }
        encrypted?.let { put("encrypted", it) }
        ciphertextB64?.let { put("ciphertextB64", it) }
    }.toString().toByteArray()

    companion object {
        fun fromJSON(data: ByteArray): ChatPayload? = runCatching {
            val j = JSONObject(String(data))
            ChatPayload(
                text = j.optString("text", ""),
                recipientID = if (j.has("recipientID")) j.getString("recipientID") else null,
                encrypted = if (j.has("encrypted")) j.getBoolean("encrypted") else null,
                ciphertextB64 = if (j.has("ciphertextB64")) j.getString("ciphertextB64") else null
            )
        }.getOrNull()
    }
}

// ── Image chunk payload ───────────────────────────────────────────────────────

data class ImageChunkPayload(
    val transferId: UUID,
    val chunkIndex: Int,
    val totalChunks: Int,
    val data: ByteArray
) {
    fun toJSON(): ByteArray = JSONObject().apply {
        put("transferId", transferId.toString())
        put("chunkIndex", chunkIndex)
        put("totalChunks", totalChunks)
        put("data", android.util.Base64.encodeToString(data, android.util.Base64.NO_WRAP))
    }.toString().toByteArray()

    override fun equals(other: Any?) =
        other is ImageChunkPayload && transferId == other.transferId && chunkIndex == other.chunkIndex
    override fun hashCode() = 31 * transferId.hashCode() + chunkIndex

    companion object {
        fun fromJSON(b: ByteArray): ImageChunkPayload? = runCatching {
            val j = JSONObject(String(b))
            ImageChunkPayload(
                transferId = UUID.fromString(j.getString("transferId")),
                chunkIndex = j.getInt("chunkIndex"),
                totalChunks = j.getInt("totalChunks"),
                data = android.util.Base64.decode(j.getString("data"), android.util.Base64.NO_WRAP)
            )
        }.getOrNull()
    }
}

// ── Map label payload ─────────────────────────────────────────────────────────

data class MapLabelPayload(
    val id: UUID,
    val category: String,
    val lat: Double,
    val lon: Double,
    val senderID: String,
    val senderName: String,
    val timestamp: Long,
    val customLabelName: String? = null,
    val customDescription: String? = null,
    val customSystemImage: String? = null
) {
    fun toJSON(): ByteArray = JSONObject().apply {
        put("i", id.toString())
        put("c", category)
        put("a", lat)
        put("o", lon)
        put("t", timestamp)
        customLabelName?.let { put("n", it) }
        customDescription?.let { put("d", it) }
        customSystemImage?.let { put("s", it) }
    }.toString().toByteArray()

    companion object {
        fun fromJSON(b: ByteArray, senderID: String = "", senderName: String = ""): MapLabelPayload? =
            runCatching {
                val j = JSONObject(String(b))
                MapLabelPayload(
                    id = UUID.fromString(j.getString("i")),
                    category = j.getString("c"),
                    lat = j.getDouble("a"),
                    lon = j.getDouble("o"),
                    timestamp = j.getLong("t"),
                    senderID = senderID,
                    senderName = senderName,
                    customLabelName = if (j.has("n")) j.getString("n") else null,
                    customDescription = if (j.has("d")) j.getString("d") else null,
                    customSystemImage = if (j.has("s")) j.getString("s") else null
                )
            }.getOrNull()
    }
}

// ── Map label vote payload ────────────────────────────────────────────────────

data class MapLabelVotePayload(
    val labelId: UUID,
    val vote: Int,
    val voterID: String
) {
    fun toJSON(): ByteArray = JSONObject().apply {
        put("l", labelId.toString())
        put("v", vote)
        put("r", voterID)
    }.toString().toByteArray()

    companion object {
        fun fromJSON(b: ByteArray): MapLabelVotePayload? = runCatching {
            val j = JSONObject(String(b))
            MapLabelVotePayload(
                labelId = UUID.fromString(j.getString("l")),
                vote = j.getInt("v"),
                voterID = j.getString("r")
            )
        }.getOrNull()
    }
}

// ── Map label image chunk payload ─────────────────────────────────────────────

/** Thumbnail chunk — optional LZ4 compression signalled by compressed=true. */
data class MapLabelImageChunkPayload(
    val imageId: UUID,
    val labelId: UUID,
    val index: Int,
    val total: Int,
    val data: ByteArray,
    val compressed: Boolean? = null   // true = reassembled bytes are LZ4; null = legacy raw JPEG
) {
    fun toJSON(): ByteArray = JSONObject().apply {
        put("i", imageId.toString())
        put("l", labelId.toString())
        put("x", index)
        put("t", total)
        put("d", android.util.Base64.encodeToString(data, android.util.Base64.NO_WRAP))
        compressed?.let { put("c", it) }
    }.toString().toByteArray()

    override fun equals(other: Any?) =
        other is MapLabelImageChunkPayload && imageId == other.imageId && index == other.index
    override fun hashCode() = 31 * imageId.hashCode() + index

    companion object {
        fun fromJSON(b: ByteArray): MapLabelImageChunkPayload? = runCatching {
            val j = JSONObject(String(b))
            MapLabelImageChunkPayload(
                imageId = UUID.fromString(j.getString("i")),
                labelId = UUID.fromString(j.getString("l")),
                index = j.getInt("x"),
                total = j.getInt("t"),
                data = android.util.Base64.decode(j.getString("d"), android.util.Base64.NO_WRAP),
                compressed = if (j.has("c")) j.getBoolean("c") else null
            )
        }.getOrNull()
    }
}

// ── Alert type & payload ──────────────────────────────────────────────────────

enum class AlertType(val value: String) {
    HAZARD("hazard"),
    AID("aid"),
    OTHER("other");

    companion object {
        fun from(s: String) = entries.firstOrNull { it.value == s } ?: OTHER
    }
}

data class AlertPayload(
    val alertID: String,
    val type: AlertType,
    val severity: Int,
    val lat: Double,
    val lon: Double,
    val description: String,
    val createdAt: Long,
    val expiresAt: Long
) {
    fun toJSON(): ByteArray = JSONObject().apply {
        put("alertID", alertID)
        put("type", type.value)
        put("severity", severity)
        put("lat", lat)
        put("lon", lon)
        put("description", description)
        put("createdAt", createdAt)
        put("expiresAt", expiresAt)
    }.toString().toByteArray()

    companion object {
        fun fromJSON(b: ByteArray): AlertPayload? = runCatching {
            val j = JSONObject(String(b))
            AlertPayload(
                alertID = j.getString("alertID"),
                type = AlertType.from(j.getString("type")),
                severity = j.getInt("severity"),
                lat = j.getDouble("lat"),
                lon = j.getDouble("lon"),
                description = j.getString("description"),
                createdAt = j.getLong("createdAt"),
                expiresAt = j.getLong("expiresAt")
            )
        }.getOrNull()
    }
}

// ── Vouch payload ─────────────────────────────────────────────────────────────

data class VouchPayload(val alertID: String, val value: Int) {
    fun toJSON(): ByteArray = JSONObject().apply {
        put("alertID", alertID)
        put("value", value)
    }.toString().toByteArray()

    companion object {
        fun fromJSON(b: ByteArray): VouchPayload? = runCatching {
            val j = JSONObject(String(b))
            VouchPayload(alertID = j.getString("alertID"), value = j.getInt("value"))
        }.getOrNull()
    }
}
