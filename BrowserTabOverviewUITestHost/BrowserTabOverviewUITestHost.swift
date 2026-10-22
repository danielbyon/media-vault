//
//  BrowserTabOverviewUITestHost.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import CalculatorFeature
import Combine
import ComposableArchitecture
import CoreFoundation
import Foundation
import SwiftUI
import UIKit
@testable import BrowserFeature

@main
struct BrowserTabOverviewUITestHost: App {
    var body: some Scene {
        WindowGroup {
            if ProcessInfo.processInfo.arguments.contains("--calculator-basic") {
                CalculatorUITestHostView()
                    .environment(\.horizontalSizeClass, .regular)
            } else if let configuration = ShowTabsPlacementConfiguration.current {
                ShowTabsPlacementHostView(configuration: configuration)
                    .environment(\.horizontalSizeClass, configuration.sizeClass.value)
            } else {
                BrowserTabOverviewUITestHostView()
                    .environment(\.horizontalSizeClass, .compact)
            }
        }
    }
}

/// Presents the production calculator in isolation for focused accessibility and keyboard tests.
@MainActor
private struct CalculatorUITestHostView: View {
    private let store: StoreOf<CalculatorFeature>

    init() {
        var state = CalculatorFeature.State()
        if ProcessInfo.processInfo.arguments.contains("--calculator-seeded-history") {
            state.history = [
                CalculatorHistoryEntry(
                    id: UUID(),
                    expression: "2 + 2",
                    result: "4",
                    date: Date(timeIntervalSince1970: 0),
                ),
            ]
        }
        store = Store(initialState: state) {
            CalculatorFeature()
        }
    }

    var body: some View {
        CalculatorView(store: store, loadsPersistenceOnAppear: false)
    }
}

/// Hosts the production overview with deterministic tabs and a reducer-backed scroll anchor.
@MainActor
private struct BrowserTabOverviewUITestHostView: View {
    private let store: StoreOf<BrowserFeature>
    private let transitionRegistry: BrowserTabTransitionSurfaceRegistry
    @StateObject
    private var scrollPosition: BrowserTabOverviewScrollPosition
    @StateObject
    private var scrollVisibility = BrowserTabOverviewScrollVisibility()
    @State
    private var committedPositionCount = 0
    @AccessibilityFocusState
    private var accessibilityFocusedTabID: BrowserTabID?

    init() {
        let tabs = (0 ..< 40).map { _ in BrowserTab.startPage(id: BrowserTabID()) }
        let arguments = ProcessInfo.processInfo.arguments
        let startsAtLastTab = arguments.contains("--restore-last-tab")
            || arguments.contains("--reconcile-close-last-tab")
        let initialAnchor = startsAtLastTab ? tabs[tabs.count - 1].id : tabs[0].id
        var initialState = BrowserFeature.State(
            tabs: tabs,
            selectedTabID: initialAnchor,
            presentation: .tabOverview,
        )
        initialState.tabOverviewScrollPosition = initialAnchor

        store = Store(initialState: initialState) {
            BrowserFeature()
        }
        transitionRegistry = BrowserTabTransitionSurfaceRegistry()
        let restoredScrollPosition = BrowserTabOverviewScrollPosition()
        restoredScrollPosition.restore(with: initialAnchor, liveTabIDs: Set(tabs.map(\.id)))
        _scrollPosition = StateObject(wrappedValue: restoredScrollPosition)
    }

    var body: some View {
        VStack(spacing: 0) {
            Text("\(savedAnchorDescription)|commits-\(committedPositionCount)")
                .font(.caption)
                .accessibilityIdentifier("browser.tab-overview.saved-anchor")

            BrowserTabOverviewRestoreSettlementLabel(observation: scrollPosition.scrollObservation)

            BrowserTabOverviewView(
                store: store,
                transitionRegistry: transitionRegistry,
                previewAspectRatio: 4.0 / 3.0,
                reduceMotionEnabled: true,
                accessibilityFocusedTabID: $accessibilityFocusedTabID,
                onCommitScrollPosition: commitScrollPosition,
                onExitOverview: handleOverviewExit,
                scrollPosition: scrollPosition,
                scrollVisibility: scrollVisibility,
            )
        }
        .onChange(of: store.state.tabOverviewScrollPosition) { _, _ in
            BrowserView.synchronizeTabOverviewScrollPosition(store: store, adapter: scrollPosition)
        }
        .onChange(of: store.state.tabs.map(\.id)) { _, _ in
            BrowserView.synchronizeTabOverviewScrollPosition(store: store, adapter: scrollPosition)
        }
    }

