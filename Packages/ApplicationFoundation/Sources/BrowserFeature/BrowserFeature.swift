//
//  BrowserFeature.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import ComposableArchitecture
import Foundation

/// Deterministic app-owned browser state and routing.
@Reducer
public struct BrowserFeature {
    /// App-visible browser state. Platform WebKit objects are intentionally excluded.
    @ObservableState
    public struct State: Equatable, Sendable {
        var tabs: [BrowserTab]
        var selectedTabID: BrowserTabID
        var presentation: BrowserPresentation
        var tabOverviewFocusID: BrowserTabID?
        var focusedField: BrowserFocusedField
        var omniboxDraft: String
        /// Distinguishes an intentionally empty edit from a draft that has never been edited.
        var hasUnsubmittedOmniboxDraft: Bool
        var bookmarks: [BrowserBookmark]
        var history: [BrowserHistoryEntry]
        var settings: BrowserSettings
        var suggestions: [BrowserSuggestion]
        var providerSuggestionValues: [String]
        var copiedLink: URL?
        var library: BrowserLibraryPresentation?
        var bookmarkEditor: BrowserBookmarkEditor?
        var findDraft: String?
        var backForwardList: BrowserBackForwardPresentation?
        var javaScriptDialogTabID: BrowserTabID?
        var tabPreviewData: [BrowserTabID: Data]
        var shareURL: URL?
        var shareTitle: String?
        var destructiveConfirmation: BrowserDestructiveConfirmation?

        /// Creates a fresh browser containing exactly one native Start Page tab.
        public init(initialTabID: BrowserTabID = .init()) {
            tabs = [.startPage(id: initialTabID)]
            selectedTabID = initialTabID
            presentation = .browsing
            tabOverviewFocusID = nil
            focusedField = .none
            omniboxDraft = ""
            hasUnsubmittedOmniboxDraft = false
            bookmarks = []
            history = []
            settings = .init()
            suggestions = []
            providerSuggestionValues = []
            copiedLink = nil
            library = nil
            bookmarkEditor = nil
            findDraft = nil
            backForwardList = nil
            javaScriptDialogTabID = nil
            tabPreviewData = [:]
            shareURL = nil
            shareTitle = nil
            destructiveConfirmation = nil
        }

        /// Creates deterministic state for restoration-free tests and previews.
        public init(
            tabs: [BrowserTab],
            selectedTabID: BrowserTabID,
            presentation: BrowserPresentation = .browsing,
            focusedField: BrowserFocusedField = .none,
            omniboxDraft: String = "",
        ) {
            precondition(!tabs.isEmpty, "Browser state must contain at least one logical tab")
            precondition(tabs.contains(where: { $0.id == selectedTabID }))
            self.tabs = tabs
            self.selectedTabID = selectedTabID
            self.presentation = presentation
            tabOverviewFocusID = nil
            self.focusedField = focusedField
            self.omniboxDraft = omniboxDraft
            hasUnsubmittedOmniboxDraft = false
            bookmarks = []
            history = []
            settings = .init()
            suggestions = []
            providerSuggestionValues = []
            copiedLink = nil
            library = nil
            bookmarkEditor = nil
            findDraft = nil
            backForwardList = nil
            javaScriptDialogTabID = nil
            tabPreviewData = [:]
            shareURL = nil
            shareTitle = nil
            destructiveConfirmation = nil
        }

        var selectedTab: BrowserTab? {
            tabs.first(where: { $0.id == selectedTabID })
        }

        var tabCountLabel: String {
            tabs.count > 99 ? "99+" : String(tabs.count)
        }

        /// Rebuilds transient suggestions only while an omnibox field owns focus.
        mutating func rebuildSuggestions() {
            guard focusedField != .none else {
                providerSuggestionValues = []
                suggestions = []
                return
            }

            suggestions = BrowserSuggestions.complete(
                draft: omniboxDraft,
                provider: settings.searchProvider,
                bookmarks: bookmarks,
                history: history,
                providerValues: providerSuggestionValues,
            )
            if omniboxDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let copiedLink {
                suggestions.insert(.init(
                    id: "copied:\(copiedLink.absoluteString)",
                    title: "Open Copied Link",
                    subtitle: BrowserSuggestions.copiedLinkPreview(copiedLink),
                    kind: .copiedLink(copiedLink),
                ), at: 0)
            }
        }
    }

