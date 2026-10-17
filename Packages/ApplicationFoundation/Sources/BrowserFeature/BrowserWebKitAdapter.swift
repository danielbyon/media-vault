//
//  BrowserWebKitAdapter.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import CoreFoundation
import CoreGraphics
import Dispatch
import Foundation
import ObjectiveC
import Synchronization
import UIKit
import WebKit

/// Internal observation seam for proving WebKit surface ownership without production logging.
enum BrowserWebKitAttachmentEvent: Equatable {
    case attached(BrowserTabID)
    case detached(BrowserTabID)
}

/// Main-actor registry that exclusively owns live WebKit contexts keyed by logical tab IDs.
@MainActor
final class BrowserWebKitAdapter: NSObject {
    static let shared = BrowserWebKitAdapter(requiresProfileConfiguration: true)

    private var contexts: [BrowserTabID: Context] = [:]
    /// Logical IDs retired by a profile boundary cannot be recreated by delayed adapter work.
    private var retiredTabIDs: Set<BrowserTabID> = []
    private var browsingProfile: BrowserBrowsingProfile = .persistentPrivate
    private var ephemeralWebsiteDataStore: WKWebsiteDataStore?
    private var hasConfiguredProfile: Bool
    /// Internal fixture witnesses expose configuration and native error codes without URLs.
    var profileIsConfigured: Bool {
        hasConfiguredProfile
    }

    var nativeNavigationFailureObserver: (@MainActor (String, Int) -> Void)?
    private var continuations: [UUID: AsyncStream<BrowserWebKitEvent>.Continuation] = [:]
    private var popupOpenersThisTurn: Set<BrowserTabID> = []
    /// Shared-browser ownership survives view remounts and tab surface detachment.
    fileprivate let downloadOwner: BrowserDownloadOwner
    private let makeTabID: () -> BrowserTabID
    private let makeWebView: @MainActor (CGRect, WKWebViewConfiguration) -> WKWebView
    private let snapshotter: @MainActor (
        WKWebView,
        WKSnapshotConfiguration?,
        @escaping @Sendable (UIImage?, Error?) -> Void,
    ) -> Void

    /// Test-only observation seam for actual adapter attachment operations.
    var attachmentObserver: ((BrowserWebKitAttachmentEvent) -> Void)?

    /// Observes an actual native handoff after policy/origin validation. Tests retain only identity
    /// and origin observations; the callback does not admit, cancel or extend writer ownership.
    var downloadHandoffObserver: (@MainActor (WKDownload, BrowserTabID) -> Void)?

    init(
        requiresProfileConfiguration: Bool = false,
        downloadOwner: BrowserDownloadOwner? = nil,
        makeTabID: @escaping () -> BrowserTabID = BrowserTabID.init,
        makeWebView: @escaping @MainActor (CGRect, WKWebViewConfiguration) -> WKWebView = {
            frame,
            configuration in WKWebView(frame: frame, configuration: configuration)
        },
        snapshotter: @escaping @MainActor (
            WKWebView,
            WKSnapshotConfiguration?,
            @escaping @Sendable (UIImage?, Error?) -> Void,
        ) -> Void = { webView, configuration, completion in
            webView.takeSnapshot(with: configuration, completionHandler: completion)
        },
    ) {
        hasConfiguredProfile = !requiresProfileConfiguration
        self.downloadOwner = downloadOwner ?? .shared
        self.makeTabID = makeTabID
        self.makeWebView = makeWebView
        self.snapshotter = snapshotter
    }

    var contextCount: Int {
        contexts.count
    }

    /// Converts framework ownership only when the download still originates from the exact live tab.
    fileprivate func receiveDownload(
        _ download: WKDownload,
        tabID: BrowserTabID,
        association: BrowserWebKitDownloadAssociation.Handoff?,
    ) {
        guard !downloadOwner.owns(download) else {
            downloadOwner.releaseAdmissionReservation(association?.admissionToken)
            return
        }

        let transfer = BrowserWKDownloadTransfer(download: download, owner: downloadOwner)
        guard let association, let context = contexts[tabID], download.webView === context.webView else {
            downloadOwner.releaseAdmissionReservation(association?.admissionToken)
            downloadOwner.reject(transfer, notice: .invalidOrigin)
            return
        }

        downloadHandoffObserver?(download, tabID)
        if let id = downloadOwner.admit(transfer, tabID: tabID, using: association.admissionToken) {
            transfer.registered(id)
        }
    }

    func hasContext(for tabID: BrowserTabID) -> Bool {
        contexts[tabID] != nil
    }

    /// Returns an existing live surface without creating a new WebKit context.
    func webView(for tabID: BrowserTabID) -> WKWebView? {
        contexts[tabID]?.webView
    }

    /// Reports whether the adapter-owned context has committed its current document.
    func hasCommittedDocument(for tabID: BrowserTabID) -> Bool {
        contexts[tabID]?.hasCommittedDocument == true
    }

    /// Test-only seam that queues the same deferred metadata work used by KVO observations.
    func scheduleMetadataEmissionForTesting(for tabID: BrowserTabID) -> Task<Bool, Never>? {
        contexts[tabID]?.scheduleMetadataEmissionForTesting()
    }

    /// Creates a context even for an unselected background tab and returns an existing one unchanged.
    @discardableResult
    func ensureContext(for tabID: BrowserTabID) -> WKWebView {
        precondition(hasConfiguredProfile, "WebKit contexts require an acknowledged Browser profile")
        precondition(!retiredTabIDs.contains(tabID), "A retired Browser tab cannot create a WebKit context")
        if let context = contexts[tabID] {
            return context.webView
        }
        return createContext(tabID: tabID, configuration: configured(WKWebViewConfiguration())).webView
    }

    /// Creates a context only while its logical tab belongs to the active Browser session.
    func ensureActiveContext(for tabID: BrowserTabID) -> WKWebView? {
        guard hasConfiguredProfile,
              !retiredTabIDs.contains(tabID)
        else {
            return nil
        }

        return ensureContext(for: tabID)
    }

    /// Resolves tab-owned modal UI and releases the tab's platform context.
    func destroyContext(for tabID: BrowserTabID) {
        downloadOwner.revokeTab(tabID)
        guard let context = contexts.removeValue(forKey: tabID) else {
            return
        }

        context.resolvePendingDialog()
        context.releasePendingDownloadReservations()
        context.adapter = nil
        context.webView.stopLoading()
        context.webView.navigationDelegate = nil
        context.webView.uiDelegate = nil
        context.webView.removeFromSuperview()
    }

    /// Attaches the registry-owned surface without transferring its ownership to reducer state.
    func attach(tabID: BrowserTabID, to container: UIView) {
        guard let webView = ensureActiveContext(for: tabID) else {
            return
        }
        guard webView.superview !== container else {
            return
        }

        webView.removeFromSuperview()
        webView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            webView.topAnchor.constraint(equalTo: container.topAnchor),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        attachmentObserver?(.attached(tabID))
    }