    private var savedAnchorDescription: String {
        guard let savedAnchor = store.state.tabOverviewScrollPosition,
              let index = store.state.tabs.firstIndex(where: { $0.id == savedAnchor })
        else {
            return "anchor-missing"
        }

        return "anchor-\(index)"
    }

    /// Mirrors BrowserView's parent callback after the overview reports a stable scroll position.
    private func commitScrollPosition(_ position: BrowserTabID?) {
        guard BrowserView.commitTabOverviewScrollPosition(
            position,
            store: store,
            adapter: scrollPosition,
        ) else {
            return
        }

        committedPositionCount += 1
    }

    private func handleOverviewExit(
        _ position: BrowserTabID?,
        _ action: BrowserTabOverviewExitAction,
    ) {
        commitScrollPosition(position)
        if case let .closeTab(tabID) = action {
            store.send(.closeTab(tabID))
        }

        BrowserView.synchronizeTabOverviewScrollPosition(store: store, adapter: scrollPosition)
    }
}

/// Exposes the production scroll-state snapshot to UI-test synchronization.
@MainActor
private struct BrowserTabOverviewRestoreSettlementLabel: View {
    @ObservedObject
    var observation: BrowserTabOverviewScrollObservation

    var body: some View {
        Text(observation.state.isSettled ? "settled" : "scrolling")
            .accessibilityIdentifier("browser.tab-overview.programmatic-restore-state")
    }
}

private struct ShowTabsPlacementConfiguration {
    enum SizeClass: String {
        case compact
        case regular

        var value: UserInterfaceSizeClass {
            self == .compact ? .compact : .regular
        }
    }

    enum Fixture: String {
        case a = "A"
        case b = "B"
        case c = "C"

        var selectedIndex: Int {
            switch self {
            case .a:
                8
            case .b:
                0
            case .c:
                8
            }
        }

        var anchorIndex: Int {
            switch self {
            case .a:
                0
            case .b:
                12
            case .c:
                8
            }
        }
    }

    let fixture: Fixture
    let sizeClass: SizeClass

    static var current: Self? {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("--show-tabs-placement") else {
            return nil
        }
        guard let value = argumentValue(
            prefix: "--show-tabs-placement-fixture=",
            in: arguments,
        ),
            let selectedFixture = Fixture(rawValue: value)
        else {
            return nil
        }

        let selectedSizeClass = argumentValue(
            prefix: "--show-tabs-placement-size-class=",
            in: arguments,
        ).flatMap(SizeClass.init(rawValue:)) ?? .regular

        return Self(fixture: selectedFixture, sizeClass: selectedSizeClass)
    }

    private static func argumentValue(prefix: String, in arguments: [String]) -> String? {
        arguments.first(where: { $0.hasPrefix(prefix) }).map {
            String($0.dropFirst(prefix.count))
        }
    }
}

/// Owns the stable fixture and observes the production transition branches for one UI-test launch.
@MainActor
private final class ShowTabsPlacementHostModel: ObservableObject {
    let store: StoreOf<BrowserFeature>
    let transitionCoordinator: BrowserTabTransitionUIKitCoordinator
    let scrollPosition: BrowserTabOverviewScrollPosition
    let scrollVisibility: BrowserTabOverviewScrollVisibility
    let status: ShowTabsPlacementStatus

    private let tabs: [BrowserTab]
    private let selectedTabID: BrowserTabID
    private let transitionRegistry: BrowserTabTransitionSurfaceRegistry

