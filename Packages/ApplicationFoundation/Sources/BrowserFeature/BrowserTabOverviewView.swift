//
//  BrowserTabOverviewView.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Combine
import ComposableArchitecture
import SwiftUI
import UIKit

/// An action that leaves Tab Overview or mutates its tab collection.
enum BrowserTabOverviewExitAction {
    /// Creates and opens a new tab.
    case newTab
    /// Opens the selected overview card.
    case selectTab(BrowserTab)
    /// Closes one overview card.
    case closeTab(BrowserTabID)
    /// Keeps one overview card and closes the rest.
    case closeOtherTabs(BrowserTabID)
}

/// The mounted scroll state needed to confirm a reducer-owned overview target has settled.
struct BrowserTabOverviewScrollState: Equatable {
    let phase: ScrollPhase
    let isPersistedTargetFullyVisible: Bool

    var isSettled: Bool {
        phase == .idle && isPersistedTargetFullyVisible
    }
}

/// Publishes mounted scroll state independently from the reducer anchor observed by the grid.
@MainActor
final class BrowserTabOverviewScrollObservation: ObservableObject {
    @Published
    private(set) var state = BrowserTabOverviewScrollState(
        phase: .idle,
        isPersistedTargetFullyVisible: false,
    )

    func update(phase: ScrollPhase, isPersistedTargetFullyVisible: Bool) {
        let newState = BrowserTabOverviewScrollState(
            phase: phase,
            isPersistedTargetFullyVisible: isPersistedTargetFullyVisible,
        )
        guard state != newState else {
            return
        }

        state = newState
    }
}

/// Adapts live scroll targets to the reducer-owned Tab Overview restoration anchor.
///
/// Only changes to the persisted anchor are published. Live target changes remain local and do not
/// invalidate the overview's tab cards or send actions through the Browser store.
@MainActor
final class BrowserTabOverviewScrollPosition: ObservableObject {
    private(set) var livePosition: BrowserTabID?
    @Published
    private(set) var persistedPosition: BrowserTabID?
    let scrollObservation = BrowserTabOverviewScrollObservation()
    /// Identifies the last submitted target until the reducer accepts or rejects it.
    private var pendingPosition: BrowserTabID?
    /// Identifies a reducer-owned target whose matching binding write is a programmatic echo.
    private var programmaticTargetEcho: BrowserTabID?
    private var stableFallbackTask: Task<Void, Never>?
    private let sleepForStableFallback: @MainActor (Duration) async throws -> Void

    var scrollPhase: ScrollPhase {
        scrollObservation.state.phase
    }

    var isPersistedTargetFullyVisible: Bool {
        scrollObservation.state.isPersistedTargetFullyVisible
    }

    init(
        persistedPosition: BrowserTabID? = nil,
        sleepForStableFallback: @escaping @MainActor (Duration) async throws -> Void = { duration in
            try await Task.sleep(for: duration)
        },
    ) {
        livePosition = persistedPosition
        self.persistedPosition = persistedPosition
        self.sleepForStableFallback = sleepForStableFallback
    }

    /// Records a non-nil target locally and reports whether its identity changed.
    @discardableResult
    func updateLivePosition(_ position: BrowserTabID?) -> Bool {
        guard let position else {
            return false
        }

        if position == programmaticTargetEcho {
            livePosition = position
            programmaticTargetEcho = nil
            return false
        }

        guard position != livePosition else {
            return false
        }

        livePosition = position
        return true
    }

    /// Tracks scroll timing and releases an outstanding reducer-target echo for new interactions.
    func updateScrollPhase(_ phase: ScrollPhase) {
        if phase == .tracking || phase == .interacting || phase == .decelerating {
            programmaticTargetEcho = nil
        }
        updateScrollState(phase: phase, isFullyVisible: isPersistedTargetFullyVisible)
    }

    /// Records whether the mounted overview reports the reducer-owned anchor fully visible.
    func updatePersistedTargetVisibility(_ isFullyVisible: Bool) {
        updateScrollState(phase: scrollPhase, isFullyVisible: isFullyVisible)
    }

