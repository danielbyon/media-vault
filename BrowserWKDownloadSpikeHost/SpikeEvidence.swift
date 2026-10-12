import CryptoKit
import Foundation

/// A redacted event sent to the host-process fixture server.
struct SpikeEvent: Codable, Sendable {
    let kind: String
    let timestamp: Double
    let profileID: String
    let profile: String
    let operationID: String
    let fields: [String: String]

    enum CodingKeys: String, CodingKey {
        case kind
        case timestamp
        case profileID = "profile_id"
        case profile
        case operationID = "operation_id"
        case fields
    }
}

/// Posts sanitized experiment events through a cookie-free control session.
final class SpikeFixtureClient: @unchecked Sendable {
    private let baseURL: URL
    private let session: URLSession

    init(baseURL: URL) {
        self.baseURL = baseURL
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.timeoutIntervalForRequest = 8
        self.session = URLSession(configuration: configuration)
    }

    func health() async -> Bool {
        guard let url = URL(string: "/__spike/health", relativeTo: baseURL),
              let (_, response) = try? await session.data(from: url)
        else {
            return false
        }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    func transferObservation(path: String) async -> SpikeFixtureTransferObservation? {
        guard let url = URL(string: "/__spike/evidence", relativeTo: baseURL),
              let (data, response) = try? await session.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let transfers = payload["transfer_events"] as? [[String: Any]],
              let event = transfers.last(where: { $0["path"] as? String == path }),
              let timestamp = (event["timestamp"] as? NSNumber)?.doubleValue,
              let bytesSent = (event["bytes_sent"] as? NSNumber)?.intValue,
              let expectedBytes = (event["expected_bytes"] as? NSNumber)?.intValue,
              let bodyComplete = event["body_complete"] as? Bool
        else {
            return nil
        }
        return SpikeFixtureTransferObservation(
            timestamp: timestamp,
            path: path,
            bytesSent: bytesSent,
            expectedBytes: expectedBytes,
            bodyComplete: bodyComplete
        )
    }

    func post(_ event: SpikeEvent) async {
        guard let url = URL(string: "/__spike/event", relativeTo: baseURL) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONEncoder().encode(event)
        _ = try? await session.data(for: request)
    }
}

struct SpikeFixtureTransferObservation: Sendable {
    let timestamp: Double
    let path: String
    let bytesSent: Int
    let expectedBytes: Int
    let bodyComplete: Bool
}

/// Builds request evidence without preserving credential or body values.
enum SpikeRequestEvidence {
    static func fields(for request: URLRequest) -> [String: String] {
        let headers = request.allHTTPHeaderFields ?? [:]
        let normalizedHeaders = Dictionary(
            headers.map { ($0.key.lowercased(), $0.value) },
            uniquingKeysWith: { first, _ in first }
        )
        let body = request.httpBody
        let cookieNames = cookieNames(from: normalizedHeaders["cookie"])
        let referer = normalizedHeaders["referer"].flatMap(safeReferer)
        let origin = normalizedHeaders["origin"].flatMap(safeOrigin)
        let userAgent = normalizedHeaders["user-agent"]
        let authorization = normalizedHeaders["authorization"]

        return [
            "method": request.httpMethod ?? "GET",
            "body_available": String(body != nil || request.httpBodyStream != nil),
            "body_length": String(body?.count ?? -1),
            "body_sha256": body.map(sha256) ?? "unavailable",
            "referer_present": String(normalizedHeaders["referer"] != nil),
            "referer_sanitized": referer ?? "absent-or-unparseable",
            "origin_present": String(normalizedHeaders["origin"] != nil),
            "origin_sanitized": origin ?? "absent-or-unparseable",
            "user_agent_present": String(userAgent != nil),
            "user_agent_sha256": userAgent.map { sha256(Data($0.utf8)) } ?? "absent",
            "authorization_scheme": authorization.map { String($0.split(separator: " ").first ?? "unknown") } ?? "absent",
            "cookie_names": cookieNames.joined(separator: ","),
            "url_origin": request.url.flatMap { safeOrigin($0.absoluteString) } ?? "absent"
        ]
    }

    static func cookieNames(from header: String?) -> [String] {
        guard let header else { return [] }
        return header.split(separator: ";").compactMap { pair in
            let name = pair.split(separator: "=", maxSplits: 1).first.map(String.init)?.trimmingCharacters(in: .whitespaces)
            return name?.isEmpty == false ? name : nil
        }.sorted()
    }

    static func safeOrigin(_ value: String) -> String? {
        guard let url = URL(string: value),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host?.lowercased()
        else {
            return nil
        }
        let port = url.port ?? (scheme == "https" ? 443 : 80)
        let normalizedHost = host.hasSuffix(".") ? String(host.dropLast()) : host
        return "\(scheme)://\(normalizedHost):\(port)"
    }

    static func sanitizedIdentity(_ value: String) -> String {
        String(sha256(Data(value.utf8)).prefix(12))
    }

    private static func safeReferer(_ value: String) -> String? {
        guard let url = URL(string: value),
              let origin = safeOrigin(value)
        else {
            return nil
        }
        return "\(origin)\(url.path)"
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