    init(configuration: ShowTabsPlacementConfiguration) {
        let initialTabs = (0 ..< 24).map { _ in BrowserTab.startPage(id: BrowserTabID()) }
        let initialSelectedTabID = initialTabs[configuration.fixture.selectedIndex].id
        let initialAnchorTabID = initialTabs[configuration.fixture.anchorIndex].id

        var state = BrowserFeature.State(
            tabs: initialTabs,
            selectedTabID: initialSelectedTabID,
        )
        state.profileLifecycle = .ready
        state.openTabsEntryLifecycle = .completed
        state.settings.preserveOpenTabs = false
        state.tabOverviewScrollPosition = initialAnchorTabID

        let initialScrollPosition = BrowserTabOverviewScrollPosition(
            persistedPosition: initialAnchorTabID,
        )
        let initialScrollVisibility = BrowserTabOverviewScrollVisibility()
        let initialStatus = ShowTabsPlacementStatus(
            fixture: configuration.fixture.rawValue,
            selectedIndex: configuration.fixture.selectedIndex,
            anchorIndex: configuration.fixture.anchorIndex,
            selectedTabID: initialSelectedTabID,
        )
        let diagnostics = BrowserTabTransitionDiagnostics(
            onExecution: { [weak initialStatus] execution in
                initialStatus?.record(execution: execution)
            },
            onAnimatorCreated: { [weak initialStatus] animator in
                initialStatus?.recordAnimatorCreated(animator)
            },
            onEvent: { [weak initialStatus] event in
                initialStatus?.record(event: event)
            },
        )
        let initialTransitionRegistry = BrowserTabTransitionSurfaceRegistry()
        let initialTransitionCoordinator = BrowserTabTransitionUIKitCoordinator(
            registry: initialTransitionRegistry,
            diagnostics: diagnostics,
        )

        tabs = initialTabs
        selectedTabID = initialSelectedTabID
        store = Store(initialState: state) {
            BrowserFeature()
        }
        transitionCoordinator = initialTransitionCoordinator
        scrollPosition = initialScrollPosition
        scrollVisibility = initialScrollVisibility
        status = initialStatus
        transitionRegistry = initialTransitionRegistry
    }

    func updateAnchor(_ anchor: BrowserTabID?) {
        status.updateAnchor(anchor.flatMap { tabID in
            tabs.firstIndex(where: { $0.id == tabID })
        })
    }

    func updateFullyVisibleTargetIDs(_ targetIDs: Set<BrowserTabID>) {
        status.updateContainment(
            targetIDs.contains(selectedTabID),
            scrollPhase: scrollPosition.scrollPhase,
        )
    }

    func updateRequestedTarget(_ target: BrowserTabID?) {
        let isSelectedTarget = target == selectedTabID
        status.updateRequestedTarget(isSelectedTarget)
        status.updateTransitionTarget(isSelectedTarget)
        status.updateLiveAnchor(scrollPosition.livePosition.flatMap { tabID in
            tabs.firstIndex(where: { $0.id == tabID })
        })
    }

    func refreshRegistryReadiness() {
        status.updateRegistryReadiness(
            transitionRegistry.isReady(for: .card(selectedTabID)),
        )
    }

    func updateScrollState(_ state: BrowserTabOverviewScrollState) {
        status.updateContainment(
            scrollVisibility.fullyVisibleTargetIDs.contains(selectedTabID),
            scrollPhase: state.phase,
        )
    }
}

/// Publishes only the scalar transition facts needed by the permanent UI regression.
@MainActor
private final class ShowTabsPlacementStatus: ObservableObject {
    struct Snapshot: Equatable {
        var fixture = ""
        var selected = 0
        var anchor: Int?
        var live: Int?
        var terminal = "pending"
        var execution = "none"
        var targetRequested = false
        var targetAttached = false
        var targetReady = false
        var targetContainedAtReady = false
        var readySettled = false
        var readyObservationCount = 0
        var readinessViolation = false
        var sawMissingDestination = false
        var sawPresentationUnavailable = false
        var animatorCreated = false
        var animatorCompleted = false
        var animatorCompletion = "pending"
        var scrollPhase = "idle"
        var targetContained = false
        var transitionActive = false
        var transitionRequestCount = 0
        var transitionReleaseCount = 0
        var transitionReleased = true
        var anchorChangeCount = 0
        var anchorMissing = false

