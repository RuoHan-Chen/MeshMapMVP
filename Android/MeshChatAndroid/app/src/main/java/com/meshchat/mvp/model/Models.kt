package com.meshchat.mvp.model

import java.util.UUID

// ── Chat ─────────────────────────────────────────────────────────────────────

data class ChatMessage(
    val id: UUID = UUID.randomUUID(),
    val envelopeId: UUID,
    val senderID: String,
    val senderName: String,
    val text: String,
    val date: Long,
    val isLocal: Boolean,
    val distanceFromMe: Double? = null,
    val imageJPEGBase64: String? = null
) {
    val isExpired: Boolean get() = System.currentTimeMillis() - date > EXPIRATION_MS
    companion object { const val EXPIRATION_MS = 20 * 60 * 1000L }
}

// ── Map label models ──────────────────────────────────────────────────────────

enum class LabelCategory(val rawValue: String) {
    HAZARD("hazard"), HELP("help"), OTHER("other"),
    ARMED_CONFLICT("armed_conflict"), EXPLOSION("explosion"), DRONE("drone"),
    MILITARY_MOVEMENT("military_movement"), POLICE_CRACKDOWN("police_crackdown"),
    ARRESTS("arrests"), CHECKPOINT("checkpoint");

    val displayName: String get() = when (this) {
        HAZARD -> "Hazard"; HELP -> "Help"; OTHER -> "Other"
        ARMED_CONFLICT -> "Armed conflict / gunfire"
        EXPLOSION -> "Explosion / bombing"
        DRONE -> "Drone / airstrike"
        MILITARY_MOVEMENT -> "Military movement"
        POLICE_CRACKDOWN -> "Police crackdown"
        ARRESTS -> "Arrests / detention"
        CHECKPOINT -> "Checkpoint / roadblock"
    }

    companion object {
        fun from(raw: String) = entries.firstOrNull { it.rawValue == raw } ?: CHECKPOINT
        val configurableEventTypes = listOf(HAZARD, HELP, OTHER)
    }
}

/** In-memory label with AlertTrustEngine score. */
data class MapLabelRecord(
    val id: UUID,
    val category: LabelCategory,
    val latitude: Double,
    val longitude: Double,
    val senderID: String,
    val senderName: String,
    val date: Long,           // epoch millis
    /** Trust score from AlertTrustEngine — higher = more trusted, 0 = unverified. */
    val trustScore: Double = 0.0,
    /** Number of votes cast (0 = unverified). */
    val voteCount: Int = 0,
    val customLabelName: String? = null,
    val customDescription: String? = null,
    val customSystemImage: String? = null
) {
    val displayName: String get() =
        if (!customLabelName.isNullOrBlank()) customLabelName else category.displayName

    val isExpired: Boolean get() = System.currentTimeMillis() - date > EVENT_EXPIRATION_MS

    companion object {
        const val EVENT_EXPIRATION_MS = 60 * 60 * 1000L
    }
}

data class LabelCluster(
    val id: UUID,
    var latitude: Double,
    var longitude: Double,
    val records: MutableList<MapLabelRecord> = mutableListOf()
)

// ── Discovered peer ───────────────────────────────────────────────────────────

data class DiscoveredPeer(
    val id: String,
    var name: String,
    var rssi: Int,
    var nickname: String?,
    var linkState: String,
    var publicKey: ByteArray?,
    var lastSeen: Long
) {
    override fun equals(other: Any?) = other is DiscoveredPeer && id == other.id
    override fun hashCode() = id.hashCode()
}

// ── Contact activity ──────────────────────────────────────────────────────────

data class ContactActivityState(
    val lastText: String,
    val lastDate: Long,
    val unread: Int
)

// ── Device identity ───────────────────────────────────────────────────────────

data class DeviceIdentity(
    val deviceID: String,
    var nickname: String,
    var shareLocation: Boolean
)

// ── Event types config ────────────────────────────────────────────────────────

data class EventTypeConfig(val name: String, val description: String)
data class EventTypesConfig(
    val hazard: EventTypeConfig = EventTypeConfig("Hazard", "Danger or risk indicators"),
    val help: EventTypeConfig = EventTypeConfig("Help", "Assistance or support requests"),
    val other: EventTypeConfig = EventTypeConfig("Other", "Miscellaneous event categories")
) { companion object { val default = EventTypesConfig() } }
