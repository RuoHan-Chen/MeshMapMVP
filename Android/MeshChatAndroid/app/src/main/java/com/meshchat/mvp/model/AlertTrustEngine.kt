package com.meshchat.mvp.model

import com.meshchat.mvp.database.NodeSightingEntity
import com.meshchat.mvp.database.SavedContactEntity
import kotlin.math.*

// ── Output types ──────────────────────────────────────────────────────────────

data class ScoredLabel(
    val payload: MapLabelPayload,
    val score: Double,
    val voteCount: Int
)

data class LabelEventCluster(
    val id: java.util.UUID = java.util.UUID.randomUUID(),
    val labels: List<ScoredLabel>
) {
    val clusterScore: Double get() = labels.sumOf { it.score }
    val leadScoredLabel: ScoredLabel get() = labels.maxByOrNull { it.score }!!
    val leadLabel: MapLabelPayload get() = leadScoredLabel.payload
}

// ── Engine ────────────────────────────────────────────────────────────────────

object AlertTrustEngine {

    // Weights
    const val W_AUTHOR = 10.0
    const val W_VOUCH  = 5.0
    const val W_DENY   = 10.0

    // Relationship multipliers
    const val R_FRIEND    = 1.0
    const val R_ASSOCIATE = 0.5
    const val R_STRANGER  = 0.2

    // Proximity multipliers
    const val P_CLOSE = 1.0
    const val P_FAR   = 0.5
    const val PROXIMITY_GPS_THRESHOLD_METERS = 500.0
    const val PROXIMITY_RSSI_THRESHOLD = -70

    // Time decay — half-life of 2 hours
    val DECAY_LAMBDA = ln(2.0) / (2.0 * 3600.0)

    // Clustering thresholds
    const val CLUSTER_RADIUS_METERS      = 500.0
    const val CLUSTER_TIME_WINDOW_SECS   = 15.0 * 60.0

    fun scoreLabel(
        authorID: String,
        lat: Double,
        lon: Double,
        timestampMs: Long,
        votes: Map<String, Int>,
        relationships: Map<String, String>,
        sightings: Map<String, NodeSightingEntity>,
        myDeviceID: String = "",
        nowMs: Long = System.currentTimeMillis()
    ): Double {
        val createdAtSec = timestampMs / 1000.0
        val ageSeconds   = (nowMs / 1000.0) - createdAtSec
        val decay        = exp(-DECAY_LAMBDA * maxOf(0.0, ageSeconds))

        val rAuthor = if (authorID == myDeviceID) R_FRIEND
                      else relationshipMultiplier(relationships[authorID])
        var total = W_AUTHOR * rAuthor

        for ((voucherID, vote) in votes) {
            val r = relationshipMultiplier(relationships[voucherID])
            val p = proximityMultiplier(lat, lon, sightings[voucherID])
            if (vote > 0) total += W_VOUCH * r * p
            else          total -= W_DENY  * r * p
        }

        return total * decay
    }

    fun clusterLabels(scoredLabels: List<ScoredLabel>): List<LabelEventCluster> {
        val remaining = scoredLabels.toMutableList()
        val clusters  = mutableListOf<LabelEventCluster>()

        while (remaining.isNotEmpty()) {
            val seed    = remaining.removeFirst()
            val members = mutableListOf(seed)
            val iter    = remaining.iterator()

            while (iter.hasNext()) {
                val candidate = iter.next()
                val dist = haversineMeters(
                    seed.payload.lat, seed.payload.lon,
                    candidate.payload.lat, candidate.payload.lon
                )
                val timeDiff = abs(
                    seed.payload.timestamp / 1000.0 - candidate.payload.timestamp / 1000.0
                )
                if (dist <= CLUSTER_RADIUS_METERS && timeDiff <= CLUSTER_TIME_WINDOW_SECS) {
                    members.add(candidate)
                    iter.remove()
                }
            }
            clusters.add(LabelEventCluster(labels = members))
        }

        return clusters.sortedByDescending { it.clusterScore }
    }

    private fun relationshipMultiplier(relationship: String?): Double = when (relationship) {
        SavedContactEntity.FRIEND    -> R_FRIEND
        SavedContactEntity.ASSOCIATE -> R_ASSOCIATE
        else                         -> R_STRANGER
    }

    private fun proximityMultiplier(
        alertLat: Double, alertLon: Double,
        sighting: NodeSightingEntity?
    ): Double {
        sighting ?: return P_FAR
        if (sighting.lat != 0.0 || sighting.lon != 0.0) {
            val dist = haversineMeters(alertLat, alertLon, sighting.lat, sighting.lon)
            if (dist <= PROXIMITY_GPS_THRESHOLD_METERS) return P_CLOSE
        }
        return if (sighting.rssi > PROXIMITY_RSSI_THRESHOLD) P_CLOSE else P_FAR
    }

    fun haversineMeters(lat1: Double, lon1: Double, lat2: Double, lon2: Double): Double {
        val R    = 6_371_000.0
        val toRad = { d: Double -> d * PI / 180 }
        val dLat = toRad(lat2 - lat1)
        val dLon = toRad(lon2 - lon1)
        val a    = sin(dLat / 2).pow(2) +
                   cos(toRad(lat1)) * cos(toRad(lat2)) * sin(dLon / 2).pow(2)
        return R * 2 * atan2(sqrt(a), sqrt(1 - a))
    }
}
