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
            let operationID = beginPreviewOperation(for: id, state: &state)
            if state.tabs[index].isStartPage {
                state.tabs[index] = .web(id: id, url: url)
            } else {
                state.tabs[index].content = .web(requestedURL: url)
            }
            let dismissalEffect = dismissPageUI(in: &state)
            discardDraft(in: &state)
            return .merge(
                dismissalEffect,
                commands([
                    .ensureContext(tabID: id),
                    .load(tabID: id, url: url, operationID: operationID),
                ]),
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
        let operationID = beginPreviewOperation(for: id, state: &state)
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
            commands([
                .ensureContext(tabID: id),
                .load(tabID: id, url: url, operationID: operationID),
            ]),
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
        state.previewState.addTab(id)
        let operationID = beginPreviewOperation(for: id, state: &state)
        if disposition == .foreground {
            state.selectedTabID = id
        }
        return commands([
            .ensureContext(tabID: id),
            .load(tabID: id, url: url, operationID: operationID),
        ])
    }

    /// Keeps the transient Tab Overview anchor attached to a live tab after tab mutations.
    func reconcileTabOverviewScrollPosition(
        previousAnchor: BrowserTabID?,
        previousAnchorIndex: Int?,
        state: inout State,
    ) {
        guard let previousAnchor else {
            state.tabOverviewScrollPosition = nil
            return
        }
        guard !state.tabs.isEmpty else {
            state.tabOverviewScrollPosition = nil
            return
        }

        if state.tabs.contains(where: { $0.id == previousAnchor }) {
            state.tabOverviewScrollPosition = previousAnchor
            return
        }

        let previousIndex = max(0, previousAnchorIndex ?? 0)
        let fallbackIndex = previousIndex > 0
            ? min(previousIndex - 1, state.tabs.count - 1)
            : min(previousIndex, state.tabs.count - 1)
        state.tabOverviewScrollPosition = state.tabs[fallbackIndex].id
    }

    /// Applies one tab mutation and reconciles the transient Tab Overview anchor against its survivors.
    func mutateTabsPreservingTabOverviewScrollPosition(
        state: inout State,
        mutation: (inout State) -> Void,
    ) {
        let previousAnchor = state.tabOverviewScrollPosition
        let previousAnchorIndex = previousAnchor.flatMap { anchor in
            state.tabs.firstIndex(where: { $0.id == anchor })
        }
        mutation(&state)
        reconcileTabOverviewScrollPosition(
            previousAnchor: previousAnchor,
            previousAnchorIndex: previousAnchorIndex,
            state: &state,
        )
    }

    func close(tabID: BrowserTabID, state: inout State) -> Effect<Action> {
        guard let index = state.tabs.firstIndex(where: { $0.id == tabID }) else {
            return .none
        }

        let wasSelected = state.selectedTabID == tabID
        let wasOverview = state.presentation == .tabOverview
        let priorOverviewFocusID = state.tabOverviewFocusID
        state.previewState.removeTab(tabID)
        let dismissalEffect: Effect<Action> =
            if wasSelected {
                dismissPageUI(in: &state)
            } else if state.javaScriptDialogTabID == tabID {
                dismissJavaScriptDialog(in: &state)
            } else {
                .none
            }
        mutateTabsPreservingTabOverviewScrollPosition(state: &state) { state in
            state.tabs.remove(at: index)
            if state.tabs.isEmpty {
                let replacement = BrowserTabID(uuid())
                state.tabs = [.startPage(id: replacement)]
                state.previewState.addTab(replacement)
                state.selectedTabID = replacement
                state.presentation = wasOverview ? .tabOverview : .browsing
                discardDraft(in: &state)
            } else if wasSelected {
                state.selectedTabID = state.tabs[max(0, index - 1)].id
                discardDraft(in: &state)
            }
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
            state.previewState.addTab(tabID)
            if foreground {
                state.selectedTabID = tabID
            }
        case let .navigationStarted(tabID):
            invalidatePreview(for: tabID, state: &state, operation: nil)
        case let .metadata(tabID, metadata, correlation):
            handleMetadata(
                tabID: tabID,
                metadata: metadata,
                operationID: correlation.operationID,
                state: &state,
            )
        case let .navigationFailed(tabID, error, correlation):
            handleNavigationFailure(
                tabID: tabID,
                error: error,
                operationID: correlation.operationID,
                state: &state,
            )
        case let .processTerminated(tabID):
            guard let index = state.tabs.firstIndex(where: { $0.id == tabID }) else {
                return .none
            }

            let wasExpectedOperation = state.previewState.clearOperations(for: tabID)
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

    private func handleMetadata(
        tabID: BrowserTabID,
        metadata: BrowserTab.Metadata,
        operationID: BrowserNavigationOperationID?,
        state: inout State,
    ) {
        guard let index = state.tabs.firstIndex(where: { $0.id == tabID }) else {
            return
        }
        guard acceptsNavigationEvent(operationID: operationID, for: tabID, state: state) else {
            return
        }

        let isExpectedOperation = operationID.map {
            state.previewState.isCurrent(operationID: $0, for: tabID)
        } ?? false
        let previousCommittedURL = state.tabs[index].metadata.committedURL
        if operationID == nil, handleUntrackedSameDocumentMetadata(
            tabID: tabID,
            index: index,
            metadata: metadata,
            previousCommittedURL: previousCommittedURL,
            state: &state,
        ) {
            return
        }

        state.tabs[index].metadata = metadata
        let representsCompletedOperation = operationID != nil && !metadata.isLoading
        if representsCompletedOperation, let operationID {
            _ = consumeNavigationOperation(
                operationID,
                for: tabID,
                state: &state,
            )
        }
        guard let committedURL = metadata.committedURL else {
            return
        }

        let isSemanticChange = committedURL != previousCommittedURL
            || !isWebContent(state.tabs[index].content)
        if isSemanticChange, !isExpectedOperation {
            // An uncorrelated document identity change, including a hash/history navigation,
            // supersedes any reducer operation that never produced a correlated WebKit start.
            // A correlated event may arrive after didCommit while WebKit is still loading, so
            // keep that operation identity until its loading-finished metadata arrives.
            // Clear the obsolete identity before accepting later callbacks from the old page.
            invalidatePreview(for: tabID, state: &state, operation: nil)
        }
        state.tabs[index].content = .web(requestedURL: committedURL)
        if tabID == state.selectedTabID, committedURL != previousCommittedURL {
            state.findDraft = nil
            state.backForwardList = nil
        }
    }

    private func handleNavigationFailure(
        tabID: BrowserTabID,
        error: BrowserNavigationError,
        operationID: BrowserNavigationOperationID?,
        state: inout State,
    ) {
        guard let index = state.tabs.firstIndex(where: { $0.id == tabID }) else {
            return
        }
        guard acceptsNavigationEvent(operationID: operationID, for: tabID, state: state) else {
            return
        }

        let wasExpectedOperation = operationID.map {
            consumeNavigationOperation($0, for: tabID, state: &state)
        } ?? false
        if !wasExpectedOperation, !isErrorContent(state.tabs[index].content) {
            invalidatePreview(for: tabID, state: &state, operation: nil)
        }
        state.tabs[index].metadata.isLoading = false
        state.tabs[index].content = .error(error)
    }

    private func acceptsNavigationEvent(
        operationID: BrowserNavigationOperationID?,
        for tabID: BrowserTabID,
        state: State,
    ) -> Bool {
        guard let operationID else {
            return true
        }

        return state.previewState.isCurrent(operationID: operationID, for: tabID)
    }

    @discardableResult
    private func consumeNavigationOperation(
        _ operationID: BrowserNavigationOperationID,
        for tabID: BrowserTabID,
        state: inout State,
    ) -> Bool {
        state.previewState.consume(operationID: operationID, for: tabID)
    }

    private func handleUntrackedSameDocumentMetadata(
        tabID: BrowserTabID,
        index: Int,
        metadata: BrowserTab.Metadata,
        previousCommittedURL: URL?,
        state: inout State,
    ) -> Bool {
        guard metadata.committedURL == previousCommittedURL else {
            return false
        }
        guard state.previewState.operation(for: tabID) != nil else {
            // An uncorrelated observation that names the already-committed document can update
            // ordinary chrome state when no reducer operation owns that document transition.
            state.tabs[index].metadata = metadata
            return true
        }

        // A same-URL KVO event cannot complete the pending operation, but its loading edge is
        // still useful for reload/stop. Keep identity-bearing fields owned by the operation and
        // merge only the monotonic loading evidence.
        guard metadata.isLoading else {
            return true
        }

        state.tabs[index].metadata.isLoading = true
        state.tabs[index].metadata.estimatedProgress = max(
            state.tabs[index].metadata.estimatedProgress,
            metadata.estimatedProgress,
        )
        return true
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
              revision == state.previewState.revision(for: tabID)
        else {
            return
        }

        state.previewState.setData(.init(revision: revision, pngData: pngData), for: tabID)
    }

    /// Creates one operation identity and invalidates the matching preview revision.
    func beginPreviewOperation(
        for tabID: BrowserTabID,
        state: inout State,
    ) -> BrowserNavigationOperationID {
        let operationID = BrowserNavigationOperationID()
        invalidatePreview(
            for: tabID,
            state: &state,
            operation: operationID,
        )
        return operationID
    }

    /// Invalidates one preview revision before a semantic document change.
    func invalidatePreview(
        for tabID: BrowserTabID,
        state: inout State,
        operation: BrowserNavigationOperationID? = nil,
    ) {
        guard state.tabs.contains(where: { $0.id == tabID }) else {
            return
        }

        state.previewState.invalidate(tabID: tabID, operation: operation)
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
            let operationID = beginPreviewOperation(for: tab.id, state: &state)
            return command(.load(tabID: tab.id, url: error.url, operationID: operationID))
        case .terminated:
            let operationID = beginPreviewOperation(for: tab.id, state: &state)
            return command(.reload(tabID: tab.id, operationID: operationID))
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