    /// User, dependency, and adapter events understood by the browser reducer.
    public enum Action: Equatable, Sendable {
        /// Starts adapter observation and loads settings/library seam values.
        case task
        /// Creates and selects a new native Start Page tab.
        case newTabTapped
        /// Requests confirmation before closing every tab.
        case closeAllTapped
        /// Performs a previously confirmed close-all operation.
        case closeAllConfirmed
        /// Selects an existing Start Page or creates one.
        case showStartPageTapped
        /// Presents the app-owned tab overview.
        case showTabOverviewTapped
        /// Records the deterministic accessibility focus target selected by Tab Overview.
        case tabOverviewFocusChanged(BrowserTabID?)
        /// Resigns transient Browser presentation state when the authenticated shell leaves Browser.
        case topLevelDeselected
        /// Requests presentation of the authenticated shell's Settings flow.
        case settingsTapped
        /// Focuses the appropriate omnibox and performs an approved clipboard check.
        case omniboxFocused
        /// Reconciles reducer state after the UI loses omnibox focus externally.
        case omniboxFocusLost
        /// Resolves and submits the current omnibox draft.
        case omniboxSubmitted
        /// Requests WebKit back navigation for the selected tab.
        case backTapped
        /// Requests WebKit forward navigation for the selected tab.
        case forwardTapped
        /// Routes to reload or stop according to live metadata.
        case reloadOrStopTapped
        /// Routes a page pull gesture to retry or reload.
        case pullToRefresh
        /// Retries the selected recoverable page state.
        case retryTapped
        /// Requests projected back-list entries from WebKit.
        case backHistoryRequested
        /// Requests projected forward-list entries from WebKit.
        case forwardHistoryRequested
        /// Navigates to a projected back-forward entry.
        case backForwardEntrySelected(BrowserBackForwardEntry.Token)
        /// Dismisses the projected back-forward list.
        case backForwardListDismissed
        /// Selects a tab by stable identity.
        case selectTab(BrowserTabID)
        /// Closes a tab by stable identity.
        case closeTab(BrowserTabID)
        /// Requests confirmation before closing every other tab.
        case closeOtherTabsTapped(BrowserTabID)
        /// Performs a previously confirmed close-other-tabs operation.
        case closeOtherTabsConfirmed(BrowserTabID)
        /// Selects a card and exits tab overview.
        case tabCardSelected(BrowserTabID)
        /// Replaces the transient omnibox draft.
        case omniboxChanged(String)
        /// Delivers provider suggestions for the draft and provider that initiated the request.
        case providerSuggestionsResponse(
            draft: String,
            provider: BrowserSearchProvider,
            Result<[String], BrowserProviderSuggestionError>,
        )
        /// Delivers an approved clipboard read.
        case clipboardChecked(URL?)
        /// Changes copied-link suggestion privacy behavior.
        case copiedLinkSuggestionsChanged(Bool)
        /// Presents the Browser Library at a requested section.
        case libraryPresented(BrowserLibrarySection)
        /// Dismisses Browser Library transient state.
        case libraryDismissed
        /// Changes local Browser Library search text.
        case librarySearchChanged(BrowserLibrarySection, String)
        /// Updates the transient scroll anchor for one Browser Library section.
        case libraryScrollChanged(BrowserLibrarySection, UUID?)
        /// Reveals a bookmark with its stable identity.
        case viewBookmark(UUID)
        /// Clears the one-shot exact-bookmark reveal target after the view scrolls to it.
        case bookmarkRevealConsumed
        /// Presents an editor for the selected page.
        case addBookmarkTapped
        /// Presents an editor for a targeted committed tab without activating it.
        case addBookmarkForTab(BrowserTabID)
        /// Presents an editor for an existing bookmark.
        case editBookmarkTapped(UUID)
        /// Changes transient bookmark editor fields.
        case bookmarkEditorChanged(title: String, url: String)
        /// Discards the transient bookmark editor.
        case bookmarkEditorCancelled
        /// Validates and saves the transient bookmark editor.
        case bookmarkEditorSaved
        /// Deletes one bookmark through the injectable backing seam.
        case deleteBookmark(UUID)
        /// Deletes one durable History entry through the injectable backing seam.
        case deleteHistoryEntry(UUID)
        /// Copies a targeted tab's committed HTTP(S) URL without activating it.
        case copyURL(BrowserTabID)
        /// Requests the shared clear-History confirmation.
        case clearHistoryTapped(source: BrowserClearHistorySource)
        /// Clears a pending destructive confirmation dismissed without confirming.
        case destructiveConfirmationDismissed
        /// Requests the delete-all-bookmarks confirmation.
        case deleteAllBookmarksTapped
        /// Performs the pending destructive operation.
        case destructiveActionConfirmed
        /// Installs loaded browser settings and library values.
        case loaded(settings: BrowserSettings, bookmarks: [BrowserBookmark], history: [BrowserHistoryEntry])
        /// Navigates the selected logical tab to a normalized URL.
        case navigate(URL)
        /// Creates and loads a related tab beside its opener.
        case openInNewTab(URL, openerID: BrowserTabID?)
        /// Changes and persists the selected search provider.
        case searchProviderChanged(BrowserSearchProvider)
        /// Changes and persists provider-suggestion consent.
        case providerSuggestionsChanged(Bool)
        /// Changes and persists foreground/background related-tab behavior.
        case openLinkPreferenceChanged(BrowserOpenLinkPreference)
        /// Restores all Issue #37 settings defaults.
        case resetSettings
        /// Presents the app-owned Find on Page input.
        case findPresented
        /// Changes Find on Page text and routes it to WebKit.
        case findChanged(String)
        /// Dismisses Find on Page and clears WebKit highlighting.
        case findDismissed
        /// Dismisses the app-owned system share sheet.
        case shareDismissed
        /// Delivers a Sendable event projected by the WebKit adapter.
        case webKitEvent(BrowserWebKitEvent)
    }

    @Dependency(\.browserWebKit)
    var webKit
    @Dependency(\.uuid)
    var uuid
    @Dependency(\.continuousClock)
    var clock
    @Dependency(\.date.now)
    var now
    @Dependency(\.browserProviderSuggestions)
    var providerSuggestions
    @Dependency(\.browserClipboard)
    var clipboard
    @Dependency(\.browserExternalNavigation)
    var externalNavigation
    @Dependency(\.browserLibrary)
    var browserLibrary
    @Dependency(\.browserSettings)
    var browserSettings

    enum CancelID { case providerSuggestions }

    /// Creates the browser reducer.
    public init() {}

    /// Composes browser state transitions and dependency effects.
    public var body: some ReducerOf<Self> {
        Reduce { state, action in coreReduce(into: &state, action: action) }
    }
}
