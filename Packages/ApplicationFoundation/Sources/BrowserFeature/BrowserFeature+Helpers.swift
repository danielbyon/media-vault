//
//  BrowserFeature+Helpers.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import ComposableArchitecture
import Foundation

extension BrowserFeature {
    func presentBookmarkEditor(for tab: BrowserTab, state: inout State) {
        guard case .web = tab.content,
              let url = tab.metadata.committedURL,
              BrowserNavigation.isHTTPURL(url)
        else {
            return
        }

        state.bookmarkEditor = .init(
            title: tab.metadata.title ?? url.host ?? "",
            urlDraft: url.absoluteString,
        )
    }

    func submitOmnibox(state: inout State) -> Effect<Action> {
        switch BrowserNavigation.resolve(state.omniboxDraft, provider: state.settings.searchProvider) {
        case .empty:
            return .none
        case let .web(url):
            guard let index = state.tabs.firstIndex(where: { $0.id == state.selectedTabID }) else {
                return .none
            }

            let id = state.selectedTabID
            invalidatePreview(
                for: id,
                state: &state,
                operation: .navigation(expectedURL: url),
            )
            if state.tabs[index].isStartPage {
                state.tabs[index] = .web(id: id, url: url)
            } else {
                state.tabs[index].content = .web(requestedURL: url)
            }
            let dismissalEffect = dismissPageUI(in: &state)
            discardDraft(in: &state)
            return .merge(
                dismissalEffect,
                commands([.ensureContext(tabID: id), .load(tabID: id, url: url)]),
            )
        case let .external(destination):
            let open = externalNavigation.open
            discardDraft(in: &state)
            return .run { _ in await open(destination) }
        case .rejectedScheme:
            return .none
        }
    }

    func navigate(url: URL, state: inout State) -> Effect<Action> {
        guard let index = state.tabs.firstIndex(where: { $0.id == state.selectedTabID }) else {
            return .none
        }

        let id = state.selectedTabID
        invalidatePreview(
            for: id,
            state: &state,
            operation: .navigation(expectedURL: url),
        )
        if state.tabs[index].isStartPage {
            state.tabs[index] = .web(id: id, url: url)
        } else {
            state.tabs[index].content = .web(requestedURL: url)
        }
        let dismissalEffect = dismissPageUI(in: &state)
        state.library = nil
        discardDraft(in: &state)
        return .merge(
            dismissalEffect,
            commands([.ensureContext(tabID: id), .load(tabID: id, url: url)]),
        )
    }

    func createRelatedTab(
        url: URL,
        openerID: BrowserTabID?,
        disposition: BrowserNewTabDisposition,
        state: inout State,
    ) -> Effect<Action> {
        let id = BrowserTabID(uuid())
        let openerIndex = openerID.flatMap { opener in state.tabs.firstIndex(where: { $0.id == opener }) }
        let insertion = openerIndex.map { index in
            var value = index + 1
            while value < state.tabs.endIndex, state.tabs[value].openerID == openerID {
                value += 1
            }
            return value
        } ?? state.tabs.endIndex
        state.tabs.insert(.web(id: id, url: url, openerID: openerID), at: insertion)
        state.previewRevisions[id] = .init()
        if disposition == .foreground {
            state.selectedTabID = id
        }
        return commands([.ensureContext(tabID: id), .load(tabID: id, url: url)])
    }

    func close(tabID: BrowserTabID, state: inout State) -> Effect<Action> {
        guard let index = state.tabs.firstIndex(where: { $0.id == tabID }) else {
            return .none
        }

        let wasSelected = state.selectedTabID == tabID
        let wasOverview = state.presentation == .tabOverview
        let priorOverviewFocusID = state.tabOverviewFocusID
        state.tabPreviewData.removeValue(forKey: tabID)
        state.previewRevisions.removeValue(forKey: tabID)
        state.pendingPreviewInvalidations.removeValue(forKey: tabID)
        let dismissalEffect: Effect<Action> =
            if wasSelected {
                dismissPageUI(in: &state)
            } else if state.javaScriptDialogTabID == tabID {
                dismissJavaScriptDialog(in: &state)
            } else {
                .none
            }
        state.tabs.remove(at: index)
        if state.tabs.isEmpty {
            let replacement = BrowserTabID(uuid())
            state.tabs = [.startPage(id: replacement)]
            state.previewRevisions[replacement] = .init()
            state.selectedTabID = replacement
            state.presentation = wasOverview ? .tabOverview : .browsing
            discardDraft(in: &state)
        } else if wasSelected {
            state.selectedTabID = state.tabs[max(0, index - 1)].id
            discardDraft(in: &state)
        }
        if wasOverview {
            if state.tabs.isEmpty || wasSelected {
                state.tabOverviewFocusID = state.selectedTabID
            } else if priorOverviewFocusID == tabID {
                let nearestSurvivorIndex = index > 0 ? index - 1 : index
                state.tabOverviewFocusID = state.tabs[nearestSurvivorIndex].id
            } else if let priorOverviewFocusID,
                      state.tabs.contains(where: { $0.id == priorOverviewFocusID }) {
                state.tabOverviewFocusID = priorOverviewFocusID
            } else {
                state.tabOverviewFocusID = state.selectedTabID
            }
        } else {
            state.tabOverviewFocusID = nil
        }
        return .merge(dismissalEffect, command(.destroyContext(tabID: tabID)))
    }