    /// Detaches only the visual surface; background loading remains adapter-owned.
    func detach(tabID: BrowserTabID, from container: UIView) {
        if contexts[tabID]?.webView.superview === container {
            contexts[tabID]?.webView.removeFromSuperview()
            attachmentObserver?(.detached(tabID))
        }
    }

    /// Executes a reducer command containing only stable identity and Sendable values.
    func execute(_ command: BrowserWebKitCommand) {
        switch command {
        case let .configureProfile(profile, retiringTabIDs):
            configureProfile(profile, retiringTabIDs: retiringTabIDs)
        case let .ensureContext(id):
            guard hasConfiguredProfile,
                  !retiredTabIDs.contains(id)
            else {
                return
            }

            _ = ensureContext(for: id)
        case let .destroyContext(id):
            destroyContext(for: id)
        case let .load(id, url, operationID):
            guard hasConfiguredProfile,
                  !retiredTabIDs.contains(id)
            else {
                return
            }

            let context = ensureContextObject(for: id)
            context.load(url, operationID: operationID)
        case let .goBack(id, operationID):
            contexts[id]?.goBack(operationID: operationID)
        case let .goForward(id, operationID):
            contexts[id]?.goForward(operationID: operationID)
        case let .reload(id, operationID):
            contexts[id]?.reload(operationID: operationID)
        case let .stop(id):
            contexts[id]?.webView.stopLoading()
        case let .showBackForwardList(id, direction):
            guard let context = contexts[id] else {
                return
            }

            emit(.backForwardEntries(
                tabID: id,
                direction: direction,
                entries: context.projectedBackForwardEntries(direction),
            ))
        case let .find(id, query):
            contexts[id]?.webView.find(query) { _ in }
        case let .goToBackForwardEntry(id, token, operationID):
            contexts[id]?.goToBackForwardEntry(token, operationID: operationID)
        case let .capturePreview(id, revision):
            guard let webView = contexts[id]?.webView else {
                emit(.preview(tabID: id, revision: revision, pngData: nil))
                return
            }

            snapshotter(webView, nil) { [weak self] image, _ in
                MainActor.assumeIsolated {
                    self?.emit(.preview(
                        tabID: id,
                        revision: revision,
                        pngData: image?.pngData(),
                    ))
                }
            }
        case let .dismissJavaScriptDialog(id):
            contexts[id]?.resolvePendingDialog()
        }
    }

    func makeEventStream() -> AsyncStream<BrowserWebKitEvent> {
        let streamID = UUID()
        return AsyncStream { continuation in
            continuations[streamID] = continuation
            continuation.onTermination = { @Sendable [weak self] _ in
                Task { @MainActor in self?.continuations.removeValue(forKey: streamID) }
            }
        }
    }

    /// Ignores replacement-navigation cancellation and maps genuine failures to stable categories.
    static func navigationError(_ error: Error, failingURL: URL) -> BrowserNavigationError? {
        let code = (error as NSError).code
        guard code != NSURLErrorCancelled else {
            return nil
        }

        switch code {
        case NSURLErrorNotConnectedToInternet:
            return .noInternet(failingURL)
        case NSURLErrorCannotFindHost,
             NSURLErrorDNSLookupFailed:
            return .serverNotFound(failingURL)
        case NSURLErrorCannotConnectToHost,
             NSURLErrorNetworkConnectionLost:
            return .connectionFailed(failingURL)
        default:
            return .pageCouldNotLoad(failingURL)
        }
    }

    fileprivate func emit(_ event: BrowserWebKitEvent) {
        for continuation in continuations.values {
            continuation.yield(event)
        }
    }

    func makePopup(openerID: BrowserTabID, configuration: WKWebViewConfiguration, url: URL?) -> WKWebView {
        let tabID = makeTabID()
        let context = createContext(tabID: tabID, configuration: configured(configuration))
        let foreground = popupOpenersThisTurn.insert(openerID).inserted
        if foreground {
            DispatchQueue.main.async { [weak self] in self?.popupOpenersThisTurn.remove(openerID) }
        }
        guard let destination = url ?? URL(string: "about:blank") else {
            preconditionFailure("WebKit's about:blank URL must be representable")
        }

        emit(.siteCreatedTab(
            openerID: openerID,
            tabID: tabID,
            url: destination,
            foreground: foreground,
        ))
        return context.webView
    }

    private func ensureContextObject(for tabID: BrowserTabID) -> Context {
        if let context = contexts[tabID] {
            return context
        }

        return createContext(tabID: tabID, configuration: configured(WKWebViewConfiguration()))
    }

    private func createContext(tabID: BrowserTabID, configuration: WKWebViewConfiguration) -> Context {
        precondition(hasConfiguredProfile, "WebKit contexts require an acknowledged Browser profile")
        let webView = makeWebView(.zero, configuration)
        webView.allowsBackForwardNavigationGestures = true
        let context = Context(tabID: tabID, webView: webView, adapter: self)
        webView.navigationDelegate = context
        webView.uiDelegate = context
        contexts[tabID] = context
        return context
    }

    private func configured(_ configuration: WKWebViewConfiguration) -> WKWebViewConfiguration {
        configuration.allowsPictureInPictureMediaPlayback = false
        configuration.allowsAirPlayForMediaPlayback = false
        configuration.websiteDataStore = websiteDataStore
        return configuration
    }

    /// Changes the app-wide WebKit profile after releasing every context from the previous profile.
    private func configureProfile(
        _ profile: BrowserBrowsingProfile,
        retiringTabIDs: [BrowserTabID],
    ) {
        guard profile != browsingProfile || !retiringTabIDs.isEmpty else {
            hasConfiguredProfile = true
            return
        }

        downloadOwner.revokeAll()
        let ownedTabIDs = Array(contexts.keys)
        retiredTabIDs.formUnion(retiringTabIDs)
        retiredTabIDs.formUnion(ownedTabIDs)
        ownedTabIDs.forEach(destroyContext(for:))
        browsingProfile = profile
        ephemeralWebsiteDataStore = profile == .ephemeral ? WKWebsiteDataStore.nonPersistent() : nil
        hasConfiguredProfile = true
    }

    private var websiteDataStore: WKWebsiteDataStore {
        switch browsingProfile {
        case .persistentPrivate:
            return WKWebsiteDataStore.default()
        case .ephemeral:
            guard let ephemeralWebsiteDataStore else {
                preconditionFailure("An Ephemeral profile must own a session website data store")
            }

            return ephemeralWebsiteDataStore
        }
    }
}

/// Adapter-private token registry for projected WebKit back-forward items.
@MainActor
final class BrowserBackForwardTokenRegistry<Item: AnyObject> {
    private var items: [BrowserBackForwardEntry.Token: Item] = [:]