        var label: String {
            [
                "fixture=\(fixture)",
                "selected=\(selected)",
                "anchor=\(anchor.map(String.init) ?? "nil")",
                "live=\(live.map(String.init) ?? "nil")",
                "terminal=\(terminal)",
                "execution=\(execution)",
                "targetRequested=\(targetRequested)",
                "targetAttached=\(targetAttached)",
                "targetReady=\(targetReady)",
                "targetContainedAtReady=\(targetContainedAtReady)",
                "readySettled=\(readySettled)",
                "readyObservationCount=\(readyObservationCount)",
                "readinessViolation=\(readinessViolation)",
                "sawMissingDestination=\(sawMissingDestination)",
                "sawPresentationUnavailable=\(sawPresentationUnavailable)",
                "animatorCreated=\(animatorCreated)",
                "animatorCompleted=\(animatorCompleted)",
                "animatorCompletion=\(animatorCompletion)",
                "scrollPhase=\(scrollPhase)",
                "targetContained=\(targetContained)",
                "transitionActive=\(transitionActive)",
                "transitionRequestCount=\(transitionRequestCount)",
                "transitionReleaseCount=\(transitionReleaseCount)",
                "transitionReleased=\(transitionReleased)",
                "anchorChangeCount=\(anchorChangeCount)",
                "anchorMissing=\(anchorMissing)",
            ].joined(separator: "|")
        }
    }

    @Published
    private(set) var snapshot: Snapshot

    private let selectedTabID: BrowserTabID

    init(
        fixture: String,
        selectedIndex: Int,
        anchorIndex: Int,
        selectedTabID: BrowserTabID,
    ) {
        self.selectedTabID = selectedTabID
        snapshot = Snapshot(
            fixture: fixture,
            selected: selectedIndex,
            anchor: anchorIndex,
        )
    }

    func record(execution: BrowserTabTransitionExecution) {
        mutate { snapshot in
            guard !snapshot.sawMissingDestination else {
                return
            }

            if case .missingDestination = execution {
                snapshot.sawMissingDestination = true
            }
            snapshot.execution =
                switch execution {
                case .geometry:
                    "geometry"
                case .reduceMotion:
                    "reduceMotion"
                case .missingSource:
                    "missingSource"
                case .missingDestination:
                    "missingDestination"
                case .aspectMismatch:
                    "aspectMismatch"
                }
        }
    }

    func record(event: BrowserTabTransitionEvent) {
        mutate { snapshot in
            switch event {
            case let .targetAttached(tabID):
                snapshot.targetAttached = tabID == selectedTabID
            case let .targetPresentationBlocked(tabID):
                if tabID == selectedTabID, !snapshot.sawPresentationUnavailable {
                    snapshot.terminal = "blocked"
                }
            case let .targetPresentationUnavailable(tabID):
                if tabID == selectedTabID {
                    snapshot.sawPresentationUnavailable = true
                    snapshot.terminal = "unavailable"
                }
            case let .targetPresentationReady(tabID):
                guard tabID == selectedTabID else {
                    return
                }

                captureReadinessIfNeeded(&snapshot)
            case .geometryAnimatorCreated:
                snapshot.animatorCreated = true
            case .destinationRevealed:
                if !snapshot.sawPresentationUnavailable {
                    snapshot.terminal = "revealed"
                }
            case .cloneRemoved:
                break
            }
        }
    }

    private func captureReadinessIfNeeded(_ snapshot: inout Snapshot) {
        guard !snapshot.targetReady else {
            return
        }

        snapshot.targetReady = true
        snapshot.readyObservationCount += 1
        snapshot.targetContainedAtReady = snapshot.targetContained
        snapshot.readySettled = snapshot.targetContained && snapshot.scrollPhase == "idle"
        if !snapshot.readySettled {
            snapshot.readinessViolation = true
        }
    }

    func recordAnimatorCreated(_ animator: UIViewPropertyAnimator) {
        mutate { $0.animatorCreated = true }
        animator.addCompletion { [weak self] position in
            Task { @MainActor [weak self] in
                self?.recordAnimatorCompletion(position)
            }
        }
    }

    func updateAnchor(_ index: Int?) {
        mutate { snapshot in
            snapshot.anchor = index
            snapshot.anchorChangeCount += 1
            snapshot.anchorMissing = snapshot.anchorMissing || index == nil
        }
    }

    func updateLiveAnchor(_ index: Int?) {
        mutate { $0.live = index }
    }

    func updateRequestedTarget(_ isSelectedTarget: Bool) {
        guard isSelectedTarget else {
            return
        }

        mutate { $0.targetRequested = true }
    }