    /// Follows a reducer-owned anchor change, including tab-mutation reconciliation.
    @discardableResult
    func synchronize(
        with persistedPosition: BrowserTabID?,
        liveTabIDs: Set<BrowserTabID>,
    ) -> Bool {
        let reducerPosition = persistedPosition.flatMap { liveTabIDs.contains($0) ? $0 : nil }
        let persistedPositionChanged = self.persistedPosition != reducerPosition
        let livePositionWasRemoved = livePosition.map { !liveTabIDs.contains($0) } ?? false
        let reducerAcknowledgedPendingPosition = pendingPosition != nil
            && pendingPosition == reducerPosition
        let userDrivenScrollIsActive = scrollPhase == .tracking
            || scrollPhase == .interacting
            || scrollPhase == .decelerating

        if livePositionWasRemoved || (persistedPositionChanged && !reducerAcknowledgedPendingPosition) {
            cancelStableFallback()
            livePosition = reducerPosition
            programmaticTargetEcho = userDrivenScrollIsActive ? nil : reducerPosition
        }
        if persistedPositionChanged {
            self.persistedPosition = reducerPosition
            updateScrollState(phase: scrollPhase, isFullyVisible: false)
        }
        pendingPosition = nil
        return persistedPositionChanged
    }

    /// Starts a newly mounted overview from the reducer-owned restoration anchor.
    func restore(with persistedPosition: BrowserTabID?, liveTabIDs: Set<BrowserTabID>) {
        cancelStableFallback()
        let reducerPosition = persistedPosition.flatMap { liveTabIDs.contains($0) ? $0 : nil }
        livePosition = reducerPosition
        self.persistedPosition = reducerPosition
        updateScrollState(phase: .idle, isFullyVisible: false)
        pendingPosition = nil
        programmaticTargetEcho = reducerPosition
    }

    private func updateScrollState(phase: ScrollPhase, isFullyVisible: Bool) {
        let state = BrowserTabOverviewScrollState(
            phase: phase,
            isPersistedTargetFullyVisible: isFullyVisible,
        )
        guard scrollPhase != state.phase
            || isPersistedTargetFullyVisible != state.isPersistedTargetFullyVisible
        else {
            return
        }

        scrollObservation.update(
            phase: state.phase,
            isPersistedTargetFullyVisible: state.isPersistedTargetFullyVisible,
        )
    }

    /// Restarts a quiet-window task so rapid logical target changes commit only the latest one.
    func scheduleStableFallback(
        after duration: Duration = .milliseconds(300),
        onCommit: @escaping @MainActor () -> Void,
    ) {
        cancelStableFallback()
        let sleepForFallback = sleepForStableFallback
        stableFallbackTask = Task { @MainActor [weak self] in
            do {
                try await sleepForFallback(duration)
            } catch {
                return
            }
            guard let self, !Task.isCancelled else {
                return
            }

            stableFallbackTask = nil
            onCommit()
        }
    }

    /// Returns the latest live identity once while awaiting the reducer's validation.
    func commit() -> BrowserTabID? {
        cancelStableFallback()
        guard let livePosition,
              livePosition != persistedPosition,
              livePosition != pendingPosition
        else {
            return nil
        }

        pendingPosition = livePosition
        return livePosition
    }

    private func cancelStableFallback() {
        stableFallbackTask?.cancel()
        stableFallbackTask = nil
    }
}

@MainActor
private final class BrowserTabOverviewScrollVisibility {
    var fullyVisibleTargetIDs: Set<BrowserTabID> = []
}

/// Renders Tab Overview cards and their exact preview boundaries.
///
/// Transition callbacks remain owned by `BrowserView`, while this view owns only overview layout,
/// card interaction, preview selection, and the direct-manipulation state for one card.
@MainActor
@preconcurrency
struct BrowserTabOverviewView: View {
    let store: StoreOf<BrowserFeature>
    let transitionRegistry: BrowserTabTransitionSurfaceRegistry
    let previewAspectRatio: CGFloat
    let reduceMotionEnabled: Bool
    let accessibilityFocusedTabID: AccessibilityFocusState<BrowserTabID?>.Binding
    let onCommitScrollPosition: (BrowserTabID?) -> Void
    let onExitOverview: (BrowserTabID?, BrowserTabOverviewExitAction) -> Void