    func rebuild(_ newItems: [Item]) -> [BrowserBackForwardEntry.Token] {
        items.removeAll(keepingCapacity: true)
        return newItems.map { item in
            let token = BrowserBackForwardEntry.Token()
            items[token] = item
            return token
        }
    }

    func resolve(_ token: BrowserBackForwardEntry.Token) -> Item? {
        items[token]
    }

    func invalidate() {
        items.removeAll(keepingCapacity: true)
    }
}

/// Adapter-private availability model for the public WebKit link context menu.
enum BrowserWebKitLinkContextMenu {
    static let actions: [BrowserLinkContextAction] = [
        .open,
        .openInNewTab,
        .copyLink,
        .shareLink,
    ]

    static func actions(for linkURL: URL?) -> [BrowserLinkContextAction] {
        linkURL == nil ? [] : actions
    }
}

/// Projects the URL of WebKit's authoritative current history item into app-visible metadata.
///
/// `WKWebView.url` can change for same-document navigation and provisional loads. The history
/// item's URL is the public WebKit source that distinguishes committed navigation from a failed
/// provisional destination.
struct BrowserWebKitCommittedURLProjection: Equatable, Sendable {
    private(set) var committedURL: URL?

    init(committedURL: URL? = nil) {
        self.committedURL = committedURL
    }

    mutating func update(authoritativeCurrentItemURL: URL?) {
        guard let authoritativeCurrentItemURL else {
            return
        }

        committedURL = authoritativeCurrentItemURL
    }
}

/// Retains only a weak identity handle, so retiring a navigation does not extend its lifetime.
private final class BrowserWebKitNavigationReference {
    weak var value: AnyObject?

    init(_ value: AnyObject) {
        self.value = value
    }
}

/// A consistent snapshot of one WebKit context's navigation correlation state.
///
/// WebKit KVO change handlers are not main-actor-isolated, so they cannot read the correlation
/// tracker directly. They capture this snapshot instead and re-validate it on the main actor before
/// emitting metadata, which keeps a delayed observation from being attributed to a later navigation.
struct BrowserWebKitMetadataEpoch: Sendable {
    /// Correlation generation that was current when the observation was delivered.
    let generation: Int

    /// Reducer operation that supplied metadata for that generation, when one was active.
    let operationID: BrowserNavigationOperationID?
}

/// Publishes the metadata epoch of one WebKit context to nonisolated observers.
///
/// The correlation tracker changes only on the main actor and republishes the resulting epoch after
/// every change. Nonisolated WebKit observations read the latest published epoch without touching
/// main-actor state.
final class BrowserWebKitMetadataEpochStore: Sendable {
    private let epoch = Mutex(BrowserWebKitMetadataEpoch(generation: 0, operationID: nil))

    /// Records the epoch that matches the tracker state after a correlation change.
    func publish(generation: Int, operationID: BrowserNavigationOperationID?) {
        epoch.withLock {
            $0 = BrowserWebKitMetadataEpoch(generation: generation, operationID: operationID)
        }
    }

    /// Returns the epoch the main actor published most recently.
    func snapshot() -> BrowserWebKitMetadataEpoch {
        epoch.withLock { $0 }
    }
}

/// A download policy decision is consumed once even when its top-level navigation was superseded.
/// Each decision has its own reservation identity; subframes do not borrow main-navigation state.
@MainActor
struct BrowserWebKitDownloadAssociation {
    struct Handoff {
        let admissionToken: BrowserDownloadOwner.AdmissionToken?
        let completion: BrowserWebKitNavigationCorrelation.Completion?
    }

    let reservationID: UUID
    let conversion: BrowserWebKitNavigationCorrelation.DownloadConversion?
    let admissionToken: BrowserDownloadOwner.AdmissionToken?
    private var consumed = false

    init(
        conversion: BrowserWebKitNavigationCorrelation.DownloadConversion?,
        admissionToken: BrowserDownloadOwner.AdmissionToken? = nil,
    ) {
        reservationID = UUID()
        self.conversion = conversion
        self.admissionToken = admissionToken
    }

    mutating func consume(correlation: inout BrowserWebKitNavigationCorrelation) -> Handoff? {
        guard !consumed else {
            return nil
        }

        consumed = true
        return Handoff(
            admissionToken: admissionToken,
            completion: conversion.flatMap { correlation.settleDownloadConversion($0) },
        )
    }
}

/// Tracks policy objects without retaining them past WebKit's conversion or cancellation callback.
/// A dead policy object identifies only its own abandoned reservation; main-navigation completion
/// is matched separately through the conversion generation.
@MainActor
struct BrowserWebKitDownloadAssociationRegistry {
    @MainActor
    private final class Entry {
        weak var policyObject: AnyObject?
        let association: BrowserWebKitDownloadAssociation

        init(policyObject: AnyObject, association: BrowserWebKitDownloadAssociation) {
            self.policyObject = policyObject
            self.association = association
        }
    }

    private var entries: [UUID: Entry] = [:]

    mutating func insert(_ association: BrowserWebKitDownloadAssociation, forPolicyObject policyObject: AnyObject) {
        entries[association.reservationID] = Entry(policyObject: policyObject, association: association)
    }

    mutating func take(forPolicyObject policyObject: AnyObject) -> BrowserWebKitDownloadAssociation? {
        guard let reservationID = entries.first(where: { $0.value.policyObject === policyObject })?.key else {
            return nil
        }

        return entries.removeValue(forKey: reservationID)?.association
    }

    @discardableResult
    mutating func releaseAbandonedAssociations(owner: BrowserDownloadOwner?) -> [UUID] {
        let reservationIDs = entries.compactMap { $0.value.policyObject == nil ? $0.key : nil }
        release(reservationIDs, owner: owner)
        return reservationIDs
    }

    mutating func releaseReservations(
        forFinishedNavigation completion: BrowserWebKitNavigationCorrelation.Completion,
        owner: BrowserDownloadOwner?,
    ) {
        releaseReservations(forNavigationGeneration: completion.navigationGeneration, owner: owner)
    }

    mutating func releaseReservations(forNavigationGeneration generation: Int, owner: BrowserDownloadOwner?) {
        let reservationIDs = entries.compactMap { entry in
            entry.value.association.conversion?.navigationGeneration == generation ? entry.key : nil
        }
        release(reservationIDs, owner: owner)
    }

    mutating func releaseAll(owner: BrowserDownloadOwner?) {
        release(Array(entries.keys), owner: owner)
    }

    func contains(reservationID: UUID) -> Bool {
        entries[reservationID] != nil
    }

    private mutating func release(_ reservationIDs: [UUID], owner: BrowserDownloadOwner?) {
        for reservationID in reservationIDs {
            guard let entry = entries.removeValue(forKey: reservationID) else {
                continue
            }

            owner?.releaseAdmissionReservation(entry.association.admissionToken)
        }
    }
}

