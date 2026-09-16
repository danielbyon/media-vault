//
//  BrowserNavigation.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Dependencies
import Foundation

/// A user-selectable provider used only when omnibox input is classified as a search.
public enum BrowserSearchProvider: String, CaseIterable, Equatable, Sendable {
    /// DuckDuckGo search, the privacy-oriented default.
    case duckDuckGo

    /// Google Search.
    case google

    /// Microsoft Bing search.
    case bing

    /// The localized provider name used by browser UI.
    public var displayName: String {
        switch self {
        case .duckDuckGo:
            "DuckDuckGo"
        case .google:
            "Google"
        case .bing:
            "Bing"
        }
    }
}

/// The deterministic app-owned result of classifying omnibox text.
public enum BrowserNavigationResolution: Equatable, Sendable {
    /// No destination was supplied.
    case empty

    /// A supported HTTP(S) destination should be loaded by WebKit.
    case web(URL)

    /// A non-web destination should be handed to the navigation-safety boundary owned by Issue #41.
    case external(URL)

    /// An app-local or script scheme is not valid top-level browser navigation.
    case rejectedScheme(String)
}

/// Pure omnibox parsing and bookmark URL validation.
public enum BrowserNavigation {
    private static let rejectedSchemes: Set = [
        "about",
        "blob",
        "data",
        "file",
        "javascript",
    ]

    /// Resolves text to a supported web URL, external-scheme seam, or rejection.
    ///
    /// Host-like input receives an HTTPS scheme. This function intentionally has no HTTP retry
    /// behavior; transport failures are reported by the WebKit adapter without weakening the
    /// selected transport.
    public static func resolve(
        _ input: String,
        provider: BrowserSearchProvider = .duckDuckGo,
    ) -> BrowserNavigationResolution {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            return .empty
        }

        if let scheme = explicitScheme(in: text) {
            if scheme == "http" || scheme == "https" {
                guard let url = normalizedWebURL(text) else {
                    return .rejectedScheme(scheme)
                }

                return .web(url)
            }
            if rejectedSchemes.contains(scheme) {
                return .rejectedScheme(scheme)
            }
            guard let url = URL(string: text), url.scheme?.lowercased() == scheme else {
                return .rejectedScheme(scheme)
            }

            return .external(url)
        }

        if isHostLike(text), let url = normalizedWebURL("https://\(text)") {
            return .web(url)
        }

        return .web(searchURL(for: text, provider: provider))
    }

    /// Returns a normalized HTTP(S) bookmark destination, or `nil` for search text and schemes
    /// that cannot be saved as browser bookmarks.
    public static func bookmarkURL(_ input: String) -> URL? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            return nil
        }

        if let scheme = explicitScheme(in: text) {
            guard scheme == "http" || scheme == "https" else {
                return nil
            }

            return normalizedWebURL(text)
        }

        guard isHostLike(text) else {
            return nil
        }

        return normalizedWebURL("https://\(text)")
    }

    /// Returns whether a URL is an HTTP(S) page eligible for page-specific actions.
    public static func isHTTPURL(_ url: URL) -> Bool {
        let scheme = url.scheme?.lowercased()
        return scheme == "http" || scheme == "https"
    }

    /// Builds the provider's ordinary HTTPS search URL.
    public static func searchURL(for query: String, provider: BrowserSearchProvider) -> URL {
        var components = URLComponents()
        components.scheme = "https"
        switch provider {
        case .duckDuckGo:
            components.host = "duckduckgo.com"
            components.path = "/"
        case .google:
            components.host = "www.google.com"
            components.path = "/search"
        case .bing:
            components.host = "www.bing.com"
            components.path = "/search"
        }
        components.queryItems = [URLQueryItem(name: "q", value: query)]
        guard let url = components.url else {
            preconditionFailure("Static search-provider URL components must form a URL")
        }

        return url
    }

    private static func explicitScheme(in text: String) -> String? {
        guard let separator = text.firstIndex(of: ":") else {
            return nil
        }

        let candidate = String(text[..<separator]).lowercased()
        let remainder = text[text.index(after: separator)...]
        if candidate == "localhost", remainder.first?.isNumber == true {
            return nil
        }
        guard !candidate.isEmpty,
              candidate.first?.isLetter == true,
              candidate.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "+" || $0 == "-" || $0 == "." })
        else {
            return nil
        }

        return candidate
    }

    private static func isHostLike(_ text: String) -> Bool {
        guard !text.contains(where: \.isWhitespace) else {
            return false
        }
        guard let components = URLComponents(string: "https://\(text)"),
              let host = components.host?.lowercased(),
              !host.isEmpty
        else {
            return false
        }

        if host == "localhost" || host.contains(".") {
            return true
        }
        return host.contains(":")
    }

    private static func normalizedWebURL(_ text: String) -> URL? {
        guard let components = URLComponents(string: text),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              components.host?.isEmpty == false
        else {
            return nil
        }

        return components.url
    }
}

/// Injectable handoff boundary for external and custom-scheme navigation owned by Issue #41.
struct BrowserExternalNavigationClient: Sendable {
    var open: @Sendable (URL) async -> Void
}

extension BrowserExternalNavigationClient: DependencyKey {
    /// Issue #41 supplies confirmation and the eventual external-app handoff.
    ///
    /// Until that boundary is composed, Issue #37 fails safely and does not escape the app.
    static let liveValue = Self(open: { _ in })
    static let testValue = Self(open: { _ in })
}

extension DependencyValues {
    var browserExternalNavigation: BrowserExternalNavigationClient {
        get { self[BrowserExternalNavigationClient.self] }
        set { self[BrowserExternalNavigationClient.self] = newValue }
    }
}