    func updateTransitionTarget(_ isActive: Bool) {
        mutate { snapshot in
            guard isActive != snapshot.transitionActive else {
                return
            }

            snapshot.transitionActive = isActive
            if isActive {
                snapshot.transitionRequestCount += 1
                snapshot.transitionReleased = false
            } else {
                if snapshot.transitionRequestCount > 0 {
                    snapshot.transitionReleaseCount += 1
                }
                snapshot.transitionReleased = true
            }
        }
    }

    func updateRegistryReadiness(_ isReady: Bool) {
        guard isReady else {
            return
        }

        mutate { snapshot in
            captureReadinessIfNeeded(&snapshot)
        }
    }

    func updateContainment(_ isContained: Bool, scrollPhase: ScrollPhase) {
        let phase =
            switch scrollPhase {
            case .idle:
                "idle"
            case .tracking:
                "tracking"
            case .interacting:
                "interacting"
            case .decelerating:
                "decelerating"
            case .animating:
                "animating"
            @unknown default:
                "unknown"
            }
        mutate { snapshot in
            snapshot.targetContained = isContained
            snapshot.scrollPhase = phase
        }
    }

    private func recordAnimatorCompletion(_ position: UIViewAnimatingPosition) {
        mutate { snapshot in
            snapshot.animatorCompleted = position == .end
            snapshot.animatorCompletion =
                switch position {
                case .end:
                    "end"
                case .start:
                    "start"
                case .current:
                    "current"
                @unknown default:
                    "unknown"
                }
        }
    }

    private func mutate(_ update: (inout Snapshot) -> Void) {
        var next = snapshot
        update(&next)
        guard next != snapshot else {
            return
        }

        snapshot = next
    }
}

/// Hosts the real BrowserView for the genuine Show Tabs transition regression.
@MainActor
private struct ShowTabsPlacementHostView: View {
    let configuration: ShowTabsPlacementConfiguration

    @StateObject
    private var model: ShowTabsPlacementHostModel

    init(configuration: ShowTabsPlacementConfiguration) {
        self.configuration = configuration
        _model = StateObject(wrappedValue: ShowTabsPlacementHostModel(configuration: configuration))
    }

    var body: some View {
        BrowserView(
            store: model.store,
            transitionCoordinator: model.transitionCoordinator,
            scrollPosition: model.scrollPosition,
            scrollVisibility: model.scrollVisibility,
        )
        .overlay(alignment: .topLeading) {
            ShowTabsPlacementStatusView(status: model.status)
        }
        .onReceive(model.scrollVisibility.$fullyVisibleTargetIDs) {
            model.updateFullyVisibleTargetIDs($0)
            Task { @MainActor in
                model.refreshRegistryReadiness()
            }
        }
        .onReceive(model.scrollPosition.scrollObservation.$state) {
            model.updateScrollState($0)
            Task { @MainActor in
                model.refreshRegistryReadiness()
            }
        }
        .onReceive(model.transitionCoordinator.$lifecycleRevision) { _ in
            Task { @MainActor in
                model.refreshRegistryReadiness()
            }
        }
        .onReceive(model.scrollPosition.objectWillChange) { _ in
            Task { @MainActor in
                model.updateRequestedTarget(model.scrollPosition.transitionDrivenPosition)
            }
        }
        .onChange(of: model.store.state.tabOverviewScrollPosition) { _, anchor in
            model.updateAnchor(anchor)
        }
    }
}

@MainActor
private struct ShowTabsPlacementStatusView: View {
    @ObservedObject
    var status: ShowTabsPlacementStatus

    @Environment(\.horizontalSizeClass)
    private var horizontalSizeClass

    var body: some View {
        Text(status.snapshot.label + "|sizeClass=" + sizeClassName)
            .font(.caption2)
            .frame(width: 1, height: 1)
            .opacity(0.01)
            .allowsHitTesting(false)
            .accessibilityIdentifier("browser.show-tabs-placement.status")
    }

    private var sizeClassName: String {
        if horizontalSizeClass == .regular {
            "regular"
        } else if horizontalSizeClass == .compact {
            "compact"
        } else {
            "unspecified"
        }
    }
}