/// Keeps one WebKit context's reducer-operation identity and delegate-navigation lifecycle together.
///
/// WebKit may deliver callbacks for an older navigation after a newer command has been issued, and
/// some history commands complete without returning a `WKNavigation` at all. Keeping those cases
/// in one tracker makes the accepted-current-navigation rule explicit at every delegate boundary.
///
/// The internal tracker accepts opaque reference objects because it compares identity only and
/// never calls navigation APIs. Production delegates supply WebKit-created `WKNavigation` objects;
/// deterministic tests can supply ordinary reference tokens without constructing native navigations.
/// Weak retirement handles preserve the same lifetime and `ObjectIdentifier` rules for both.
@MainActor
struct BrowserWebKitNavigationCorrelation {
    /// Captured at the policy boundary, independent of later KVO and registration epochs.
    struct DownloadConversion: Equatable {
        fileprivate let navigationGeneration: Int
        let operationID: BrowserNavigationOperationID?
    }

    struct Completion {
        let operationID: BrowserNavigationOperationID?
        let navigationGeneration: Int
    }

    private(set) var hasCommittedDocument = false
    private var wasCommittedBeforeNavigation = false
    private var activeNavigationIdentifier: ObjectIdentifier?
    /// Keeps synchronous command callbacks from being mistaken for untracked external starts.
    private var isAwaitingNavigationRegistration = false
    private var hasActiveUnidentifiedNavigation = false
    private var operationIDs: [ObjectIdentifier: BrowserNavigationOperationID] = [:]
    private var activeNavigationReference: BrowserWebKitNavigationReference?
    private var supersededNavigations: [BrowserWebKitNavigationReference] = []
    private(set) var generation = 0
    private var navigationGeneration = 0
    private var pendingOperationID: BrowserNavigationOperationID?
    private var downloadConversionIsPending = false
    private var downloadConversionIsSettled = false
    private var convertedNavigations: [BrowserWebKitNavigationReference] = []

    /// Returns the generation used to match pending download conversions to navigation callbacks.
    fileprivate func currentNavigationGeneration() -> Int {
        navigationGeneration
    }

    var hasActiveNavigation: Bool {
        isAwaitingNavigationRegistration || activeNavigationIdentifier != nil || hasActiveUnidentifiedNavigation
    }

    /// Conversion never publishes provisional metadata as a newly committed page.
    var acceptsMetadataObservations: Bool {
        !downloadConversionIsPending
    }

    /// Accepts fresh observations after settlement while rejecting work queued under an older epoch.
    func acceptsMetadataObservation(_ epoch: BrowserWebKitMetadataEpoch) -> Bool {
        acceptsMetadataObservations && epoch.generation == generation
    }

    /// Lock-protected mirror of this tracker's epoch, read by nonisolated WebKit observations.
    private let metadataEpoch: BrowserWebKitMetadataEpochStore

    init(metadataEpoch: BrowserWebKitMetadataEpochStore = .init()) {
        self.metadataEpoch = metadataEpoch
        publishMetadataEpoch()
    }

    private mutating func pruneSupersededNavigations() {
        supersededNavigations.removeAll { $0.value == nil }
    }

    private mutating func rememberSupersededNavigation(_ navigation: AnyObject?) {
        pruneSupersededNavigations()
        guard let navigation else {
            return
        }

        supersededNavigations.append(.init(navigation))
    }

    mutating func beginNavigation(operationID: BrowserNavigationOperationID) {
        rememberSupersededNavigation(activeNavigationReference?.value)
        wasCommittedBeforeNavigation = hasCommittedDocument || wasCommittedBeforeNavigation
        hasCommittedDocument = false
        activeNavigationIdentifier = nil
        activeNavigationReference = nil
        isAwaitingNavigationRegistration = true
        hasActiveUnidentifiedNavigation = false
        operationIDs.removeAll(keepingCapacity: true)
        pendingOperationID = operationID
        navigationGeneration &+= 1
        downloadConversionIsPending = false
        downloadConversionIsSettled = false
        generation &+= 1
        publishMetadataEpoch()
    }

    /// Registers the navigation returned by a command. Returns `false` for a synchronous no-op.
    mutating func register(
        _ navigation: AnyObject?,
        operationID: BrowserNavigationOperationID,
    ) -> Bool {
        // A synchronous conversion can settle before the command returns its WKNavigation.
        // That return must not revive the consumed operation or emit page-completion metadata.
        guard pendingOperationID == operationID else {
            rememberSupersededNavigation(navigation)
            return true
        }

        isAwaitingNavigationRegistration = false
        pendingOperationID = nil
        generation &+= 1
        if downloadConversionIsSettled {
            if let navigation {
                convertedNavigations.append(.init(navigation))
            }
            publishMetadataEpoch()
            return true
        }
        guard let navigation else {
            // A policy handoff is still outstanding; nil is not an ordinary history no-op.
            if downloadConversionIsPending {
                publishMetadataEpoch()
                return true
            }
            hasCommittedDocument = wasCommittedBeforeNavigation
            publishMetadataEpoch()
            return false
        }

        let navigationIdentifier = ObjectIdentifier(navigation)
        discardSupersededNavigation(navigation)
        activeNavigationIdentifier = navigationIdentifier
        activeNavigationReference = .init(navigation)
        operationIDs[navigationIdentifier] = operationID
        hasActiveUnidentifiedNavigation = false
        publishMetadataEpoch()
        return true
    }

    /// Accepts an unregistered navigation created outside the reducer command path.
    mutating func acceptExternalNavigation(_ navigation: AnyObject?) -> Bool {
        if navigation == nil {
            guard !isAwaitingNavigationRegistration else {
                return false
            }
            guard activeNavigationIdentifier == nil,
                  !hasActiveUnidentifiedNavigation
            else {
                return false
            }

            rememberSupersededNavigation(activeNavigationReference?.value)
            wasCommittedBeforeNavigation = hasCommittedDocument || wasCommittedBeforeNavigation
            hasCommittedDocument = false
            operationIDs.removeAll(keepingCapacity: true)
            activeNavigationIdentifier = nil
            activeNavigationReference = nil
            hasActiveUnidentifiedNavigation = true
            navigationGeneration &+= 1
            downloadConversionIsPending = false
            downloadConversionIsSettled = false
            generation &+= 1
            publishMetadataEpoch()
            return true
        }
        guard let navigation else {
            return false
        }

        let navigationIdentifier = ObjectIdentifier(navigation)
        pruneSupersededNavigations()
        convertedNavigations.removeAll { $0.value == nil }
        guard !isAwaitingNavigationRegistration,
              !convertedNavigations.contains(where: { $0.value === navigation }),
              !supersededNavigations.contains(where: { $0.value === navigation }),
              operationIDs[navigationIdentifier] == nil,
              activeNavigationIdentifier != navigationIdentifier
        else {
            return false
        }

        // Retire the previous identity, including a conversion awaiting its didBecome callback.
        // A distinct provisional start owns a new generation; the old policy capture cannot settle it.
        if downloadConversionIsPending, let converted = activeNavigationReference?.value {
            convertedNavigations.append(.init(converted))
        } else {
            rememberSupersededNavigation(activeNavigationReference?.value)
        }
        wasCommittedBeforeNavigation = hasCommittedDocument || wasCommittedBeforeNavigation
        hasCommittedDocument = false
        operationIDs.removeAll(keepingCapacity: true)
        activeNavigationIdentifier = navigationIdentifier
        activeNavigationReference = .init(navigation)
        hasActiveUnidentifiedNavigation = false
        navigationGeneration &+= 1
        downloadConversionIsPending = false
        downloadConversionIsSettled = false
        generation &+= 1
        publishMetadataEpoch()
        return true
    }

