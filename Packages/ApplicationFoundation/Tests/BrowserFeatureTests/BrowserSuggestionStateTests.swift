//
//  BrowserSuggestionStateTests.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Clocks
import ComposableArchitecture
import Foundation
import Testing
@testable import BrowserFeature

@Suite("Browser suggestion state machine")
@MainActor
struct BrowserSuggestionStateTests {
    @Test("Provider requests require two characters and deterministic debounce")
    func providerThresholdAndDebounce() async {
        let clock = TestClock()
        let requests = LockIsolated<[String]>([])
        var state = BrowserFeature.State(initialTabID: BrowserTabID())
        state.settings.providerSuggestionsEnabled = true
        let store = TestStore(initialState: state) { BrowserFeature() } withDependencies: {
            $0.continuousClock = clock
            $0.browserProviderSuggestions.fetch = { query, _ in
                requests.withValue { $0.append(query) }
                return [query + " remote"]
            }
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.omniboxChanged("a"))
        await clock.advance(by: .seconds(1))
        #expect(requests.value.isEmpty)

        await store.send(.omniboxChanged("ab"))
        await clock.advance(by: .milliseconds(249))
        #expect(requests.value.isEmpty)
        await clock.advance(by: .milliseconds(1))
        await store.receive(.providerSuggestionsResponse(
            draft: "ab",
            provider: .duckDuckGo,
            .success(["ab remote"]),
        ))
        #expect(requests.value == ["ab"])
        #expect(store.state.suggestions.contains(where: { $0.kind == .provider("ab remote") }))
    }

    @Test("Stale and failed provider responses leave current local suggestions intact")
    func staleAndFailure() async throws {
        var state = BrowserFeature.State(initialTabID: BrowserTabID())
        state.settings.providerSuggestionsEnabled = true
        state.omniboxDraft = "current"
        state.bookmarks = try [BrowserBookmark(
            id: UUID(),
            title: "Current",
            url: #require(URL(string: "https://current.example")),
            siblingOrder: 0,
        )]
        state.rebuildSuggestions()
        let expected = state.suggestions
        let store = TestStore(initialState: state) { BrowserFeature() }

        await store.send(.providerSuggestionsResponse(
            draft: "old",
            provider: .duckDuckGo,
            .success(["old remote"]),
        ))
        #expect(store.state.suggestions == expected)
        await store.send(.providerSuggestionsResponse(
            draft: "current",
            provider: .duckDuckGo,
            .failure(.unavailable),
        ))
        #expect(store.state.suggestions == expected)
    }

    @Test("Disabling suggestions and changing provider reject in-flight responses")
    func consentAndProviderCancellation() async {
        var state = BrowserFeature.State(initialTabID: BrowserTabID())
        state.settings.providerSuggestionsEnabled = true
        state.omniboxDraft = "private"
        state.rebuildSuggestions()
        let expected = state.suggestions
        let store = TestStore(initialState: state) { BrowserFeature() }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.providerSuggestionsChanged(false))
        await store.send(.providerSuggestionsResponse(
            draft: "private",
            provider: .duckDuckGo,
            .success(["should not appear"]),
        ))
        #expect(store.state.suggestions == expected)

        await store.send(.providerSuggestionsChanged(true))
        await store.send(.searchProviderChanged(.google))
        await store.send(.providerSuggestionsResponse(
            draft: "private",
            provider: .duckDuckGo,
            .success(["stale provider"]),
        ))
        #expect(store.state.suggestions.contains(where: { $0.kind == .provider("stale provider") }) == false)
    }

    @Test("Reset settings clears provider results before rebuilding transient suggestions")
    func resetSettingsClearsProviderResults() async {
        var state = BrowserFeature.State(initialTabID: BrowserTabID())
        state.settings.providerSuggestionsEnabled = true
        state.omniboxDraft = "private"
        state.providerSuggestionValues = ["private remote"]
        state.rebuildSuggestions()
        let store = TestStore(initialState: state) { BrowserFeature() }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.resetSettings)
        await store.send(.providerSuggestionsResponse(
            draft: "private",
            provider: .duckDuckGo,
            .success(["stale after reset"]),
        ))

        #expect(store.state.settings == .init())
        #expect(store.state.providerSuggestionValues.isEmpty)
        #expect(store.state.suggestions.contains(where: { $0.kind == .provider("stale after reset") }) == false)
    }

    @Test("Clipboard is read only at approved interactions and never when disabled")
    func clipboardPrivacy() async throws {
        let reads = LockIsolated(0)
        let copied = try #require(URL(string: "https://copied.example/private?token=secret"))
        let store = TestStore(initialState: BrowserFeature.State(initialTabID: BrowserTabID())) {
            BrowserFeature()
        } withDependencies: {
            $0.uuid = .incrementing
            $0.browserClipboard.readHTTPURL = {
                reads.withValue { $0 += 1 }
                return copied
            }
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.omniboxFocused)
        await store.receive(.clipboardChecked(copied))
        #expect(reads.value == 1)
        #expect(store.state.copiedLink == copied)

        await store.send(.copiedLinkSuggestionsChanged(false))
        await store.send(.newTabTapped)
        #expect(reads.value == 1)
    }

    @Test("Empty submission retains focus and never creates history")
    func emptySubmit() async {
        var state = BrowserFeature.State(initialTabID: BrowserTabID())
        state.focusedField = .startPage
        let store = TestStore(initialState: state) { BrowserFeature() }
        await store.send(.omniboxSubmitted)
        #expect(store.state.focusedField == .startPage)
        #expect(store.state.history.isEmpty)
    }
}
