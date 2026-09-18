//
//  BrowserFeature+Reducer.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import ComposableArchitecture
import Foundation

extension BrowserFeature {
    // swiftlint:disable:next cyclomatic_complexity function_body_length
    func coreReduce(into state: inout State, action: Action) -> Effect<Action> {
        switch action {
        case .task:
            let events = webKit.events
            let loadSettings = browserSettings.load
            let loadBookmarks = browserLibrary.loadBookmarks
            let loadHistory = browserLibrary.loadHistory
            return .merge(
                .run { send in for await event in await events() {
                    await send(.webKitEvent(event))
                } },
                .run { send in
                    async let settings = loadSettings()
                    async let bookmarks = (try? loadBookmarks()) ?? []
                    async let history = (try? loadHistory()) ?? []
                    await send(.loaded(
                        settings: settings,
                        bookmarks: bookmarks,
                        history: history,
                    ))
                },
            )
        case .newTabTapped:
            let dismissalEffect = dismissPageUI(in: &state)
            let id = BrowserTabID(uuid())
            state.tabs.append(.startPage(id: id))
            state.selectedTabID = id
            state.presentation = .browsing
            state.tabOverviewFocusID = nil
            state.focusedField = .startPage
            state.omniboxDraft = ""
            state.hasUnsubmittedOmniboxDraft = false
            state.providerSuggestionValues = []
            state.rebuildSuggestions()
            return .merge(dismissalEffect, checkClipboardIfAllowed(state: state))
        case let .selectTab(id):
            guard state.library == nil,
                  state.tabs.contains(where: { $0.id == id })
            else {
                return .none
            }

            let dismissalEffect = dismissPageUI(in: &state)
            state.selectedTabID = id
            state.presentation = .browsing
            state.tabOverviewFocusID = nil
            discardDraft(in: &state)
            return dismissalEffect
        case let .closeTab(id):
            return close(tabID: id, state: &state)
        case .closeAllTapped:
            let meaningfulCount = state.tabs.count(where: { !$0.isStartPage })
            if meaningfulCount > 1 {
                state.destructiveConfirmation = .closeAllTabs(count: state.tabs.count)
                state.pendingNewTab = nil
            } else {
                return .send(.closeAllConfirmed)
            }
        case .closeAllConfirmed:
            state.pendingNewTab = nil
            let dismissalEffect = dismissPageUI(in: &state)
            let closedIDs = state.tabs.map(\.id)
            let id = BrowserTabID(uuid())
            state.tabs = [.startPage(id: id)]
            state.selectedTabID = id
            state.presentation = .browsing
            state.tabOverviewFocusID = nil
            discardDraft(in: &state)
            return .merge(dismissalEffect, commands(closedIDs.map { .destroyContext(tabID: $0) }))
        case let .closeOtherTabsTapped(id):
            guard state.tabs.contains(where: { $0.id == id }) else {
                return .none
            }

            let otherTabs = state.tabs.filter { $0.id != id }
            let meaningfulCount = otherTabs.count(where: { !$0.isStartPage })
            if meaningfulCount >= 2 {
                state.destructiveConfirmation = .closeOtherTabs(keeping: id, count: otherTabs.count)
                state.pendingNewTab = nil
            } else {
                return .send(.closeOtherTabsConfirmed(id))
            }
        case let .closeOtherTabsConfirmed(id):
            guard let tab = state.tabs.first(where: { $0.id == id }) else {
                return .none
            }

            state.pendingNewTab = nil
            let dismissalEffect = dismissPageUI(in: &state)
            let closedIDs = state.tabs.filter { $0.id != id }.map(\.id)
            state.tabs = [tab]
            state.selectedTabID = id
            state.presentation = .browsing
            state.tabOverviewFocusID = nil
            discardDraft(in: &state)
            return .merge(dismissalEffect, commands(closedIDs.map { .destroyContext(tabID: $0) }))
        case .showStartPageTapped:
            let dismissalEffect = dismissPageUI(in: &state)
            if let existing = state.tabs.first(where: \.isStartPage) {
                state.selectedTabID = existing.id
                state.presentation = .browsing
                state.tabOverviewFocusID = nil
                discardDraft(in: &state)
                return dismissalEffect
            }

            let id = BrowserTabID(uuid())
            state.tabs.append(.startPage(id: id))
            state.selectedTabID = id
            state.presentation = .browsing
            state.tabOverviewFocusID = nil
            state.omniboxDraft = ""
            state.hasUnsubmittedOmniboxDraft = false
            state.focusedField = .startPage
            state.providerSuggestionValues = []
            state.rebuildSuggestions()
            return .merge(dismissalEffect, checkClipboardIfAllowed(state: state))
        case .showTabOverviewTapped:
            guard state.library == nil else {
                return .none
            }

            let dismissalEffect = dismissPageUI(in: &state)
            state.pendingNewTab = nil
            state.presentation = .tabOverview
            state.tabOverviewFocusID = state.selectedTabID
            discardDraft(in: &state)
            let previewCommands = state.tabs.compactMap { tab in
                tab.isStartPage ? nil : BrowserWebKitCommand.capturePreview(tabID: tab.id)
            }
            return .merge(dismissalEffect, commands(previewCommands))
        case let .tabCardSelected(id):
            guard state.tabs.contains(where: { $0.id == id }) else {
                return .none
            }

            let dismissalEffect = dismissPageUI(in: &state)
            state.selectedTabID = id
            state.presentation = .browsing
            state.tabOverviewFocusID = nil
            discardDraft(in: &state)
            return dismissalEffect
        case let .tabOverviewFocusChanged(id):
            guard state.presentation == .tabOverview else {
                return .none
            }

            if let id, state.tabs.contains(where: { $0.id == id }) {
                state.tabOverviewFocusID = id
            } else {
                state.tabOverviewFocusID = state.selectedTabID
            }
        case .topLevelDeselected:
            state.destructiveConfirmation = nil
            state.pendingNewTab = nil
            return reconcileOmniboxFocusLoss(in: &state)
        case .settingsTapped:
            state.pendingNewTab = nil
            return .none
        case .omniboxFocused:
            let field = state.selectedTab?.isStartPage == true ? BrowserFocusedField.startPage : .chrome
            state.focusedField = field
            if field == .chrome,
               !state.hasUnsubmittedOmniboxDraft,
               let url = state.selectedTab?.metadata.committedURL {
                state.omniboxDraft = url.absoluteString
            }
            state.providerSuggestionValues = []
            state.rebuildSuggestions()
            return checkClipboardIfAllowed(state: state)
        case .omniboxFocusLost:
            return reconcileOmniboxFocusLoss(in: &state)
        case let .omniboxChanged(draft):
            state.omniboxDraft = draft
            state.hasUnsubmittedOmniboxDraft = true
            state.providerSuggestionValues = []
            state.rebuildSuggestions()
            guard state.focusedField != .none else {
                return .cancel(id: CancelID.providerSuggestions)
            }

            let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
            guard state.settings.providerSuggestionsEnabled, trimmed.count >= 2 else {
                return .cancel(id: CancelID.providerSuggestions)
            }

            let provider = state.settings.searchProvider
            let fetch = providerSuggestions.fetch
            let clock = clock
            return .run { send in
                do {
                    try await clock.sleep(for: .milliseconds(250))
                    try await send(.providerSuggestionsResponse(
                        draft: draft,
                        provider: provider,
                        .success(fetch(trimmed, provider)),
                    ))
                } catch is CancellationError {
                    return
                } catch {
                    await send(.providerSuggestionsResponse(
                        draft: draft,
                        provider: provider,
                        .failure(.unavailable),
                    ))
                }
            }
            .cancellable(id: CancelID.providerSuggestions, cancelInFlight: true)
        case let .providerSuggestionsResponse(draft, provider, result):
            guard state.focusedField != .none,
                  state.settings.providerSuggestionsEnabled,
                  provider == state.settings.searchProvider,
                  draft == state.omniboxDraft
            else {
                return .none
            }

            if case let .success(values) = result {
                state.providerSuggestionValues = values
                state.rebuildSuggestions()
            }
        case let .clipboardChecked(url):
            guard state.focusedField != .none,
                  state.settings.copiedLinkSuggestionsEnabled
            else {
                return .none
            }

            state.copiedLink = url
            state.rebuildSuggestions()
        case let .copiedLinkSuggestionsChanged(enabled):
            state.settings.copiedLinkSuggestionsEnabled = enabled
            if !enabled {
                state.copiedLink = nil
                state.rebuildSuggestions()
            }
            return persist(settings: state.settings)
        case let .libraryPresented(section):
            state.pendingNewTab = nil
            if state.library == nil {
                state.library = .init(section: section, referenceDate: now)
            } else {
                state.library?.section = section
            }
        case .libraryDismissed:
            state.library = nil
        case let .librarySearchChanged(section, query):
            switch section {
            case .bookmarks:
                state.library?.bookmarkSearch = query
            case .history:
                state.library?.historySearch = query
            }
        case let .libraryScrollChanged(section, position):
            switch section {
            case .bookmarks:
                state.library?.bookmarkScrollPosition = position
            case .history:
                state.library?.historyScrollPosition = position
            }
        case let .viewBookmark(id):
            state.library = .init(
                section: .bookmarks,
                bookmarkScrollPosition: id,
                revealedBookmarkID: id,
                referenceDate: now,
            )
        case .bookmarkRevealConsumed:
            state.library?.revealedBookmarkID = nil
        case .addBookmarkTapped:
            guard let tab = state.selectedTab else {
                return .none
            }

            state.pendingNewTab = nil
            presentBookmarkEditor(for: tab, state: &state)
        case let .addBookmarkForTab(tabID):
            guard let tab = state.tabs.first(where: { $0.id == tabID }) else {
                return .none
            }

            state.pendingNewTab = nil
            presentBookmarkEditor(for: tab, state: &state)
        case let .editBookmarkTapped(id):
            guard let bookmark = state.bookmarks.first(where: { $0.id == id }) else {
                return .none
            }

            state.pendingNewTab = nil
            state.bookmarkEditor = .init(
                bookmarkID: id,
                title: bookmark.title,
                urlDraft: bookmark.url.absoluteString,
            )
        case let .bookmarkEditorChanged(title, url):
            state.bookmarkEditor?.title = title
            state.bookmarkEditor?.urlDraft = url
            state.bookmarkEditor?.validationMessage = nil
        case .bookmarkEditorCancelled:
            state.bookmarkEditor = nil
        case .bookmarkEditorSaved:
            guard var editor = state.bookmarkEditor else {
                return .none
            }
            guard let url = BrowserNavigation.bookmarkURL(editor.urlDraft) else {
                editor.validationMessage = "Enter a valid HTTP or HTTPS address."
                state.bookmarkEditor = editor
                return .none
            }

            let duplicate = state.bookmarks.firstIndex(where: { $0.url == url })
            let existing = editor.bookmarkID.flatMap { id in state.bookmarks.firstIndex(where: { $0.id == id }) }
            let target = existing ?? duplicate
            let bookmark: BrowserBookmark
            if let target {
                let old = state.bookmarks[target]
                bookmark = .init(
                    id: old.id,
                    title: editor.title.trimmingCharacters(in: .whitespacesAndNewlines),
                    url: url,
                    siblingOrder: old.siblingOrder,
                    faviconData: old.faviconData,
                )
                state.bookmarks[target] = bookmark
            } else {
                bookmark = .init(
                    id: uuid(),
                    title: editor.title.trimmingCharacters(in: .whitespacesAndNewlines),
                    url: url,
                    siblingOrder: state.bookmarks.count,
                )
                state.bookmarks.append(bookmark)
            }
            state.bookmarkEditor = nil
            state.rebuildSuggestions()
            let save = browserLibrary.saveBookmark
            return .run { _ in try? await save(bookmark) }
        case let .deleteBookmark(id):
            state.bookmarks.removeAll { $0.id == id }
            state.rebuildSuggestions()
            let delete = browserLibrary.deleteBookmark
            return .run { _ in try? await delete(id) }
        case let .deleteHistoryEntry(id):
            state.history.removeAll { $0.id == id }
            state.rebuildSuggestions()
            let delete = browserLibrary.deleteHistoryEntry
            return .run { _ in try? await delete(id) }
        case let .copyURL(tabID):
            guard let url = state.tabs.first(where: { $0.id == tabID })?.metadata.committedURL,
                  BrowserNavigation.isHTTPURL(url)
            else {
                return .none
            }

            let write = clipboard.writeURL
            return .run { _ in await write(url) }
        case .clearHistoryTapped:
            state.destructiveConfirmation = .clearHistory
            state.pendingNewTab = nil
        case .destructiveConfirmationDismissed:
            state.destructiveConfirmation = nil
            return .none
        case .deleteAllBookmarksTapped:
            state.destructiveConfirmation = .deleteAllBookmarks(count: state.bookmarks.count)
            state.pendingNewTab = nil
        case .destructiveActionConfirmed:
            guard let confirmation = state.destructiveConfirmation else {
                return .none
            }

            state.destructiveConfirmation = nil
            switch confirmation {
            case .clearHistory:
                state.history = []
                let clear = browserLibrary.clearHistory
                return .run { _ in try? await clear() }
            case .deleteAllBookmarks:
                state.bookmarks = []
                state.rebuildSuggestions()
                let delete = browserLibrary.deleteAllBookmarks
                return .run { _ in try? await delete() }
            case .closeAllTabs:
                return .send(.closeAllConfirmed)
            case let .closeOtherTabs(id, _):
                return .send(.closeOtherTabsConfirmed(id))
            }
        case let .loaded(settings, bookmarks, history):
            state.settings = settings
            state.bookmarks = bookmarks
            state.history = history
            state.rebuildSuggestions()
        case let .navigate(url):
            return navigate(url: url, state: &state)
        case let .openInNewTab(url, openerID):
            guard state.pendingNewTab == nil else {
                return .none
            }

            switch state.settings.openLinksInNewTabs {
            case .background:
                return createRelatedTab(
                    url: url,
                    openerID: openerID,
                    disposition: .background,
                    state: &state,
                )
            case .foreground:
                return createRelatedTab(
                    url: url,
                    openerID: openerID,
                    disposition: .foreground,
                    state: &state,
                )
            case .askEveryTime:
                state.pendingNewTab = .init(url: url, openerID: openerID)
                return .none
            }
        case let .newTabDispositionSelected(disposition):
            guard let request = state.pendingNewTab else {
                return .none
            }

            state.pendingNewTab = nil
            return createRelatedTab(
                url: request.url,
                openerID: request.openerID,
                disposition: disposition,
                state: &state,
            )
        case .newTabDispositionDismissed:
            state.pendingNewTab = nil
            return .none
        case let .searchProviderChanged(provider):
            state.settings.searchProvider = provider
            state.providerSuggestionValues = []
            state.rebuildSuggestions()
            return .merge(.cancel(id: CancelID.providerSuggestions), persist(settings: state.settings))
        case let .providerSuggestionsChanged(enabled):
            state.settings.providerSuggestionsEnabled = enabled
            if !enabled {
                state.providerSuggestionValues = []
                state.rebuildSuggestions()
            }
            return .merge(.cancel(id: CancelID.providerSuggestions), persist(settings: state.settings))
        case let .openLinkPreferenceChanged(preference):
            state.settings.openLinksInNewTabs = preference
            return persist(settings: state.settings)
        case .resetSettings:
            state.settings = .init()
            state.providerSuggestionValues = []
            state.copiedLink = nil
            state.rebuildSuggestions()
            let reset = browserSettings.reset
            return .merge(
                .cancel(id: CancelID.providerSuggestions),
                .run { _ in await reset() },
            )
        case .findPresented:
            guard case .web = state.selectedTab?.content else {
                return .none
            }

            state.findDraft = ""
        case let .findChanged(query):
            guard state.findDraft != nil else {
                return .none
            }

            state.findDraft = query
            return command(.find(tabID: state.selectedTabID, query: query))
        case .findDismissed:
            state.findDraft = nil
            return command(.find(tabID: state.selectedTabID, query: ""))
        case .shareDismissed:
            state.shareURL = nil
            state.shareTitle = nil
        case .omniboxSubmitted:
            return submitOmnibox(state: &state)
        case .backTapped:
            return selectedCommand(state: state, BrowserWebKitCommand.goBack)
        case .forwardTapped:
            return selectedCommand(state: state, BrowserWebKitCommand.goForward)
        case .backHistoryRequested:
            return command(.showBackForwardList(tabID: state.selectedTabID, direction: .back))
        case .forwardHistoryRequested:
            return command(.showBackForwardList(tabID: state.selectedTabID, direction: .forward))
        case let .backForwardEntrySelected(token):
            guard let list = state.backForwardList else {
                return .none
            }

            state.backForwardList = nil
            return command(.goToBackForwardEntry(tabID: list.tabID, token: token))
        case .backForwardListDismissed:
            state.backForwardList = nil
        case .reloadOrStopTapped:
            guard let tab = state.selectedTab else {
                return .none
            }

            return command(tab.metadata.isLoading ? .stop(tabID: tab.id) : .reload(tabID: tab.id))
        case .pullToRefresh:
            guard let tab = state.selectedTab else {
                return .none
            }

            switch tab.content {
            case .startPage:
                return .none
            case .error:
                return retry(tab: tab)
            case .web,
                 .terminated:
                return command(.reload(tabID: tab.id))
            }
        case .retryTapped:
            guard let tab = state.selectedTab else {
                return .none
            }

            return retry(tab: tab)
        case let .webKitEvent(event):
            return handle(event: event, state: &state)
        }
        return .none
    }
}