    func isCurrent(_ navigation: AnyObject?) -> Bool {
        guard !downloadConversionIsPending, !downloadConversionIsSettled else {
            return false
        }

        if let navigation {
            guard let activeNavigationIdentifier else {
                return false
            }

            return ObjectIdentifier(navigation) == activeNavigationIdentifier
        }

        return hasActiveUnidentifiedNavigation
    }

    mutating func commit(_ navigation: AnyObject?) -> Bool {
        guard isCurrent(navigation) else {
            return false
        }

        hasCommittedDocument = true
        return true
    }

    mutating func finish(_ navigation: AnyObject?) -> Completion? {
        guard isCurrent(navigation) else {
            return nil
        }

        let completedNavigationGeneration = navigationGeneration
        hasCommittedDocument = true
        if navigation == nil {
            hasActiveUnidentifiedNavigation = false
            return Completion(operationID: nil, navigationGeneration: completedNavigationGeneration)
        }

        clearActiveNavigation()
        return Completion(
            operationID: consumeOperationID(for: navigation),
            navigationGeneration: completedNavigationGeneration,
        )
    }

    func operationID(for navigation: AnyObject?) -> BrowserNavigationOperationID? {
        guard let navigation else {
            return nil
        }

        return operationIDs[ObjectIdentifier(navigation)]
    }

    /// Returns the operation whose navigation is currently supplying KVO metadata.
    ///
    /// KVO does not carry a `WKNavigation`, but metadata emitted after a correlated commit still
    /// belongs to that operation until its delegate finish callback consumes the identity.
    func currentOperationID() -> BrowserNavigationOperationID? {
        guard !downloadConversionIsSettled else {
            return nil
        }
        guard let activeNavigationIdentifier else {
            return pendingOperationID
        }

        return operationIDs[activeNavigationIdentifier]
    }

    /// Freezes the initiating operation before calling a WebKit download policy decision handler.
    mutating func captureDownloadConversion() -> DownloadConversion {
        downloadConversionIsPending = true
        generation &+= 1
        publishMetadataEpoch()
        return .init(navigationGeneration: navigationGeneration, operationID: currentOperationID())
    }

    /// Settles only the captured navigation; duplicates and older handoffs cannot finish newer work.
    mutating func settleDownloadConversion(_ capture: DownloadConversion) -> Completion? {
        guard capture.navigationGeneration == navigationGeneration,
              downloadConversionIsPending, !downloadConversionIsSettled
        else {
            return nil
        }

        if let navigation = activeNavigationReference?.value {
            convertedNavigations.append(.init(navigation))
        }
        activeNavigationIdentifier = nil
        activeNavigationReference = nil
        hasActiveUnidentifiedNavigation = false
        operationIDs.removeAll(keepingCapacity: true)
        hasCommittedDocument = wasCommittedBeforeNavigation
        downloadConversionIsPending = false
        downloadConversionIsSettled = true
        generation &+= 1
        publishMetadataEpoch()
        return .init(
            operationID: capture.operationID,
            navigationGeneration: capture.navigationGeneration,
        )
    }

    /// Republishes the epoch that nonisolated WebKit observations capture before hopping onto the
    /// main actor. Every change that moves the generation or the active operation calls this, so the
    /// published snapshot always describes the state the main actor validates against.
    private func publishMetadataEpoch() {
        metadataEpoch.publish(generation: generation, operationID: currentOperationID())
    }

    mutating func consumeOperationID(for navigation: AnyObject?) -> BrowserNavigationOperationID? {
        guard let navigation else {
            return nil
        }

        if downloadConversionIsPending, ObjectIdentifier(navigation) == activeNavigationIdentifier {
            return nil
        }
        guard let operationID = operationIDs.removeValue(forKey: ObjectIdentifier(navigation)) else {
            return nil
        }

        generation &+= 1
        publishMetadataEpoch()
        return operationID
    }

    mutating func markFinished(_ navigation: AnyObject?) {
        guard isCurrent(navigation) else {
            return
        }

        if navigation == nil {
            hasActiveUnidentifiedNavigation = false
            generation &+= 1
            publishMetadataEpoch()
            return
        }

        clearActiveNavigation()
    }

    private mutating func clearActiveNavigation() {
        rememberSupersededNavigation(activeNavigationReference?.value)
        activeNavigationIdentifier = nil
        activeNavigationReference = nil
        publishMetadataEpoch()
    }

    mutating func discardSupersededNavigation(_ navigation: AnyObject?) {
        guard let navigation else {
            return
        }

        supersededNavigations.removeAll { $0.value === navigation || $0.value == nil }
    }

    mutating func processTerminated() {
        hasCommittedDocument = false
        wasCommittedBeforeNavigation = false
        pendingOperationID = nil
        navigationGeneration &+= 1
        downloadConversionIsPending = false
        downloadConversionIsSettled = false
        convertedNavigations.removeAll(keepingCapacity: true)
        isAwaitingNavigationRegistration = false
        hasActiveUnidentifiedNavigation = false
        activeNavigationIdentifier = nil
        operationIDs.removeAll(keepingCapacity: true)
        activeNavigationReference = nil
        supersededNavigations.removeAll(keepingCapacity: true)
        generation &+= 1
        publishMetadataEpoch()
    }
}

/// Classifies responses without substituting a request or changing inline displayable content.
enum BrowserWebKitDownloadPolicy {
    static func responseRequiresDownload(canShowMIMEType: Bool, contentDisposition: String?) -> Bool {
        let disposition = contentDisposition?.split(separator: ";", maxSplits: 1)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return !canShowMIMEType || disposition == "attachment"
    }
}

@MainActor
private final class Context: NSObject, WKNavigationDelegate, WKUIDelegate {
    let tabID: BrowserTabID
    let webView: WKWebView
    weak var adapter: BrowserWebKitAdapter?
    private weak var downloadOwner: BrowserDownloadOwner?
    var hasCommittedDocument: Bool {
        navigationCorrelation.hasCommittedDocument
    }

