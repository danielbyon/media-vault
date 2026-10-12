import Foundation
import WebKit

/// Cookie bridging between the exact WebKit data store assigned to the
/// experimental page and an app-owned transfer request.
///
/// Only cookies that satisfy RFC 6265 scope rules for the destination URL are
/// attached, so a transfer can never send a cookie that the browser itself
/// would not have sent. Values are never logged; only names, counts, and
/// hashes reach the evidence log.
@MainActor
enum SpikeCookieBridge {
    /// One cookie scope decision, recorded for evidence.
    struct ScopeDecision: Sendable {
        let name: String
        let included: Bool
        let reason: String
    }

    /// Cookies the page's own store holds for one URL.
    static func cookies(in dataStore: WKWebsiteDataStore, for url: URL) async -> [HTTPCookie] {
        await dataStore.httpCookieStore.cookies(for: url)
    }

    /// Every cookie the page's own store holds.
    static func allCookies(in dataStore: WKWebsiteDataStore) async -> [HTTPCookie] {
        await dataStore.httpCookieStore.allCookies()
    }

    /// Apply RFC 6265 scope rules and report one decision per cookie.
    static func scope(_ cookies: [HTTPCookie], for url: URL) -> (included: [HTTPCookie], decisions: [ScopeDecision]) {
        var included: [HTTPCookie] = []
        var decisions: [ScopeDecision] = []
        for cookie in cookies {
            if let reason = exclusionReason(for: cookie, url: url) {
                decisions.append(ScopeDecision(name: cookie.name, included: false, reason: reason))
            } else {
                included.append(cookie)
                decisions.append(ScopeDecision(name: cookie.name, included: true, reason: "in-scope"))
            }
        }
        return (included, decisions)
    }

    /// Build a single Cookie header value from in-scope cookies.
    static func headerValue(_ cookies: [HTTPCookie]) -> String? {
        guard !cookies.isEmpty else { return nil }
        return cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }

    /// Redacted description of cookie names only.
    static func names(_ cookies: [HTTPCookie]) -> String {
        cookies.map(\.name).sorted().joined(separator: ",")
    }

    /// Reason a cookie is out of scope for a URL, or nil when it is in scope.
    static func exclusionReason(for cookie: HTTPCookie, url: URL) -> String? {
        guard let host = url.host?.lowercased() else { return "no-host" }
        let domain = cookie.domain.lowercased()
        if domain.hasPrefix(".") {
            let bareDomain = String(domain.dropFirst())
            guard host == bareDomain || host.hasSuffix(".\(bareDomain)") else { return "domain-mismatch" }
        } else {
            guard host == domain else { return "domain-mismatch" }
        }
        guard pathMatches(cookiePath: cookie.path, requestPath: url.path) else { return "path-mismatch" }
        if cookie.isSecure, url.scheme?.lowercased() != "https" { return "secure-requires-https" }
        if let expires = cookie.expiresDate, expires <= Date() { return "expired" }
        if cookie.value.isEmpty { return "empty-value" }
        return nil
    }

    /// RFC 6265 path-match rule.
    static func pathMatches(cookiePath: String, requestPath: String) -> Bool {
        let path = cookiePath.isEmpty ? "/" : cookiePath
        let request = requestPath.isEmpty ? "/" : requestPath
        if path == request { return true }
        guard request.hasPrefix(path) else { return false }
        if path.hasSuffix("/") { return true }
        return request.dropFirst(path.count).first == "/"
    }

    /// Inject deliberately out-of-scope markers into the page's own store so
    /// the bridge filter is exercised even when a browser would refuse to keep
    /// such cookies. Returns the marker names that the store accepted.
    static func injectOutOfScopeMarkers(in dataStore: WKWebsiteDataStore, url: URL) async -> [String] {
        var injected: [String] = []
        for marker in SpikeContract.ScopeMarker.allCases {
            guard let cookie = markerCookie(marker, url: url) else { continue }
            await dataStore.httpCookieStore.setCookie(cookie)
            injected.append(marker.rawValue)
        }
        return injected
    }

    private static func markerCookie(_ marker: SpikeContract.ScopeMarker, url: URL) -> HTTPCookie? {
        var properties: [HTTPCookiePropertyKey: Any] = [
            .name: marker.rawValue,
            .value: marker.value,
            .domain: url.host ?? SpikeContract.primaryHost,
            .originURL: url,
        ]
        switch marker {
        case .path:
            properties[.path] = "/scoped"
        case .secure:
            properties[.path] = "/"
            properties[.secure] = "TRUE"
        case .otherHost:
            properties[.domain] = SpikeContract.secondaryHost
            properties[.path] = "/"
        case .expired:
            properties[.path] = "/"
            properties[.expires] = Date().addingTimeInterval(-3_600)
        }
        return HTTPCookie(properties: properties)
    }
}

/// Redaction helpers shared by the experiment host.
enum SpikeRedaction {
    /// Scheme, host, and path only, so signed query values never reach logs.
    static func urlHostPath(_ url: URL?) -> String {
        guard let url else { return "none" }
        return "\(url.scheme ?? "")://\(url.host ?? "")\(url.path)"
    }

    /// Query key names only, so token values never reach logs.
    static func queryKeys(_ url: URL?) -> String {
        guard let url, let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return "" }
        let names = (components.queryItems ?? []).map(\.name).sorted()
        return names.joined(separator: ",")
    }
}
