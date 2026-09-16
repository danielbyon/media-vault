//
//  BrowserProviderSuggestionClient.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import ComposableArchitecture
import Foundation

/// Stable failure reported by the optional provider-suggestion boundary.
public enum BrowserProviderSuggestionError: Error, Equatable, Sendable {
    /// Suggestions could not be loaded; local results remain usable.
    case unavailable
}

/// Optional network autocomplete boundary. Calls occur only after the reducer's opt-in gate.
struct BrowserProviderSuggestionClient: Sendable {
    var fetch: @Sendable (String, BrowserSearchProvider) async throws -> [String]
}

extension BrowserProviderSuggestionClient: DependencyKey {
    static let liveValue = Self(fetch: { query, provider in
        let url = BrowserProviderEndpoints.url(query: query, provider: provider)
        let (data, _) = try await URLSession.shared.data(from: url)
        return BrowserProviderEndpoints.values(data: data)
    })
    static let testValue = Self(fetch: { _, _ in [] })
}

extension DependencyValues {
    /// Reducer-facing optional provider autocomplete dependency.
    var browserProviderSuggestions: BrowserProviderSuggestionClient {
        get { self[BrowserProviderSuggestionClient.self] }
        set { self[BrowserProviderSuggestionClient.self] = newValue }
    }
}

/// Provider-specific endpoint construction and response parsing.
private enum BrowserProviderEndpoints {
    static func url(query: String, provider: BrowserSearchProvider) -> URL {
        var components = URLComponents()
        components.scheme = "https"
        switch provider {
        case .duckDuckGo:
            components.host = "duckduckgo.com"
            components.path = "/ac/"
        case .google:
            components.host = "suggestqueries.google.com"
            components.path = "/complete/search"
        case .bing:
            components.host = "api.bing.com"
            components.path = "/osjson.aspx"
        }
        components.queryItems = provider == .bing
            ? [URLQueryItem(name: "query", value: query)]
            : [URLQueryItem(
                name: provider == .google ? "client" : "type",
                value: provider == .google
                    ? "firefox"
                    : "list",
            ), URLQueryItem(name: "q", value: query)]
        guard let url = components.url else {
            preconditionFailure("Static suggestion-provider URL components must form a URL")
        }

        return url
    }

    static func values(data: Data) -> [String] {
        guard let json = try? JSONSerialization.jsonObject(with: data) else {
            return []
        }

        if let array = json as? [Any], array.count > 1, let values = array[1] as? [String] {
            return values
        }
        if let rows = json as? [[String: Any]] {
            return rows.compactMap { $0["phrase"] as? String }
        }
        return []
    }
}
