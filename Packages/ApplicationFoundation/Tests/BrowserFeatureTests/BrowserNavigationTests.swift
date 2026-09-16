//
//  BrowserNavigationTests.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
@testable import BrowserFeature

@Suite("Browser navigation resolution")
struct BrowserNavigationTests {
    @Test("Explicit HTTP and HTTPS destinations are preserved")
    func explicitWebURLs() throws {
        #expect(try BrowserNavigation.resolve("https://example.com/path?q=one") == .web(
            #require(URL(string: "https://example.com/path?q=one")),
        ))
        #expect(try BrowserNavigation.resolve("http://example.com") == .web(
            #require(URL(string: "http://example.com")),
        ))
    }

    @Test("Host-like input prefers HTTPS without an HTTP fallback")
    func inferredHTTPS() throws {
        #expect(try BrowserNavigation.resolve("example.com/docs") == .web(
            #require(URL(string: "https://example.com/docs")),
        ))
        #expect(try BrowserNavigation.resolve("localhost:8080") == .web(
            #require(URL(string: "https://localhost:8080")),
        ))
        #expect(try BrowserNavigation.resolve("127.0.0.1:3000") == .web(
            #require(URL(string: "https://127.0.0.1:3000")),
        ))
    }

    @Test("Ordinary text becomes a provider search")
    func searches() throws {
        #expect(try BrowserNavigation.resolve("private photo ideas", provider: .duckDuckGo) == .web(
            #require(URL(string: "https://duckduckgo.com/?q=private%20photo%20ideas")),
        ))
        #expect(try BrowserNavigation.resolve("private photo ideas", provider: .google) == .web(
            #require(URL(string: "https://www.google.com/search?q=private%20photo%20ideas")),
        ))
        #expect(try BrowserNavigation.resolve("private photo ideas", provider: .bing) == .web(
            #require(URL(string: "https://www.bing.com/search?q=private%20photo%20ideas")),
        ))
    }

    @Test("Unsupported schemes are routed or rejected at the correct seam")
    func unsupportedSchemes() throws {
        let mailtoURL = try #require(URL(string: "mailto:person@example.com"))
        #expect(BrowserNavigation.resolve("mailto:person@example.com") == .external(mailtoURL))
        #expect(BrowserNavigation.resolve("file:///tmp/private") == .rejectedScheme("file"))
        #expect(BrowserNavigation.resolve("data:text/plain,secret") == .rejectedScheme("data"))
        #expect(BrowserNavigation.resolve("javascript:alert(1)") == .rejectedScheme("javascript"))
    }

    @Test("Whitespace-only input is empty")
    func empty() {
        #expect(BrowserNavigation.resolve("  \n ") == .empty)
    }

    @Test("Bookmark validation shares browser web normalization")
    func bookmarkValidation() throws {
        #expect(try BrowserNavigation.bookmarkURL(" example.com ") == #require(URL(string: "https://example.com")))
        #expect(BrowserNavigation.bookmarkURL("mailto:person@example.com") == nil)
        #expect(BrowserNavigation.bookmarkURL("words to search") == nil)
    }
}