    // swiftlint:disable:next cyclomatic_complexity
    func handle(event: BrowserWebKitEvent, state: inout State) -> Effect<Action> {
        switch event {
        case let .siteCreatedTab(openerID, tabID, url, foreground):
            guard let openerIndex = state.tabs.firstIndex(where: { $0.id == openerID }) else {
                return .none
            }

            var insertion = openerIndex + 1
            while insertion < state.tabs.endIndex, state.tabs[insertion].openerID == openerID {
                insertion += 1
            }
            state.tabs.insert(.scriptCreatedWeb(id: tabID, openerID: openerID, url: url), at: insertion)
            state.previewRevisions[tabID] = .init()
            if foreground {
                state.selectedTabID = tabID
            }
        case let .metadata(tabID, metadata):
            guard let index = state.tabs.firstIndex(where: { $0.id == tabID }) else {
                return .none
            }

            let previousCommittedURL = state.tabs[index].metadata.committedURL
            state.tabs[index].metadata = metadata
            if let committedURL = metadata.committedURL {
                let isSemanticChange = committedURL != previousCommittedURL
                    || !isWebContent(state.tabs[index].content)
                let pendingOperation = state.pendingPreviewInvalidations[tabID]
                let wasExpectedOperation = pendingOperation?.consumes(
                    committedURL: committedURL,
                    isSemanticChange: isSemanticChange,
                ) == true
                if pendingOperation != nil {
                    state.pendingPreviewInvalidations.removeValue(forKey: tabID)
                }
                if isSemanticChange, !wasExpectedOperation {
                    invalidatePreview(for: tabID, state: &state, operation: nil)
                }
                state.tabs[index].content = .web(requestedURL: committedURL)
                if tabID == state.selectedTabID, committedURL != previousCommittedURL {
                    state.findDraft = nil
                    state.backForwardList = nil
                }
            }
        case let .navigationFailed(tabID, error):
            guard let index = state.tabs.firstIndex(where: { $0.id == tabID }) else {
                return .none
            }

            let wasExpectedOperation = state.pendingPreviewInvalidations.removeValue(forKey: tabID) != nil
            if !wasExpectedOperation, !isErrorContent(state.tabs[index].content) {
                invalidatePreview(for: tabID, state: &state, operation: nil)
            }
            state.tabs[index].metadata.isLoading = false
            state.tabs[index].content = .error(error)
        case let .processTerminated(tabID):
            guard let index = state.tabs.firstIndex(where: { $0.id == tabID }) else {
                return .none
            }

            let wasExpectedOperation = state.pendingPreviewInvalidations.removeValue(forKey: tabID) != nil
            if !wasExpectedOperation, !isTerminatedContent(state.tabs[index].content) {
                invalidatePreview(for: tabID, state: &state, operation: nil)
            }
            state.tabs[index].metadata.isLoading = false
            state.tabs[index].content = .terminated(lastCommittedURL: state.tabs[index].metadata.committedURL)
        case let .scriptCloseRequested(tabID):
            guard state.tabs.first(where: { $0.id == tabID })?.isScriptCreated == true else {
                return .none
            }

            return close(tabID: tabID, state: &state)
        case let .javaScriptDialogChanged(tabID, isPresented):
            if isPresented {
                state.javaScriptDialogTabID = tabID
            } else if state.javaScriptDialogTabID == tabID {
                state.javaScriptDialogTabID = nil
            }
        case let .backForwardEntries(tabID, direction, entries):
            guard tabID == state.selectedTabID else {
                return .none
            }

            state.backForwardList = .init(tabID: tabID, direction: direction, entries: entries)
        case let .preview(tabID, revision, pngData):
            storePreview(tabID: tabID, revision: revision, pngData: pngData, state: &state)
        case let .linkContextAction(tabID, action, url):
            return handleLinkContextAction(tabID: tabID, action: action, url: url, state: &state)
        }
        return .none
    }

    /// Stores a capture only when its opaque revision still names the live document.
    func storePreview(
        tabID: BrowserTabID,
        revision: BrowserTabPreviewRevision,
        pngData: Data?,
        state: inout State,
    ) {
        guard state.tabs.contains(where: { $0.id == tabID }),
              let pngData,
              !pngData.isEmpty,
              revision == state.previewRevisions[tabID]
        else {
            return
        }

        state.tabPreviewData[tabID] = .init(revision: revision, pngData: pngData)
    }