    private var pendingDialogResolution: (() -> Void)?
    private var observations: [NSKeyValueObservation] = []
    private nonisolated let metadataEpoch: BrowserWebKitMetadataEpochStore
    private var navigationCorrelation: BrowserWebKitNavigationCorrelation
    private var committedURLProjection = BrowserWebKitCommittedURLProjection()
    private let backForwardTokens = BrowserBackForwardTokenRegistry<WKBackForwardListItem>()
    private var downloadAssociations = BrowserWebKitDownloadAssociationRegistry()

    init(tabID: BrowserTabID, webView: WKWebView, adapter: BrowserWebKitAdapter) {
        let metadataEpochStore = BrowserWebKitMetadataEpochStore()
        metadataEpoch = metadataEpochStore
        self.tabID = tabID
        self.webView = webView
        self.adapter = adapter
        downloadOwner = adapter.downloadOwner
        navigationCorrelation = BrowserWebKitNavigationCorrelation(metadataEpoch: metadataEpochStore)
        super.init()
        observations = [
            webView.observe(\.isLoading, options: [.initial, .new]) { [weak self] _, _ in
                _ = self?.scheduleMetadataEmission()
            },
            webView.observe(\.estimatedProgress, options: [.new]) { [weak self] _, _ in
                _ = self?.scheduleMetadataEmission()
            },
            webView.observe(\.canGoBack, options: [.new]) { [weak self] _, _ in
                _ = self?.scheduleMetadataEmission()
            },
            webView.observe(\.canGoForward, options: [.new]) { [weak self] _, _ in
                _ = self?.scheduleMetadataEmission()
            },
            webView.observe(\.title, options: [.new]) { [weak self] _, _ in
                _ = self?.scheduleMetadataEmission()
            },
            webView.observe(\.url, options: [.new]) { [weak self] _, _ in
                _ = self?.scheduleMetadataEmission()
            },
        ]
    }

    func projectedBackForwardEntries(_ direction: BrowserNavigationDirection) -> [BrowserBackForwardEntry] {
        let items = direction == .back ? webView.backForwardList.backList : webView.backForwardList.forwardList
        let tokens = backForwardTokens.rebuild(items)
        return zip(tokens, items).map { token, item in
            BrowserBackForwardEntry(token: token, title: item.title, url: item.url)
        }
    }

    func load(_ url: URL, operationID: BrowserNavigationOperationID) {
        navigationCorrelation.beginNavigation(operationID: operationID)
        invalidateBackForwardTokens()
        let navigation = webView.load(URLRequest(url: url))
        register(navigation, operationID: operationID)
    }

    func goToBackForwardEntry(
        _ token: BrowserBackForwardEntry.Token,
        operationID: BrowserNavigationOperationID,
    ) {
        guard let item = backForwardTokens.resolve(token) else {
            navigationCorrelation.beginNavigation(operationID: operationID)
            register(nil, operationID: operationID)
            return
        }

        backForwardTokens.invalidate()
        navigationCorrelation.beginNavigation(operationID: operationID)
        register(webView.go(to: item), operationID: operationID)
    }

    func invalidateBackForwardTokens() {
        backForwardTokens.invalidate()
    }

    func goBack(operationID: BrowserNavigationOperationID) {
        navigationCorrelation.beginNavigation(operationID: operationID)
        invalidateBackForwardTokens()
        register(webView.goBack(), operationID: operationID)
    }

    func goForward(operationID: BrowserNavigationOperationID) {
        navigationCorrelation.beginNavigation(operationID: operationID)
        invalidateBackForwardTokens()
        register(webView.goForward(), operationID: operationID)
    }

    func reload(operationID: BrowserNavigationOperationID) {
        navigationCorrelation.beginNavigation(operationID: operationID)
        invalidateBackForwardTokens()
        register(webView.reload(), operationID: operationID)
    }

    func webView(
        _: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @MainActor (WKNavigationActionPolicy) -> Void,
    ) {
        guard navigationAction.shouldPerformDownload else {
            decisionHandler(.allow)
            return
        }
        guard let association = captureDownloadAssociation(
            isMainFrame: navigationAction.targetFrame?.isMainFrame == true,
        ) else {
            decisionHandler(.cancel)
            return
        }

        downloadAssociations.insert(association, forPolicyObject: navigationAction)
        decisionHandler(.download)
    }

    func webView(
        _: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @MainActor (WKNavigationResponsePolicy) -> Void,
    ) {
        let disposition = (navigationResponse.response as? HTTPURLResponse)?
            .value(forHTTPHeaderField: "Content-Disposition")
        guard BrowserWebKitDownloadPolicy.responseRequiresDownload(
            canShowMIMEType: navigationResponse.canShowMIMEType,
            contentDisposition: disposition,
        ) else {
            decisionHandler(.allow)
            return
        }
        guard let association = captureDownloadAssociation(isMainFrame: navigationResponse.isForMainFrame) else {
            decisionHandler(.cancel)
            return
        }

        downloadAssociations.insert(association, forPolicyObject: navigationResponse)
        decisionHandler(.download)
    }

    func webView(_: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        releaseAbandonedDownloadAssociations()
        let associated = consumeDownloadAssociation(downloadAssociations.take(forPolicyObject: navigationAction))
        handoff(download, association: associated)
    }

    func webView(_: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        releaseAbandonedDownloadAssociations()
        let associated = consumeDownloadAssociation(downloadAssociations.take(forPolicyObject: navigationResponse))
        handoff(download, association: associated)
    }

    private func captureDownloadConversion() -> BrowserWebKitNavigationCorrelation.DownloadConversion {
        if !navigationCorrelation.hasActiveNavigation,
           navigationCorrelation.acceptExternalNavigation(nil) {
            adapter?.emit(.navigationStarted(tabID: tabID))
        }
        return navigationCorrelation.captureDownloadConversion()
    }

    /// Reserves capacity before asking WebKit to create a native writer. A denied main-frame
    /// conversion is settled immediately so cancellation cannot leave navigation state loading.
    private func captureDownloadAssociation(isMainFrame: Bool) -> BrowserWebKitDownloadAssociation? {
        releaseAbandonedDownloadAssociations()
        let admissionToken: BrowserDownloadOwner.AdmissionToken?
        if let downloadOwner {
            guard let token = downloadOwner.captureAdmissionToken(for: tabID) else {
                if isMainFrame {
                    _ = consumeDownloadAssociation(
                        BrowserWebKitDownloadAssociation(conversion: captureDownloadConversion()),
                    )
                }
                return nil
            }

            admissionToken = token
        } else {
            admissionToken = nil
        }

        let conversion = isMainFrame ? captureDownloadConversion() : nil
        return BrowserWebKitDownloadAssociation(
            conversion: conversion,
            admissionToken: admissionToken,
        )
    }

