import Foundation

// MARK: - Output types

struct ScoredAlert {
    let alert: Alert
    let score: Double
}

struct AlertCluster: Identifiable {
    let id = UUID()
    let alerts: [ScoredAlert]

    var clusterScore: Double { alerts.reduce(0) { $0 + $1.score } }
    var leadAlert: Alert { alerts.max(by: { $0.score < $1.score })!.alert }
}

// MARK: - Engine

enum AlertTrustEngine {

    // MARK: Configurable weights
    static let wAuthor: Double = 10
    static let wVouch:  Double = 5
    static let wDeny:   Double = 10

    // MARK: Relationship multipliers
    static let rFriend:    Double = 1.0
    static let rAssociate: Double = 0.5
    static let rStranger:  Double = 0.2

    // MARK: Proximity multipliers
    static let pClose: Double = 1.0
    static let pFar:   Double = 0.5
    static let proximityGPSThresholdMeters: Double = 500
    static let proximityRSSIThreshold: Int = -70

    // MARK: Time decay — half-life of 2 hours
    // e^(-λΔt) = 0.5 when Δt = 2 h  →  λ = ln(2) / (2 * 3600)
    static let decayLambda: Double = log(2.0) / (2.0 * 3600.0)

    // MARK: Clustering thresholds
    static let clusterRadiusMeters:      Double = 500
    static let clusterTimeWindowSeconds: Double = 15 * 60

    // MARK: - Score

    /// Computes S_alert using the formula:
    /// ((W_author·R_author) + Σ(W_vouch·R_i·P_i) − Σ(W_deny·R_j·P_j)) · e^(−λΔt)
    ///
    /// - Parameters:
    ///   - alert: The alert to score.
    ///   - vouches: All vouches recorded for this alert.
    ///   - relationships: nodeID → "friend" | "associate" (absent = stranger).
    ///     Build from `SavedContact` entries using `canonicalSenderID`.
    ///   - sightings: nodeID → most-recent `NodeSighting` for proximity lookup.
    ///   - now: Reference time; injectable for unit testing.
    static func score(
        alert: Alert,
        vouches: [Vouch],
        relationships: [String: String],
        sightings: [String: NodeSighting],
        now: Date = Date()
    ) -> Double {
        let age   = now.timeIntervalSince1970 - Double(alert.createdAt)
        let decay = exp(-decayLambda * max(0.0, age))

        let rAuthor = relationshipMultiplier(relationships[alert.authorID])
        var total   = wAuthor * rAuthor

        for vouch in vouches {
            let r = relationshipMultiplier(relationships[vouch.voucherID])
            let p = proximityMultiplier(
                alertLat: alert.lat, alertLon: alert.lon,
                sighting: sightings[vouch.voucherID]
            )
            if vouch.value > 0 {
                total += wVouch * r * p
            } else {
                total -= wDeny  * r * p
            }
        }

        return total * decay
    }

    // MARK: - Clustering

    /// Groups `ScoredAlert`s into clusters (≤500 m apart, ≤15 min apart),
    /// then returns them sorted descending by cluster score.
    static func cluster(scoredAlerts: [ScoredAlert]) -> [AlertCluster] {
        var remaining = scoredAlerts
        var clusters: [AlertCluster] = []

        while !remaining.isEmpty {
            let seed    = remaining.removeFirst()
            var members = [seed]
            var i       = 0

            while i < remaining.count {
                let candidate = remaining[i]
                let dist = haversineMeters(
                    lat1: seed.alert.lat, lon1: seed.alert.lon,
                    lat2: candidate.alert.lat, lon2: candidate.alert.lon
                )
                let timeDiff = abs(Double(seed.alert.createdAt - candidate.alert.createdAt))

                if dist <= clusterRadiusMeters && timeDiff <= clusterTimeWindowSeconds {
                    members.append(remaining.remove(at: i))
                } else {
                    i += 1
                }
            }

            clusters.append(AlertCluster(alerts: members))
        }

        return clusters.sorted { $0.clusterScore > $1.clusterScore }
    }

    // MARK: - Helpers

    private static func relationshipMultiplier(_ relationship: String?) -> Double {
        switch relationship {
        case SavedContact.friend:    return rFriend
        case SavedContact.associate: return rAssociate
        default:                     return rStranger
        }
    }

    /// P multiplier for a voucher: GPS distance to alert location first,
    /// then RSSI from latest sighting, then default to pFar.
    private static func proximityMultiplier(
        alertLat: Double, alertLon: Double,
        sighting: NodeSighting?
    ) -> Double {
        guard let s = sighting else { return pFar }
        if s.lat != 0 || s.lon != 0 {
            let dist = haversineMeters(lat1: alertLat, lon1: alertLon, lat2: s.lat, lon2: s.lon)
            if dist <= proximityGPSThresholdMeters { return pClose }
        }
        return s.rssi > proximityRSSIThreshold ? pClose : pFar
    }

    private static func haversineMeters(
        lat1: Double, lon1: Double,
        lat2: Double, lon2: Double
    ) -> Double {
        let R    = 6_371_000.0
        let toRad: (Double) -> Double = { $0 * .pi / 180 }
        let dLat = toRad(lat2 - lat1)
        let dLon = toRad(lon2 - lon1)
        let a    = sin(dLat / 2) * sin(dLat / 2)
                 + cos(toRad(lat1)) * cos(toRad(lat2)) * sin(dLon / 2) * sin(dLon / 2)
        return R * 2 * atan2(sqrt(a), sqrt(1 - a))
    }
}
