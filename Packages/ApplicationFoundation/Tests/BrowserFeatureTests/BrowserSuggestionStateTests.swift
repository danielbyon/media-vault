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
        var state = BrowserFeature.State.readyForTesting(initialTabID: BrowserTabID())
        state.focusedField = .startPage
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
        var state = BrowserFeature.State.readyForTesting(initialTabID: BrowserTabID())
        state.focusedField = .startPage
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

    @Test("Late provider and clipboard completions cannot reactivate unfocused suggestions")
    func lateResultsAreIgnoredWhenUnfocused() async throws {
        let bookmarkURL = try #require(URL(string: "https://current.example"))
        let copiedURL = try #require(URL(string: "https://copied.example"))
        var state = BrowserFeature.State.readyForTesting(initialTabID: BrowserTabID())
        state.settings.providerSuggestionsEnabled = true
        state.omniboxDraft = "current"
        state.bookmarks = [BrowserBookmark(
            id: UUID(),
            title: "Current",
            url: bookmarkURL,
            siblingOrder: 0,
        )]
        state.rebuildSuggestions()
        #expect(state.suggestions.isEmpty)
        let store = TestStore(initialState: state) { BrowserFeature() }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.providerSuggestionsResponse(
            draft: "current",
            provider: .duckDuckGo,
            .success(["late remote"]),
        ))
        await store.send(.clipboardChecked(copiedURL))

        #expect(store.state.providerSuggestionValues.isEmpty)
        #expect(store.state.copiedLink == nil)
        #expect(store.state.suggestions.isEmpty)
    }

    @Test("External focus loss clears transient suggestions and cancels provider work")
    func externalFocusLossCancelsProviderWork() async {
        let clock = TestClock()
        let requests = LockIsolated<[String]>([])
        var state = BrowserFeature.State.readyForTesting(initialTabID: BrowserTabID())
        state.focusedField = .startPage
        state.settings.providerSuggestionsEnabled = true
        let store = TestStore(initialState: state) { BrowserFeature() } withDependencies: {
            $0.continuousClock = clock
            $0.browserProviderSuggestions.fetch = { query, _ in
                requests.withValue { $0.append(query) }
                return [query + " remote"]
            }
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.omniboxChanged("cu"))
        await store.send(.omniboxFocusLost)
        await clock.advance(by: .seconds(1))
        await store.send(.providerSuggestionsResponse(
            draft: "cu",
            provider: .duckDuckGo,
            .success(["late remote"]),
        ))

        #expect(requests.value.isEmpty)
        #expect(store.state.focusedField == .none)
        #expect(store.state.suggestions.isEmpty)
        #expect(store.state.providerSuggestionValues.isEmpty)
    }

    @Test("Unfocused omnibox edits preserve the draft without rebuilding or requesting suggestions")
    func unfocusedEditDoesNotStartSuggestions() async {
        let clock = TestClock()
        let requests = LockIsolated<[String]>([])
        var state = BrowserFeature.State.readyForTesting(initialTabID: BrowserTabID())
        state.settings.copiedLinkSuggestionsEnabled = false
        state.settings.providerSuggestionsEnabled = true
        let store = TestStore(initialState: state) { BrowserFeature() } withDependencies: {
            $0.continuousClock = clock
            $0.browserProviderSuggestions.fetch = { query, _ in
                requests.withValue { $0.append(query) }
                return [query + " remote"]
            }
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.omniboxFocused)
        await store.send(.omniboxChanged("ab"))
        await store.send(.omniboxFocusLost)
        await store.send(.omniboxChanged("abc"))
        await clock.advance(by: .seconds(1))

        #expect(store.state.omniboxDraft == "abc")
        #expect(store.state.hasUnsubmittedOmniboxDraft)
        #expect(store.state.focusedField == .none)
        #expect(store.state.suggestions.isEmpty)
        #expect(store.state.providerSuggestionValues.isEmpty)
        #expect(requests.value.isEmpty)
    }

    @Test("Top-level Browser deselection reconciles transient omnibox state")
    func topLevelDeselectionCancelsProviderWork() async throws {
        let clock = TestClock()
        let requests = LockIsolated<[String]>([])
        let copiedURL = try #require(URL(string: "https://copied.example"))
        var state = BrowserFeature.State.readyForTesting(initialTabID: BrowserTabID())
        state.focusedField = .startPage
        state.settings.providerSuggestionsEnabled = true
        state.copiedLink = copiedURL
        let store = TestStore(initialState: state) { BrowserFeature() } withDependencies: {
            $0.continuousClock = clock
            $0.browserProviderSuggestions.fetch = { query, _ in
                requests.withValue { $0.append(query) }
                return [query + " remote"]
            }
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.omniboxChanged("cu"))
        await store.send(.topLevelDeselected)
        await clock.advance(by: .seconds(1))

        #expect(requests.value.isEmpty)
        #expect(store.state.focusedField == .none)
        #expect(store.state.copiedLink == nil)
        #expect(store.state.suggestions.isEmpty)
        #expect(store.state.omniboxDraft == "cu")
    }

    @Test("An edited omnibox draft survives dismissal and focus reacquisition")
    func editedDraftSurvivesFocusLossAndReacquisition() async throws {
        let url = try #require(URL(string: "https://committed.example"))
        let editedDraft = "edited.example/path"
        var webTab = BrowserTab.web(id: BrowserTabID(), url: url)
        webTab.metadata.committedURL = url
        let store = TestStore(initialState: BrowserFeature.State.readyForTesting(
            tabs: [webTab],
            selectedTabID: webTab.id,
        )) {
            BrowserFeature()
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.omniboxFocused)
        #expect(store.state.focusedField == .chrome)
        #expect(store.state.omniboxDraft == url.absoluteString)
        await store.send(.omniboxChanged(editedDraft))
        await store.send(.omniboxFocusLost)
        #expect(store.state.focusedField == .none)
        #expect(store.state.omniboxDraft == editedDraft)
        await store.send(.omniboxFocused)
        #expect(store.state.focusedField == .chrome)
        #expect(store.state.omniboxDraft == editedDraft)
    }

    @Test("Start Page rebuilds local suggestions on refocus without clipboard suggestions")
    func startPageSuggestionsRebuildOnRefocus() async throws {
        let bookmarkID = UUID()
        let bookmarkURL = try #require(URL(string: "https://example.com"))
        var state = BrowserFeature.State.readyForTesting(initialTabID: BrowserTabID())
        state.focusedField = .startPage
        state.settings.copiedLinkSuggestionsEnabled = false
        state.bookmarks = [BrowserBookmark(
            id: bookmarkID,
            title: "Example",
            url: bookmarkURL,
            siblingOrder: 0,
        )]
        let store = TestStore(initialState: state) { BrowserFeature() }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.omniboxChanged("example"))
        await store.send(.omniboxFocusLost)
        await store.send(.omniboxFocused)

        #expect(store.state.focusedField == .startPage)
        #expect(store.state.suggestions.contains { $0.kind == .bookmark(bookmarkID) })
    }

    @Test("Disabling suggestions and changing provider reject in-flight responses")
    func consentAndProviderCancellation() async {
        var state = BrowserFeature.State.readyForTesting(initialTabID: BrowserTabID())
        state.focusedField = .startPage
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
        var state = BrowserFeature.State.readyForTesting(initialTabID: BrowserTabID())
        state.profileLifecycle = .ready
        state.focusedField = .startPage
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
        let store = TestStore(initialState: BrowserFeature.State.readyForTesting(initialTabID: BrowserTabID())) {
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
        var state = BrowserFeature.State.readyForTesting(initialTabID: BrowserTabID())
        state.focusedField = .startPage
        let store = TestStore(initialState: state) { BrowserFeature() }
        await store.send(.omniboxSubmitted)
        #expect(store.state.focusedField == .startPage)
        #expect(store.state.history.isEmpty)
    }
}
