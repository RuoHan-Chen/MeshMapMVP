package com.meshchat.mvp.database

import androidx.room.*
import kotlinx.coroutines.flow.Flow

// ── Entities ──────────────────────────────────────────────────────────────────

@Entity(tableName = "saved_contacts")
data class SavedContactEntity(
    @PrimaryKey val id: String,
    val nickname: String,
    val relationship: String = "associate",
    val firstSeen: Long,
    val lastSeen: Long,
    val publicKey: ByteArray
) {
    companion object {
        const val ASSOCIATE = "associate"
        const val FRIEND = "friend"
    }
    override fun equals(other: Any?) = other is SavedContactEntity && id == other.id
    override fun hashCode() = id.hashCode()
}

@Entity(tableName = "contacts")
data class MeshContactEntity(
    @PrimaryKey val id: String,
    val nickname: String,
    val relationship: String = "associate",
    val firstSeen: Long,
    val lastSeen: Long,
    val publicKey: ByteArray?
) {
    override fun equals(other: Any?) = other is MeshContactEntity && id == other.id
    override fun hashCode() = id.hashCode()
}

@Entity(tableName = "messages")
data class PersistedMessageEntity(
    @PrimaryKey val id: String,
    val senderID: String,
    val senderName: String,
    val text: String,
    val timestamp: Long,
    val channel: String = "broadcast",
    val receivedAt: Long,
    val imageBase64: String? = null
)

@Entity(tableName = "alerts")
data class AlertEntity(
    @PrimaryKey val id: String,
    val authorID: String,
    val type: String,
    val severity: Int,
    val lat: Double,
    val lon: Double,
    val description: String,
    val createdAt: Long,
    val expiresAt: Long,
    val trustScore: Double = 0.0
)

@Entity(tableName = "vouches", primaryKeys = ["alertID", "voucherID"])
data class VouchEntity(
    val alertID: String,
    val voucherID: String,
    val value: Int,
    val timestamp: Long
)

@Entity(tableName = "node_sightings")
data class NodeSightingEntity(
    @PrimaryKey(autoGenerate = true) val id: Long = 0,
    val nodeID: String,
    val lat: Double,
    val lon: Double,
    val timestamp: Long,
    val rssi: Int
)

// ── DAOs ──────────────────────────────────────────────────────────────────────

@Dao
interface SavedContactDao {
    @Query("SELECT * FROM saved_contacts ORDER BY lastSeen DESC")
    suspend fun listAll(): List<SavedContactEntity>

    @Query("SELECT * FROM saved_contacts WHERE publicKey = :key LIMIT 1")
    suspend fun findByPublicKey(key: ByteArray): SavedContactEntity?

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun insert(contact: SavedContactEntity)

    @Update
    suspend fun update(contact: SavedContactEntity)

    @Delete
    suspend fun delete(contact: SavedContactEntity)
}

@Dao
interface MeshContactDao {
    @Query("SELECT * FROM contacts WHERE id = :id LIMIT 1")
    suspend fun find(id: String): MeshContactEntity?

    @Insert(onConflict = OnConflictStrategy.IGNORE)
    suspend fun insert(contact: MeshContactEntity)

    @Update
    suspend fun update(contact: MeshContactEntity)

    @Query("UPDATE contacts SET publicKey = :key WHERE id = :id")
    suspend fun updatePublicKey(id: String, key: ByteArray)
}

@Dao
interface MessageDao {
    @Query("SELECT * FROM messages WHERE channel = :channel ORDER BY timestamp ASC LIMIT :limit")
    suspend fun getMessages(channel: String, limit: Int = 200): List<PersistedMessageEntity>

    @Insert(onConflict = OnConflictStrategy.IGNORE)
    suspend fun insert(msg: PersistedMessageEntity)

    @Query("DELETE FROM messages WHERE channel LIKE 'dm:%' AND receivedAt < :cutoff")
    suspend fun pruneDMMessages(cutoff: Long)
}

@Dao
interface AlertDao {
    @Query("SELECT * FROM alerts WHERE expiresAt > :now ORDER BY createdAt DESC")
    suspend fun activeAlerts(now: Long = System.currentTimeMillis() / 1000): List<AlertEntity>

    @Query("SELECT * FROM alerts WHERE id = :id LIMIT 1")
    suspend fun find(id: String): AlertEntity?

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun insert(alert: AlertEntity)

    @Update
    suspend fun update(alert: AlertEntity)
}

@Dao
interface VouchDao {
    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun insert(vouch: VouchEntity)

    @Query("SELECT * FROM vouches WHERE alertID = :alertID")
    suspend fun forAlert(alertID: String): List<VouchEntity>
}

@Dao
interface NodeSightingDao {
    @Insert
    suspend fun insert(s: NodeSightingEntity)

    @Query("SELECT * FROM node_sightings WHERE nodeID = :nodeID ORDER BY timestamp DESC LIMIT :limit")
    suspend fun recent(nodeID: String, limit: Int = 10): List<NodeSightingEntity>
}

// ── Database ──────────────────────────────────────────────────────────────────

@Database(
    entities = [
        SavedContactEntity::class,
        MeshContactEntity::class,
        PersistedMessageEntity::class,
        AlertEntity::class,
        VouchEntity::class,
        NodeSightingEntity::class
    ],
    version = 1,
    exportSchema = false
)
abstract class MeshDatabase : RoomDatabase() {
    abstract fun savedContactDao(): SavedContactDao
    abstract fun meshContactDao(): MeshContactDao
    abstract fun messageDao(): MessageDao
    abstract fun alertDao(): AlertDao
    abstract fun vouchDao(): VouchDao
    abstract fun nodeSightingDao(): NodeSightingDao
}