    /// Releases policy-time slots that WebKit cannot hand off after a tab or process ends.
    func releasePendingDownloadReservations() {
        downloadAssociations.releaseAll(owner: downloadOwner)
    }

    /// Releases main-frame conversions for a navigation that finished or failed without handoff.
    /// Subframe reservations are released by their exact policy-object terminal callback instead.
    private func releasePendingDownloadReservations(forNavigationGeneration generation: Int) {
        downloadAssociations.releaseReservations(forNavigationGeneration: generation, owner: downloadOwner)
    }

    private func releasePendingDownloadReservations(
        forFinishedNavigation completion: BrowserWebKitNavigationCorrelation.Completion,
    ) {
        downloadAssociations.releaseReservations(forFinishedNavigation: completion, owner: downloadOwner)
    }

    private func releaseAbandonedDownloadAssociations() {
        _ = downloadAssociations.releaseAbandonedAssociations(owner: downloadOwner)
    }

    private func consumeDownloadAssociation(
        _ association: BrowserWebKitDownloadAssociation?,
    ) -> BrowserWebKitDownloadAssociation.Handoff? {
        guard var association,
              let handoff = association.consume(correlation: &navigationCorrelation)
        else {
            return nil
        }

        if let completion = handoff.completion {
            adapter?.emit(.navigationConvertedToDownload(
                tabID: tabID,
                correlation: completion.operationID.map { .operation($0) } ?? .untracked,
            ))
        }
        return handoff
    }

    private func handoff(_ download: WKDownload, association: BrowserWebKitDownloadAssociation.Handoff?) {
        if let adapter {
            adapter.receiveDownload(download, tabID: tabID, association: association)
        } else {
            guard let owner = downloadOwner else {
                download.cancel { _ in }
                return
            }
            guard !owner.owns(download) else {
                owner.releaseAdmissionReservation(association?.admissionToken)
                return
            }

            owner.releaseAdmissionReservation(association?.admissionToken)
            owner.reject(BrowserWKDownloadTransfer(download: download, owner: owner), notice: .invalidOrigin)
        }
    }

    func webView(_: WKWebView, didStartProvisionalNavigation navigation: WKNavigation?) {
        // A command registers its WKNavigation immediately after issuing the WebKit call. The
        // correlation tracker rejects callbacks from that registration window and from known or
        // stale navigations. Outside that window, a nil callback represents an untracked external
        // navigation because WebKit supplied no identity to correlate.
        guard navigationCorrelation.acceptExternalNavigation(navigation) else {
            navigationCorrelation.discardSupersededNavigation(navigation)
            return
        }

        adapter?.emit(.navigationStarted(tabID: tabID))
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation?) {
        guard navigationCorrelation.commit(navigation) else {
            navigationCorrelation.discardSupersededNavigation(navigation)
            return
        }

        backForwardTokens.invalidate()
        committedURLProjection.update(authoritativeCurrentItemURL: webView.backForwardList.currentItem?.url)
        // didCommit proves document ownership even for same-URL reloads. This event updates
        // the conversion recovery snapshot without finishing loading or invalidating previews.
        let operationID = navigationCorrelation.operationID(for: navigation)
        adapter?.emit(.navigationCommitted(
            tabID: tabID,
            metadata: currentMetadata(),
            correlation: operationID.map { .operation($0) } ?? .untracked,
        ))
    }

    func webView(_: WKWebView, didFinish navigation: WKNavigation?) {
        releaseAbandonedDownloadAssociations()
        guard let completion = navigationCorrelation.finish(navigation) else {
            navigationCorrelation.discardSupersededNavigation(navigation)
            _ = navigationCorrelation.consumeOperationID(for: navigation)
            return
        }

        releasePendingDownloadReservations(forFinishedNavigation: completion)
        backForwardTokens.invalidate()
        emitMetadata(operationID: completion.operationID)
    }

    func webView(_: WKWebView, didFail navigation: WKNavigation?, withError error: Error) {
        releaseAbandonedDownloadAssociations()
        let nativeError = error as NSError
        adapter?.nativeNavigationFailureObserver?(nativeError.domain, nativeError.code)
        guard navigationCorrelation.isCurrent(navigation) else {
            navigationCorrelation.discardSupersededNavigation(navigation)
            _ = navigationCorrelation.consumeOperationID(for: navigation)
            return
        }

        releasePendingDownloadReservations(forNavigationGeneration: navigationCorrelation.currentNavigationGeneration())
        emit(error, navigation: navigation)
    }

    func webView(
        _: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation?,
        withError error: Error,
    ) {
        releaseAbandonedDownloadAssociations()
        let nativeError = error as NSError
        adapter?.nativeNavigationFailureObserver?(nativeError.domain, nativeError.code)
        guard navigationCorrelation.isCurrent(navigation) else {
            navigationCorrelation.discardSupersededNavigation(navigation)
            _ = navigationCorrelation.consumeOperationID(for: navigation)
            return
        }

        releasePendingDownloadReservations(forNavigationGeneration: navigationCorrelation.currentNavigationGeneration())
        emit(error, navigation: navigation)
    }

    func webViewWebContentProcessDidTerminate(_: WKWebView) {
        releasePendingDownloadReservations()
        navigationCorrelation.processTerminated()
        adapter?.emit(.processTerminated(tabID: tabID))
    }

    func webView(
        _: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures _: WKWindowFeatures,
    ) -> WKWebView? {
        adapter?.makePopup(openerID: tabID, configuration: configuration, url: navigationAction.request.url)
    }