    @Environment(\.horizontalSizeClass)
    private var horizontalSizeClass
    @State
    private var tabCardDrag: BrowserTabCardDrag?
    @State
    private var scrollVisibility = BrowserTabOverviewScrollVisibility()
    @ObservedObject
    var scrollPosition: BrowserTabOverviewScrollPosition

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Text("Tabs").font(.largeTitle.bold())
                Spacer()
                Button("New Tab", systemImage: "plus") {
                    exitOverview(with: .newTab)
                }
            }
            tabOverviewScrollView
        }
        .padding(20)
    }

    private var tabOverviewScrollView: some View {
        ScrollView {
            LazyVGrid(columns: tabOverviewColumns, spacing: 18) {
                ForEach(store.tabs) { tab in
                    tabCard(tab)
                        .id(tab.id)
                }
            }
            .scrollTargetLayout()
        }
        .scrollPosition(id: tabOverviewScrollPositionBinding)
        .accessibilityIdentifier("browser.tab-overview.scroll-view")
        .onScrollPhaseChange { _, phase in
            scrollPosition.updateScrollPhase(phase)
            if phase == .idle {
                commitScrollPosition()
            }
        }
        .onScrollTargetVisibilityChange(idType: BrowserTabID.self, threshold: 1) { targetIDs in
            let visibleTargetIDs = Set(targetIDs)
            scrollVisibility.fullyVisibleTargetIDs = visibleTargetIDs
            scrollPosition.updatePersistedTargetVisibility(
                scrollPosition.persistedPosition.map(visibleTargetIDs.contains) ?? false,
            )
        }
        .onChange(of: scrollPosition.persistedPosition, initial: true) { _, position in
            scrollPosition.updatePersistedTargetVisibility(
                position.map(scrollVisibility.fullyVisibleTargetIDs.contains) ?? false,
            )
        }
    }

    /// The logical identity binding consumed by the overview's SwiftUI scroll view.
    var tabOverviewScrollPositionBinding: Binding<BrowserTabID?> {
        Binding(
            get: { scrollPosition.livePosition },
            set: { position in
                guard scrollPosition.updateLivePosition(position) else {
                    return
                }

                scrollPosition.scheduleStableFallback {
                    commitScrollPosition()
                }
            },
        )
    }

    private func commitScrollPosition() {
        guard let position = scrollPosition.commit() else {
            return
        }

        onCommitScrollPosition(position)
    }

    private func exitOverview(with action: BrowserTabOverviewExitAction) {
        onExitOverview(scrollPosition.commit(), action)
    }

    private var tabOverviewColumns: [GridItem] {
        if horizontalSizeClass == .compact {
            return [
                GridItem(.flexible(), spacing: 18),
                GridItem(.flexible(), spacing: 18),
            ]
        }

        return [GridItem(.adaptive(minimum: 220), spacing: 18)]
    }

    private func tabCard(_ tab: BrowserTab) -> some View {
        ZStack(alignment: .bottomTrailing) {
            Button { exitOverview(with: .selectTab(tab)) } label: { tabCardContent(tab) }
                .buttonStyle(.plain)
            Button { exitOverview(with: .closeTab(tab.id)) } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .frame(width: 44, height: 44)
                    .accessibilityHidden(true)
            }
            .accessibilityLabel("Close \(BrowserTabPresentation.title(for: tab))")
            .padding(10)
        }
        .offset(x: tabCardDrag?.tabID == tab.id ? tabCardDrag?.horizontalTranslation ?? 0 : 0)
        .accessibilityFocused(accessibilityFocusedTabID, equals: tab.id)
        .accessibilityValue(tab.id == store.selectedTabID ? "Selected" : "")
        .accessibilityAction(named: "Close Tab") {
            exitOverview(with: .closeTab(tab.id))
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 24)
                .onChanged { gesture in
                    updateTabCardDrag(tabID: tab.id, translation: gesture.translation)
                }
                .onEnded { gesture in
                    finishTabCardDrag(tabID: tab.id, translation: gesture.translation)
                },
        )
        .contextMenu { tabCardMenu(tab) }
    }

    private func updateTabCardDrag(tabID: BrowserTabID, translation: CGSize) {
        if let tabCardDrag, tabCardDrag.tabID == tabID {
            guard tabCardDrag.axis == .horizontal else {
                return
            }

            self.tabCardDrag = .init(
                tabID: tabID,
                axis: .horizontal,
                horizontalTranslation: translation.width,
            )
            return
        }

        let axis = BrowserTabSwipe.axis(for: translation)
        tabCardDrag = .init(
            tabID: tabID,
            axis: axis,
            horizontalTranslation: axis == .horizontal ? translation.width : 0,
        )
    }

    private func finishTabCardDrag(tabID: BrowserTabID, translation: CGSize) {
        guard let tabCardDrag, tabCardDrag.tabID == tabID else {
            return
        }
        guard let outcome = BrowserTabSwipe.outcome(for: translation, axis: tabCardDrag.axis) else {
            self.tabCardDrag = nil
            return
        }

        switch outcome {
        case .cancel:
            withAnimation(tabCardSettleAnimation) {
                self.tabCardDrag = nil
            }
        case .dismiss:
            self.tabCardDrag = nil
            exitOverview(with: .closeTab(tabID))
        }
    }

    private var tabCardSettleAnimation: Animation {
        reduceMotionEnabled ? .easeOut(duration: 0.15) : .spring(response: 0.42)
    }

    private func tabCardContent(_ tab: BrowserTab) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            BrowserTabTransitionSurfaceHost(
                role: .card(tab.id),
                registry: transitionRegistry,
            ) {
                tabPreviewSurface(tab)
            }
            .aspectRatio(previewAspectRatio, contentMode: .fit)
            HStack(spacing: 6) {
                if tab.id == store.selectedTabID {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .frame(width: 28, height: 44)
                        .accessibilityLabel("Selected")
                }
                Text(BrowserTabPresentation.title(for: tab))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .minimumScaleFactor(0.5)
                    .allowsTightening(true)
                    .layoutPriority(1)
                Spacer()
            }
            .padding(.trailing, 34)
            .frame(height: 44, alignment: .center)
            .clipped()
        }
        .padding(10)
        .frame(maxWidth: .infinity)
        .background(.background, in: RoundedRectangle(cornerRadius: 18))
        .shadow(radius: 3)
    }

    private func tabPreviewSurface(_ tab: BrowserTab) -> some View {
        tabPreviewSurface(
            representation: visiblePreviewRepresentation(for: tab),
            fallback: BrowserTabPreviewRepresentation.fallback(for: tab),
        )
    }

    private func visiblePreviewRepresentation(for tab: BrowserTab) -> BrowserTabPreviewRepresentation {
        .cachedOrFallback(
            for: tab,
            revision: store.previewState.revision(for: tab.id),
            entry: store.previewState.data(for: tab.id),
        )
    }

    private func tabPreviewSurface(
        representation: BrowserTabPreviewRepresentation,
        fallback: BrowserTabPreviewRepresentation,
    ) -> some View {
        ZStack {
            RoundedRectangle(
                cornerRadius: BrowserTabTransitionPresentation.cardCornerRadius,
                style: .continuous,
            )
            .fill(.quaternary)
            switch representation {
            case let .snapshot(data):
                if let image = UIImage(data: data) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .clipped()
                        .accessibilityHidden(true)
                } else {
                    placeholderPreview(fallback)
                }
            case let .placeholder(placeholder):
                placeholderPreview(.placeholder(placeholder))
            }
        }
        .clipShape(RoundedRectangle(
            cornerRadius: BrowserTabTransitionPresentation.cardCornerRadius,
            style: .continuous,
        ))
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func placeholderPreview(_ representation: BrowserTabPreviewRepresentation) -> some View {
        if case let .placeholder(placeholder) = representation {
            VStack(spacing: 8) {
                Image(systemName: placeholder.systemImage)
                    .font(.largeTitle)
                    .accessibilityHidden(true)
                Text(placeholder.label)
                    .font(.caption.weight(.medium))
            }
            .foregroundStyle(placeholder.tint)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func tabCardMenu(_ tab: BrowserTab) -> some View {
        Button("Open Tab") { exitOverview(with: .selectTab(tab)) }
        if BrowserTabPresentation.canShowPageActions(for: tab),
           let url = tab.metadata.committedURL {
            if let bookmarkID = BrowserTabPresentation.bookmarkID(
                for: tab,
                bookmarks: store.bookmarks,
            ) {
                Button("View Bookmark") { store.send(.viewBookmark(bookmarkID)) }
            } else {
                Button("Add Bookmark") { store.send(.addBookmarkForTab(tab.id)) }
            }
            Button("Copy URL") { store.send(.copyURL(tab.id)) }
            ShareLink(
                item: url,
                subject: Text(BrowserTabPresentation.title(for: tab)),
            ) { Text("Share Page") }
        }
        Button("Close Tab", role: .destructive) {
            exitOverview(with: .closeTab(tab.id))
        }
        if store.tabs.count > 1 {
            Button("Close Other Tabs", role: .destructive) {
                exitOverview(with: .closeOtherTabs(tab.id))
            }
        }
    }
}