    /// Invalidates one preview revision before a semantic document change.
    func invalidatePreview(
        for tabID: BrowserTabID,
        state: inout State,
        operation: BrowserPreviewInvalidationOperation? = .navigation(expectedURL: nil),
    ) {
        guard state.tabs.contains(where: { $0.id == tabID }) else {
            return
        }

        state.previewRevisions[tabID] = .init()
        state.tabPreviewData.removeValue(forKey: tabID)
        if let operation {
            state.pendingPreviewInvalidations[tabID] = operation
        } else {
            state.pendingPreviewInvalidations.removeValue(forKey: tabID)
        }
    }

    private func isWebContent(_ content: BrowserTab.Content) -> Bool {
        if case .web = content {
            return true
        }
        return false
    }

    private func isErrorContent(_ content: BrowserTab.Content) -> Bool {
        if case .error = content {
            return true
        }
        return false
    }

    private func isTerminatedContent(_ content: BrowserTab.Content) -> Bool {
        if case .terminated = content {
            return true
        }
        return false
    }

    func handleLinkContextAction(
        tabID: BrowserTabID,
        action: BrowserLinkContextAction,
        url: URL,
        state: inout State,
    ) -> Effect<Action> {
        guard state.tabs.contains(where: { $0.id == tabID }) else {
            return .none
        }

        switch action {
        case .open:
            guard state.selectedTabID == tabID else {
                return .none
            }

            if BrowserNavigation.isHTTPURL(url) {
                return navigate(url: url, state: &state)
            }
            let open = externalNavigation.open
            return .run { _ in await open(url) }
        case .openInNewTab:
            guard BrowserNavigation.isHTTPURL(url) else {
                let open = externalNavigation.open
                return .run { _ in await open(url) }
            }

            return .send(.openInNewTab(url, openerID: tabID))
        case .copyLink:
            let write = clipboard.writeURL
            return .run { _ in await write(url) }
        case .shareLink:
            state.pendingNewTab = nil
            state.shareURL = url
            state.shareTitle = state.tabs.first(where: { $0.id == tabID })?.metadata.title
                ?? url.host
        }
        return .none
    }

    func retry(tab: BrowserTab, state: inout State) -> Effect<Action> {
        switch tab.content {
        case let .error(error):
            invalidatePreview(
                for: tab.id,
                state: &state,
                operation: .navigation(expectedURL: error.url),
            )
            return command(.load(tabID: tab.id, url: error.url))
        case .terminated:
            invalidatePreview(
                for: tab.id,
                state: &state,
                operation: .reload(committedURL: tab.metadata.committedURL),
            )
            return command(.reload(tabID: tab.id))
        case .startPage,
             .web:
            return .none
        }
    }

    func selectedCommand(state: State, _ make: (BrowserTabID) -> BrowserWebKitCommand) -> Effect<Action> {
        command(make(state.selectedTabID))
    }

    func command(_ value: BrowserWebKitCommand) -> Effect<Action> {
        let execute = webKit.execute
        return .run { _ in await execute(value) }
    }

    func commands(_ values: [BrowserWebKitCommand]) -> Effect<Action> {
        let execute = webKit.execute
        return .run { _ in for value in values {
            await execute(value)
        } }
    }

    func discardDraft(in state: inout State) {
        state.omniboxDraft = ""
        state.hasUnsubmittedOmniboxDraft = false
        state.focusedField = .none
        state.providerSuggestionValues = []
        state.suggestions = []
    }

    /// Clears focus-owned transient state while preserving any unsubmitted omnibox draft.
    func reconcileOmniboxFocusLoss(in state: inout State) -> Effect<Action> {
        state.focusedField = .none
        state.providerSuggestionValues = []
        state.suggestions = []
        state.copiedLink = nil
        return .cancel(id: CancelID.providerSuggestions)
    }

    func dismissJavaScriptDialog(in state: inout State) -> Effect<Action> {
        guard let tabID = state.javaScriptDialogTabID else {
            return .none
        }

        state.javaScriptDialogTabID = nil
        return command(.dismissJavaScriptDialog(tabID: tabID))
    }

    func dismissPageUI(in state: inout State) -> Effect<Action> {
        let dialogEffect = dismissJavaScriptDialog(in: &state)
        let findEffect: Effect<Action>
        if state.findDraft != nil {
            let tabID = state.selectedTabID
            state.findDraft = nil
            findEffect = command(.find(tabID: tabID, query: ""))
        } else {
            findEffect = .none
        }
        state.backForwardList = nil
        state.shareURL = nil
        state.shareTitle = nil
        return .merge(dialogEffect, findEffect)
    }

    func checkClipboardIfAllowed(state: State) -> Effect<Action> {
        guard state.focusedField != .none,
              state.settings.copiedLinkSuggestionsEnabled,
              state.omniboxDraft.isEmpty || state.selectedTab?.isStartPage == true
        else {
            return .none
        }

        let read = clipboard.readHTTPURL
        return .run { send in await send(.clipboardChecked(read())) }
    }

    func persist(settings: BrowserSettings) -> Effect<Action> {
        let save = browserSettings.save
        return .run { _ in await save(settings) }
    }
}
