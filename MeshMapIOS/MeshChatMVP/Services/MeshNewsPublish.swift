import Foundation

// MARK: - API request body (matches https://news-jade-nine.vercel.app/api/stories/generate)

struct MeshNewsGenerateBody: Encodable {
    let news_id: String
    /// Required by API: story is only created when both news_id and sos are present.
    let sos: SOSPayload
    let events: [EventPayload]
}

struct SOSPayload: Encodable {
    let title: String
    let description: String
    let latitude: Double
    let longitude: Double
}

struct EventPayload: Encodable {
    let title: String
    let description: String
    let latitude: Double
    let longitude: Double
    let image: ImagePayload?
}

struct ImagePayload: Encodable {
    let data: String  // base64
    let mime_type: String
}

// MARK: - Publish

private let meshNewsBaseURL = "https://news-jade-nine.vercel.app"
private let meshNewsGeneratePath = "/api/stories/generate"

/// Builds request body from current map labels + thumbnails and POSTs to MeshNews.
/// API requires news_id + sos + events[] (sos required; events can be empty).
func publishMapDataToMeshNews(
    mapLabels: [UUID: MapLabelPayload],
    thumbnails: [UUID: Data],
    userLocation: (lat: Double, lon: Double)?
) async -> Result<Void, Error> {
    let events: [EventPayload] = mapLabels.values.map { payload in
        let title = payload.customLabelName?.isEmpty == false
            ? payload.customLabelName!
            : (LabelCategory(rawValue: payload.category)?.displayName ?? payload.category)
        let description = payload.customDescription ?? ""
        let imageData = thumbnails[payload.id]
        let image: ImagePayload? = imageData.map { data in
            ImagePayload(data: data.base64EncodedString(), mime_type: "image/jpeg")
        }
        return EventPayload(
            title: title,
            description: description,
            latitude: payload.lat,
            longitude: payload.lon,
            image: image
        )
    }

    // API requires sos (title, description, latitude, longitude). Use user location, else first event, else placeholder.
    let (sosLat, sosLon): (Double, Double) = if let loc = userLocation {
        (loc.lat, loc.lon)
    } else if let first = events.first {
        (first.latitude, first.longitude)
    } else {
        (0, 0)
    }
    let sos = SOSPayload(
        title: "Map export",
        description: "Community map labels from mesh.",
        latitude: sosLat,
        longitude: sosLon
    )

    let body = MeshNewsGenerateBody(
        news_id: UUID().uuidString,
        sos: sos,
        events: events
    )

    guard let url = URL(string: meshNewsBaseURL + meshNewsGeneratePath) else {
        return .failure(NSError(domain: "MeshNewsPublish", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid URL"]))
    }

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try? JSONEncoder().encode(body)

    do {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            return .failure(NSError(domain: "MeshNewsPublish", code: -2, userInfo: [NSLocalizedDescriptionKey: "No HTTP response"]))
        }
        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            let message = body.isEmpty
                ? "Server returned \(http.statusCode)"
                : "\(http.statusCode): \(body)"
            return .failure(NSError(domain: "MeshNewsPublish", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: message]))
        }
        return .success(())
    } catch {
        return .failure(error)
    }
}
