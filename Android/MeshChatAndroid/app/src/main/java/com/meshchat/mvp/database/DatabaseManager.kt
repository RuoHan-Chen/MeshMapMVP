package com.meshchat.mvp.database

import android.content.Context
import android.util.Base64
import androidx.room.Room
import com.meshchat.mvp.crypto.KeyManager

object DatabaseManager {
    // Nullable until init() is called — all accessors guard against this
    private var db: MeshDatabase? = null

    fun init(context: Context) {
        if (db != null) return   // idempotent
        db = Room.databaseBuilder(context.applicationContext, MeshDatabase::class.java, "mesh.db")
            .fallbackToDestructiveMigration()
            .build()
    }

    private fun requireDb(): MeshDatabase =
        db ?: throw IllegalStateException("DatabaseManager.init() not called yet")

    // ── Saved contacts ────────────────────────────────────────────────────────

    suspend fun listContacts(): List<SavedContactEntity> =
        runCatching { requireDb().savedContactDao().listAll() }.getOrDefault(emptyList())

    suspend fun findContactByPublicKey(key: ByteArray): SavedContactEntity? =
        runCatching { requireDb().savedContactDao().findByPublicKey(key) }.getOrNull()

    suspend fun createContact(c: SavedContactEntity) =
        runCatching { requireDb().savedContactDao().insert(c) }

    suspend fun updateContact(c: SavedContactEntity) =
        runCatching { requireDb().savedContactDao().update(c) }

    suspend fun deleteContact(c: SavedContactEntity) =
        runCatching { requireDb().savedContactDao().delete(c) }

    suspend fun updateLastSeenForPublicKey(key: ByteArray) = runCatching {
        val c = requireDb().savedContactDao().findByPublicKey(key) ?: return@runCatching
        requireDb().savedContactDao().update(c.copy(lastSeen = System.currentTimeMillis() / 1000))
    }

    suspend fun savedNickname(forSenderID: String): String? = runCatching {
        val sid = forSenderID.trim()
        if (sid.isEmpty()) return@runCatching null
        val pk = KeyManager.decodePublicKeyBase64(sid)
        if (pk != null) {
            val c = findContactByPublicKey(pk)
            if (c != null) return@runCatching c.nickname
        }
        listContacts().firstOrNull { canonicalSenderID(it.publicKey) == sid }?.nickname
    }.getOrNull()

    // ── Mesh contacts ─────────────────────────────────────────────────────────

    suspend fun upsertContact(id: String, nickname: String) = runCatching {
        val now = System.currentTimeMillis() / 1000
        val d = requireDb()
        val existing = d.meshContactDao().find(id)
        if (existing != null) {
            d.meshContactDao().update(existing.copy(nickname = nickname, lastSeen = now))
        } else {
            d.meshContactDao().insert(
                MeshContactEntity(id = id, nickname = nickname, firstSeen = now, lastSeen = now, publicKey = null)
            )
        }
    }

    // ── Messages ──────────────────────────────────────────────────────────────

    suspend fun saveMessage(msg: PersistedMessageEntity) =
        runCatching { requireDb().messageDao().insert(msg) }

    suspend fun messages(channel: String = "broadcast", limit: Int = 200): List<PersistedMessageEntity> =
        runCatching { requireDb().messageDao().getMessages(channel, limit) }.getOrDefault(emptyList())

    suspend fun pruneDMMessages(olderThanSeconds: Long) = runCatching {
        val cutoff = System.currentTimeMillis() / 1000 - olderThanSeconds
        requireDb().messageDao().pruneDMMessages(cutoff)
    }

    // ── Alerts ────────────────────────────────────────────────────────────────

    suspend fun saveAlert(a: AlertEntity) =
        runCatching { requireDb().alertDao().insert(a) }

    suspend fun activeAlerts(): List<AlertEntity> =
        runCatching { requireDb().alertDao().activeAlerts() }.getOrDefault(emptyList())

    suspend fun recomputeTrustScore(alertID: String) = runCatching {
        val d = requireDb()
        val alert = d.alertDao().find(alertID) ?: return@runCatching
        val vouches = d.vouchDao().forAlert(alertID)
        val score = vouches.sumOf { it.value.toDouble() * 0.2 }.coerceIn(0.0, 1.0)
        d.alertDao().update(alert.copy(trustScore = score))
    }

    // ── Vouches ───────────────────────────────────────────────────────────────

    suspend fun saveVouch(v: VouchEntity) =
        runCatching { requireDb().vouchDao().insert(v) }

    // ── Node sightings ────────────────────────────────────────────────────────

    suspend fun recordSighting(nodeID: String, lat: Double, lon: Double, rssi: Int) =
        runCatching {
            requireDb().nodeSightingDao().insert(
                NodeSightingEntity(nodeID = nodeID, lat = lat, lon = lon,
                    timestamp = System.currentTimeMillis() / 1000, rssi = rssi)
            )
        }

    // ── Utilities ─────────────────────────────────────────────────────────────

    fun canonicalSenderID(publicKey: ByteArray): String =
        Base64.encodeToString(publicKey, Base64.NO_WRAP or Base64.NO_PADDING)
            .replace("+", "-").replace("/", "_").trimEnd('=')

    /** Returns all non-expired alerts with their vouches in one transaction. */
    suspend fun alertsWithVouches(): List<Pair<AlertEntity, List<VouchEntity>>> {
        val alerts = activeAlerts()
        return alerts.map { alert ->
            val vouches = requireDb().vouchDao().forAlert(alert.id)
            alert to vouches
        }
    }

    /** Recent sightings for a node — used by AlertTrustEngine for proximity scoring. */
    suspend fun recentSightings(nodeID: String, limit: Int = 10): List<NodeSightingEntity> =
        requireDb().nodeSightingDao().recent(nodeID, limit)
}