    func webView(
        _: WKWebView,
        contextMenuConfigurationForElement elementInfo: WKContextMenuElementInfo,
        completionHandler: @MainActor (UIContextMenuConfiguration?) -> Void,
    ) {
        guard let url = elementInfo.linkURL else {
            // Returning nil preserves WebKit's native editing and non-link context menus.
            completionHandler(nil)
            return
        }

        let actions = BrowserWebKitLinkContextMenu.actions(for: url)

        let configuration = UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            UIMenu(title: "", children: actions.compactMap { self?.linkAction($0, url: url) })
        }
        completionHandler(configuration)
    }

    private func linkAction(_ action: BrowserLinkContextAction, url: URL) -> UIAction {
        let title =
            switch action {
            case .open:
                "Open"
            case .openInNewTab:
                "Open in New Tab"
            case .copyLink:
                "Copy Link"
            case .shareLink:
                "Share Link"
            }

        return UIAction(title: title) { [weak self] _ in
            guard let self else {
                return
            }

            adapter?.emit(.linkContextAction(tabID: tabID, action: action, url: url))
        }
    }

    func webViewDidClose(_: WKWebView) {
        adapter?.emit(.scriptCloseRequested(tabID: tabID))
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame _: WKFrameInfo,
        completionHandler: @escaping @MainActor () -> Void,
    ) {
        present(
            .alert,
            title: webView.url?.host,
            message: message,
        ) { _ in completionHandler() }
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame _: WKFrameInfo,
        completionHandler: @escaping @MainActor (Bool) -> Void,
    ) {
        present(
            .confirm,
            title: webView.url?.host,
            message: message,
        ) { action in completionHandler(action == .ok) }
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptTextInputPanelWithPrompt prompt: String,
        defaultText: String?,
        initiatedByFrame _: WKFrameInfo,
        completionHandler: @escaping @MainActor (String?) -> Void,
    ) {
        guard let presenter = webView.window?.rootViewController else {
            completionHandler(nil)
            return
        }

        let alert = UIAlertController(title: webView.url?.host, message: prompt, preferredStyle: .alert)
        alert.addTextField { $0.text = defaultText }
        pendingDialogResolution = { [weak alert] in alert?.dismiss(animated: false)
            completionHandler(nil)
        }
        for action in BrowserJavaScriptDialogPresentation.prompt.actions {
            switch action {
            case .cancel:
                alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { [weak self] _ in
                    self?.finish { completionHandler(nil) }
                })
            case .ok:
                alert.addAction(UIAlertAction(title: "OK", style: .default) { [weak self, weak alert] _ in
                    self?.finish { completionHandler(alert?.textFields?.first?.text) }
                })
            }
        }
        adapter?.emit(.javaScriptDialogChanged(tabID: tabID, isPresented: true))
        presenter.present(alert, animated: true)
    }

    func resolvePendingDialog() {
        pendingDialogResolution?()
        pendingDialogResolution = nil
    }

    private func present(
        _ presentation: BrowserJavaScriptDialogPresentation,
        title: String?,
        message: String,
        completion: @escaping @MainActor (BrowserJavaScriptDialogAction) -> Void,
    ) {
        let fallbackAction = presentation.actions.contains(.cancel) ? BrowserJavaScriptDialogAction.cancel : .ok
        guard let presenter = webView.window?.rootViewController else {
            completion(fallbackAction)
            return
        }

        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        pendingDialogResolution = { [weak alert] in alert?.dismiss(animated: false)
            completion(fallbackAction)
        }
        for action in presentation.actions {
            let actionTitle = action == .cancel ? "Cancel" : "OK"
            let style: UIAlertAction.Style = action == .cancel ? .cancel : .default
            alert.addAction(UIAlertAction(title: actionTitle, style: style) { [weak self] _ in
                self?.finish { completion(action) }
            })
        }
        adapter?.emit(.javaScriptDialogChanged(tabID: tabID, isPresented: true))
        presenter.present(alert, animated: true)
    }

    private func finish(_ completion: () -> Void) {
        pendingDialogResolution = nil
        completion()
        adapter?.emit(.javaScriptDialogChanged(tabID: tabID, isPresented: false))
    }

    /// Testing seam: schedules the metadata emission a WebKit observation would schedule now.
    ///
    /// The captured epoch matches what a nonisolated WebKit observation reads from `metadataEpoch`,
    /// so a test can invalidate the correlation afterwards and observe the emission being discarded.
    fileprivate func scheduleMetadataEmissionForTesting() -> Task<Bool, Never> {
        scheduleMetadataEmission()
    }

    /// Schedules a metadata emission for the correlation epoch that is current when it is called.
    ///
    /// WebKit delivers KVO change notifications to nonisolated handlers, so the epoch is captured
    /// through the context's thread-safe store before the work crosses onto the main actor. The
    /// emission is discarded unless the captured generation is still current, which keeps a delayed
    /// notification from being attributed to a later navigation.
    private nonisolated func scheduleMetadataEmission() -> Task<Bool, Never> {
        let epoch = metadataEpoch.snapshot()
        return Task { @MainActor [weak self] in
            self?.performMetadataEmission(for: epoch) ?? false
        }
    }

    /// Emits metadata for an observation epoch unless its generation is no longer current.
    private func performMetadataEmission(for epoch: BrowserWebKitMetadataEpoch) -> Bool {
        guard navigationCorrelation.acceptsMetadataObservation(epoch) else {
            return false
        }

        emitMetadata(operationID: epoch.operationID)
        return true
    }

    /// Reads the current document projection; only delegate didCommit proves commit ownership.
    private func currentMetadata() -> BrowserTab.Metadata {
        synchronizeCommittedURL()
        return BrowserTab.Metadata(
            committedURL: committedURLProjection.committedURL,
            title: webView.title,
            isLoading: webView.isLoading,
            estimatedProgress: webView.estimatedProgress,
            canGoBack: webView.canGoBack,
            canGoForward: webView.canGoForward,
        )
    }

    private func emitMetadata(operationID: BrowserNavigationOperationID? = nil) {
        let correlation: BrowserWebKitEventCorrelation = operationID.map { .operation($0) }
            ?? .untracked
        adapter?.emit(.metadata(
            tabID: tabID,
            metadata: currentMetadata(),
            correlation: correlation,
        ))
    }

    private func synchronizeCommittedURL() {
        let previousURL = committedURLProjection.committedURL
        committedURLProjection.update(authoritativeCurrentItemURL: webView.backForwardList.currentItem?.url)
        if committedURLProjection.committedURL != previousURL {
            backForwardTokens.invalidate()
        }
    }

    private func emit(_ error: Error, navigation: WKNavigation?) {
        let url = (error as NSError).userInfo[NSURLErrorFailingURLErrorKey] as? URL ?? webView.url
        let operationID = navigationCorrelation.operationID(for: navigation)
        guard let url, let mapped = BrowserWebKitAdapter.navigationError(error, failingURL: url) else {
            // WebKit reports user cancellation as an unmapped navigation error. It still must
            // complete the reducer-issued operation or the preview lifecycle remains pending.
            emitMetadata(operationID: operationID)
            navigationCorrelation.markFinished(navigation)
            _ = navigationCorrelation.consumeOperationID(for: navigation)
            return
        }

        let correlation: BrowserWebKitEventCorrelation = operationID
            .map { .operation($0) }
            ?? .untracked
        adapter?.emit(.navigationFailed(
            tabID: tabID,
            error: mapped,
            correlation: correlation,
        ))
        navigationCorrelation.markFinished(navigation)
        _ = navigationCorrelation.consumeOperationID(for: navigation)
    }

    private func register(
        _ navigation: WKNavigation?,
        operationID: BrowserNavigationOperationID,
    ) {
        if !navigationCorrelation.register(navigation, operationID: operationID) {
            // History can change between the reducer reading its metadata and this command
            // reaching WebKit. A synchronous no-op still completes with the command identity.
            emitMetadata(operationID: operationID)
        }
    }
}
