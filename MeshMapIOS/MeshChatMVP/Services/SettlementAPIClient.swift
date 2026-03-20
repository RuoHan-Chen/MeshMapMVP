import Foundation

enum SettlementCanonicalStatus: String, Codable {
    case settled
    case submitted
    case duplicate
    case conflict
    case failed
    case expired
    case invalid
}

struct SettlementSubmitRequest: Encodable {
    let payment_id: String
    let sender_device_id: String
    let recipient_device_id: String
    let amount_minor: Int64
    let asset_code: String
    let memo: String?
    let created_at: Int64
    let expires_at: Int64?
    let local_sequence: Int64
    let sender_signature: String
    let raw_payload_json: String

    let sender_wallet_address: String?
    let recipient_wallet_address: String?

    let submitted_by_device_id: String
    let app_version: String
    let schema_version: Int
}

struct SettlementSubmitResponse: Decodable {
    let payment_id: String
    let canonical_status: SettlementCanonicalStatus
    let backend_receipt_id: String?
    let transaction_signature: String?
    let settled_at: Int64?
    let failure_reason: String?
    let conflict_reason: String?
    let canonical_sequence: Int64?
}

enum SettlementAPIError: Error, Equatable {
    case transient(String)
    case permanent(String)
}

final class SettlementAPIClient {
    static let shared = SettlementAPIClient()

    private let urlSession: URLSession

    // MARK: - Debug simulation hooks (Wave 2 manual testing)
    enum DebugSimulationMode {
        case none
        case transientFailureOnce
        case duplicateOnce
    }

    private let debugLock = NSLock()
    private var debugMode: DebugSimulationMode = .none

    init(urlSession: URLSession = .shared) {
        self.urlSession = urlSession
    }

    func setDebugMode(_ mode: DebugSimulationMode) {
        debugLock.lock()
        debugMode = mode
        debugLock.unlock()
    }

    private func takeDebugMode() -> DebugSimulationMode {
        debugLock.lock()
        let m = debugMode
        debugMode = .none
        debugLock.unlock()
        return m
    }

    private func backendBaseURL() -> URL? {
        // Prefer user-configured value so this isn't hardcoded for every developer.
        if let s = UserDefaults.standard.string(forKey: "meshchat.settlement.backendBaseURL"),
           !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let url = URL(string: s) {
            return url
        }
#if DEBUG
        // DEBUG fallback for local dev (optional; can be overridden in Settings/debug UI).
        return URL(string: "http://localhost:3000")
#else
        return nil
#endif
    }

    func submitPayment(_ request: SettlementSubmitRequest) async throws -> (response: SettlementSubmitResponse, rawResponse: String) {
        // Debug simulations before any network call.
        let debug = takeDebugMode()
        switch debug {
        case .transientFailureOnce:
            throw SettlementAPIError.transient("Debug: simulated transient backend failure")
        case .duplicateOnce:
            // Return a duplicate outcome without network.
            let dup = SettlementSubmitResponse(
                payment_id: request.payment_id,
                canonical_status: .duplicate,
                backend_receipt_id: "debug-receipt-\(UUID().uuidString.prefix(8))",
                transaction_signature: nil,
                settled_at: nil,
                failure_reason: nil,
                conflict_reason: nil,
                canonical_sequence: nil
            )
            return (dup, "{ \"debug\": true, \"canonical_status\": \"duplicate\" }")
        case .none:
            break
        }

        guard let base = backendBaseURL() else {
            throw SettlementAPIError.permanent("Settlement backend URL not configured")
        }

        guard let url = URL(string: "/api/payments/submit", relativeTo: base) else {
            throw SettlementAPIError.permanent("Invalid settlement backend URL")
        }

        var httpRequest = URLRequest(url: url)
        httpRequest.httpMethod = "POST"
        httpRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        httpRequest.httpBody = try JSONEncoder().encode(request)

        do {
            let (data, response) = try await urlSession.data(for: httpRequest)
            let raw = String(data: data, encoding: .utf8) ?? ""
            guard let http = response as? HTTPURLResponse else {
                throw SettlementAPIError.transient("No HTTP response from backend")
            }
            if (200...299).contains(http.statusCode) {
                let decoded = try JSONDecoder().decode(SettlementSubmitResponse.self, from: data)
                return (decoded, raw)
            }

            // Treat 5xx as transient; 4xx as permanent.
            if (500...599).contains(http.statusCode) {
                throw SettlementAPIError.transient("Server error \(http.statusCode): \(raw)")
            } else {
                throw SettlementAPIError.permanent("Request rejected \(http.statusCode): \(raw)")
            }
        } catch let apiErr as SettlementAPIError {
            throw apiErr
        } catch {
            // Network / timeout / transport errors are considered transient.
            throw SettlementAPIError.transient(error.localizedDescription)
        }
    }
}

