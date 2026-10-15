//
//  BrowserDownloadHTTPTests.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import ComposableArchitecture
import CoreFoundation
import CoreGraphics
import CryptoKit
import Dependencies
import Foundation
import ObjectiveC
import Testing
import UIKit
import WebKit
@testable import BrowserFeature

extension AppHostedUITests {
    /// Real native policies and delegates against one loopback origin. No delegate calls, requests,
    /// cookies or completed bytes are manufactured by the fixture after navigation starts.
    @Suite("Originating WebKit HTTP downloads")
    @MainActor
    struct BrowserDownloadHTTPTests {
        @Test("Non-Root adapter commits one first page at Root WebKit geometry")
        func nonRootAdapterCommitsFirstPageAtRootGeometry() async throws {
            try await withSinglePageHTTPDownloadFixture { fixture, firstURL in
                let selectedTab = fixture.store.selectedTab
                let tab = try #require(selectedTab)
                let firstRouteRequests = fixture.server.requests.filter { issue42RouteName($0.path) == "first" }
                let matchingGET = firstRouteRequests.contains { $0.method == "GET" }
                let windowSize = fixture.window.bounds.size
                let webViewSize = fixture.webView.bounds.size
                let titleMatches = tab.metadata.title == "Issue42 first"
                let committed = fixture.adapter.hasCommittedDocument(for: fixture.tabID)
                let attached = fixture.webView.window === fixture.window
                let reducerReady = tab.metadata.committedURL == firstURL && !tab.metadata.isLoading
                let nativeReady = !fixture.webView.isLoading
                let halfPixelInPoints = 0.5 / fixture.window.traitCollection.displayScale
                let sizeMatches = windowSize.width == 390 && windowSize.height == 844
                    && webViewSize.width == 390
                    && abs(webViewSize.height - 520.6667) <= halfPixelInPoints

                #expect(sizeMatches)
                #expect(firstRouteRequests.count == 1)
                #expect(matchingGET)
                #expect(reducerReady)
                #expect(titleMatches)
                #expect(nativeReady)
                #expect(attached)
                #expect(committed)
                #expect(fixture.observations.nativeErrors.isEmpty)
                #expect(fixture.adapter.webView(for: fixture.tabID) === fixture.webView)
            }
        }

        @Test("Fresh native initial page commits with command and transport witnesses")
        func initialPageCommits() async throws {
            try await withHTTPDownloadFixture(.ephemeral) { fixture in
                #expect(fixture.adapter.hasCommittedDocument(for: fixture.tabID))
                #expect(fixture.server.requests.count >= 2)
            }
        }

        @Test(
            "Native HTTP classification and request ownership",
            arguments:
            [BrowserBrowsingProfile.persistentPrivate, .ephemeral],
            HTTPDownloadCase.allCases,
        )
        func originatingMatrix(profile: BrowserBrowsingProfile, row: HTTPDownloadCase) async throws {
            try await withHTTPDownloadFixture(profile) { fixture in
                let before = try #require(fixture.store.selectedTab?.metadata)
                let selected = fixture.store.selectedTabID
                let tabIDs = fixture.store.tabs.map(\.id)
                try await fixture.trigger(row)
                if row == .inline {
                    try await fixture.wait("inline PDF commits without download") {
                        fixture.store.selectedTab?.metadata.committedURL == fixture.inlineURL
                            && fixture.store.selectedTab?.metadata.isLoading == false
                    }
                    #expect(fixture.owner.snapshot.records.isEmpty)
                    #expect(fixture.observations.handoffs.isEmpty)
                    #expect(fixture.observations.conversions == 0)
                } else {
                    try await fixture.wait("completed native download and reducer conversion") {
                        fixture.owner.snapshot.records.first?.isReady == true
                            && fixture.observations.conversions == 1
                            && fixture.store.selectedTab?.metadata.isLoading == false
                            && fixture.store.previewState.operation(for: fixture.tabID) == nil
                    }
                    fixture.assertPreservedDocument(before)
                    #expect(fixture.observations.handoffs.count == 1)
                    #expect(fixture.observations.handoffs.allSatisfy { $0.sameOrigin && $0.tabID == fixture.tabID })
                    #expect(Set(fixture.observations.handoffs.map(\.identity)).count == 1)
                    #expect(fixture.owner.activeCount == 0)
                    #expect(fixture.owner.retainedCount == 1)
                    try fixture.verifyCompletedFile()
                }
                fixture.assertNativeRequest(row)
                #expect(fixture.observations.failures == 0)
                #expect(fixture.store.selectedTabID == selected)
                #expect(fixture.store.tabs.map(\.id) == tabIDs)
                #expect(fixture.adapter.contextCount == 1)
                #expect(fixture.adapter.webView(for: fixture.tabID) === fixture.webView)
                #expect(fixture.webView.window === fixture.window)
            }
        }

        @Test(
            "Slow native progress excludes partial files and cancellation waits for writer acknowledgement",
            arguments:
            [BrowserBrowsingProfile.persistentPrivate, .ephemeral],
            [true, false],
        )
        func slowCancellation(profile: BrowserBrowsingProfile, knownLength: Bool) async throws {
            try await withHTTPDownloadFixture(profile) { fixture in
                let before = try #require(fixture.store.selectedTab?.metadata)
                let route = knownLength ? "slow-known" : "slow-unknown"
                try fixture.store.send(.navigate(fixture.server.url(route)))
                try await fixture.wait("owner receives native progress while server remainder is held") {
                    fixture.server.slowPrefixSent && (fixture.owner.snapshot.records.first?.receivedBytes ?? 0) > 0
                }
                let partial = try #require(fixture.owner.snapshot.records.first)
                #expect(!partial.isReady)
                #expect(partial.filename == nil)
                #expect(partial.receivedBytes < Int64(fixture.server.payload.count))
                if knownLength {
                    #expect(partial.expectedBytes == Int64(fixture.server.payload.count))
                } else {
                    #expect(partial.expectedBytes == nil)
                }
                fixture.owner.execute(.init(snapshot: fixture.owner.snapshot, action: .present(partial.id, .share)))
                #expect(fixture.owner.snapshot.presentation == nil)
                #expect(fixture.owner.activeCount == 1)
                fixture.owner.execute(.init(snapshot: fixture.owner.snapshot, action: .cancel(partial.id)))
                #expect(fixture.owner.snapshot.records.isEmpty)
                try await fixture.wait("native cancellation acknowledged and scratch removed") {
                    fixture.owner.activeCount == 0 && fixture.owner.retainedCount == 0
                        && !fixture.owner.privacyCleanupPending
                        && fixture.store.downloads.records.isEmpty
                }
                let received = fixture.observations
                    .snapshots
                    .flatMap(\.records)
                    .filter { $0.id == partial.id }
                    .map(\.receivedBytes)
                #expect(zip(received, received.dropFirst()).allSatisfy { $0 <= $1 })
                #expect(!received.isEmpty)
                #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.scratchRoot.path).isEmpty)
                #expect(fixture.observations.conversions == 1)
                #expect(fixture.observations.failures == 0)
                fixture.assertPreservedDocument(before)
            }
        }
    }
}

private func issue42RouteName(_ requestPath: String) -> String {
    let lastComponent = requestPath.split(separator: "/").last ?? ""
    return String(lastComponent.split(separator: "?", maxSplits: 1).first ?? "")
}

enum HTTPDownloadCase: String, CaseIterable, Sendable {
    case attachment
    case inline
    case octet
    case redirect
    case protected
    case post
    case blob
    case attribute
}

@MainActor
private func withHTTPDownloadFixture(
    _ profile: BrowserBrowsingProfile,
    body: (HTTPDownloadFixture) async throws -> Void,
) async throws {
    let fixture = try HTTPDownloadFixture(profile: profile)
    do {
        try await fixture.prepare()
        try await body(fixture)
    } catch {
        await fixture.remove()
        throw error
    }
    await fixture.remove()
}

@MainActor
private func withSinglePageHTTPDownloadFixture(
    body: (HTTPDownloadFixture, URL) async throws -> Void,
) async throws {
    let fixture = try HTTPDownloadFixture(
        profile: .persistentPrivate,
        nativeContentSize: CGSize(width: 390, height: 520.6667),
    )
    do {
        let firstURL = try await fixture.prepareSingleFirstPage()
        try await body(fixture, firstURL)
    } catch {
        await fixture.remove()
        throw error
    }
    await fixture.remove()
}

/// Observations retain stable identities and projections, never a WKDownload or its source path.
@MainActor
private final class HTTPDownloadObservations {
    struct Handoff {
        let identity: ObjectIdentifier
        let tabID: BrowserTabID
        let sameOrigin: Bool
    }

    weak var origin: WKWebView?
    var subscribed = false
    var commands: [BrowserWebKitCommand] = []
    var nativeErrors: [String] = []
    var handoffs: [Handoff] = []
    var events: [BrowserWebKitEvent] = []
    var snapshots: [BrowserDownloadSnapshot] = []

    var conversions: Int {
        events.count {
            if case .navigationConvertedToDownload = $0 {
                true
            } else {
                false
            }
        }
    }

    var failures: Int {
        events.count {
            if case .navigationFailed = $0 {
                true
            } else {
                false
            }
        }
    }

    func execute(_ command: BrowserWebKitCommand, adapter: BrowserWebKitAdapter) {
        commands.append(command)
        adapter.execute(command)
    }

    func webKitStream(_ adapter: BrowserWebKitAdapter) -> AsyncStream<BrowserWebKitEvent> {
        let upstream = adapter.makeEventStream()
        subscribed = true
        return AsyncStream { continuation in
            let pump = Task { @MainActor in
                for await event in upstream {
                    self.events.append(event)
                    continuation.yield(event)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in pump.cancel() }
        }
    }

    func downloadStream(_ owner: BrowserDownloadOwner) -> AsyncStream<BrowserDownloadSnapshot> {
        let upstream = owner.subscribe()
        return AsyncStream { continuation in
            let pump = Task { @MainActor in
                for await snapshot in upstream {
                    self.snapshots.append(snapshot)
                    continuation.yield(snapshot)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in pump.cancel() }
        }
    }
}

/// One real tab, adapter, reducer and scene-backed window per row. The simulator injection replaces
/// only unsupported native protection readback; ownership, regular-file, size and backup verification
/// still use the real filesystem. Physical runs keep the default native verifier.
@MainActor
private final class HTTPDownloadFixture {
    let server: Issue42LoopbackServer
    let scratchRoot: URL
    let owner: BrowserDownloadOwner
    let adapter: BrowserWebKitAdapter
    let store: StoreOf<BrowserFeature>
    let tabID = BrowserTabID()
    let window: UIWindow
    let webView: WKWebView
    let observations = HTTPDownloadObservations()
    private var subscription: StoreTask?
    private(set) var inlineURL: URL?
    private var requestedPage: URL?

    init(profile: BrowserBrowsingProfile, nativeContentSize: CGSize? = nil) throws {
        server = try Issue42LoopbackServer()
        scratchRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
            "Issue42HTTP-\(UUID().uuidString)",
            isDirectory: true,
        )
        let scratch: BrowserDownloadScratchStore
        #if targetEnvironment(simulator)
        scratch = BrowserDownloadScratchStore(root: scratchRoot, verifyProtection: { _ in })
        #else
        scratch = BrowserDownloadScratchStore(root: scratchRoot)
        #endif
        let fixtureOwner = BrowserDownloadOwner(store: scratch)
        owner = fixtureOwner
        let fixtureAdapter = BrowserWebKitAdapter(requiresProfileConfiguration: true, downloadOwner: fixtureOwner)
        adapter = fixtureAdapter
        fixtureAdapter.execute(.configureProfile(profile: profile, retiringTabIDs: []))
        fixtureOwner.installAuthorization { true }
        let recorder = observations
        fixtureAdapter.nativeNavigationFailureObserver = { [weak recorder] domain, code in
            recorder?.nativeErrors.append("\(domain):\(code)")
        }
        let webKit = BrowserWebKitClient(
            execute: { await recorder.execute($0, adapter: fixtureAdapter) },
            events: { await recorder.webKitStream(fixtureAdapter) },
        )
        let downloads = BrowserDownloadClient(
            execute: { await fixtureOwner.execute($0) },
            events: { await recorder.downloadStream(fixtureOwner) },
        )
        var initial = BrowserFeature.State(initialTabID: tabID)
        initial.profileLifecycle = .ready
        initial.settings.browsingProfile = profile
        initial.settings.preserveOpenTabs = false
        store = withDependencies {
            $0.uuid = .incrementing
            $0.browserWebKit = webKit
            $0.browserDownloads = downloads
        } operation: {
            Store(initialState: initial) { BrowserFeature() }
        }
        let controller = UIViewController()
        window = UIKitTestSupport.makeWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        let attachmentView: UIView
        if let nativeContentSize {
            let nativeContentView = UIView(frame: CGRect(origin: .zero, size: nativeContentSize))
            controller.view.addSubview(nativeContentView)
            attachmentView = nativeContentView
        } else {
            attachmentView = controller.view
        }
        adapter.attach(tabID: tabID, to: attachmentView)
        webView = try #require(adapter.webView(for: tabID))
        observations.origin = webView
        adapter.downloadHandoffObserver = { [weak recorder] download, tabID in
            recorder?.handoffs.append(.init(
                identity: ObjectIdentifier(download),
                tabID: tabID,
                sameOrigin: download.webView === recorder?.origin,
            ))
        }
        controller.view.layoutIfNeeded()
        subscription = store.send(.task)
    }

    func prepareSingleFirstPage() async throws -> URL {
        try await server.start()
        try await waitForSinglePageControl("event subscription and active hosting scene") {
            observations.subscribed && window.windowScene?.activationState == .foregroundActive
                && adapter.profileIsConfigured && store.downloads.revision == owner.snapshot.revision
        }
        let firstURL = try server.url("first")
        requestedPage = firstURL
        store.send(.navigate(firstURL))
        try await waitForSinglePageControl("native page committed: first") {
            store.selectedTab?.metadata.committedURL == firstURL
                && store.selectedTab?.metadata.title == "Issue42 first"
                && store.selectedTab?.metadata.isLoading == false && !webView.isLoading
                && webView.window === window && adapter.hasCommittedDocument(for: tabID)
        }
        return firstURL
    }

    private func waitForSinglePageControl(
        _ milestone: String,
        until predicate: @MainActor () -> Bool,
    ) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !predicate(), Date() < deadline {
            window.rootViewController?.view.layoutIfNeeded()
            await Task.yield()
        }
        try #require(
            predicate(),
            Comment(
                rawValue:
                "Timed out: \(milestone) requests=\(server.requests.count) "
                    + "accepted=\(server.acceptedCount) subscribed=\(observations.subscribed) "
                    + "profileReady=\(adapter.profileIsConfigured) "
                    + "committed=\(adapter.hasCommittedDocument(for: tabID)) "
                    + "reducerLoading=\(String(describing: store.selectedTab?.metadata.isLoading)) "
                    + "nativeLoading=\(webView.isLoading) attached=\(webView.window === window) "
                    + "bounds=\(webView.bounds.size) errors=\(observations.nativeErrors.count)",
            ),
        )
    }

    func prepare() async throws {
        try await server.start()
        inlineURL = try server.url("inline")
        try await wait("event subscription and actual active hosting scene") {
            observations.subscribed && window.windowScene?.activationState == .foregroundActive
                && store.downloads.revision == owner.snapshot.revision
        }
        try await loadPage("first")
        try await loadPage("committed")
        #expect(store.selectedTab?.metadata.canGoBack == true)
        #expect(adapter.hasCommittedDocument(for: tabID))
    }

    private func loadPage(_ route: String) async throws {
        let url = try server.url(route)
        requestedPage = url
        store.send(.navigate(url))
        try await wait("native page committed: \(route)") {
            store.selectedTab?.metadata.committedURL == url && store.selectedTab?.metadata.title == "Issue42 \(route)"
                && store.selectedTab?.metadata.isLoading == false && !webView.isLoading
                && adapter.hasCommittedDocument(for: tabID)
        }
    }

    func trigger(_ row: HTTPDownloadCase) async throws {
        switch row {
        case .attribute:
            try await script("document.getElementById('attribute').click()")
        case .post:
            try await script("document.getElementById('post').submit()")
        case .blob:
            try await script("void startBlob()")
        default:
            try store.send(.navigate(server.url(row.rawValue)))
        }
    }

    private func script(_ text: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            webView.evaluateJavaScript(text) { _, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    func assertPreservedDocument(_ before: BrowserTab.Metadata) {
        let after = store.selectedTab?.metadata
        #expect(after?.committedURL == before.committedURL)
        #expect(after?.title == before.title)
        #expect(after?.canGoBack == before.canGoBack)
        #expect(after?.canGoForward == before.canGoForward)
        #expect(after?.isLoading == false)
        #expect(store.previewState.operation(for: tabID) == nil)
        #expect(adapter.hasCommittedDocument(for: tabID))
    }

    func assertNativeRequest(_ row: HTTPDownloadCase) {
        let suffix = row == .blob ? "blob-bytes" : row.rawValue
        let matches = server.requests.filter { $0.path == server.cookiePath + suffix }
        #expect(!matches.isEmpty)
        if row == .post {
            #expect(matches.allSatisfy { $0.method == "POST" && $0.body == Data("fixture=\(server.namespace)".utf8) })
        } else {
            #expect(matches.allSatisfy { $0.method == "GET" || $0.method == "HEAD" })
        }
        if row == .protected {
            #expect(matches
                .allSatisfy { ($0.headers["cookie"] ?? "").contains("\(server.cookieName)=\(server.cookieValue)") })
        }
        if row == .redirect {
            #expect(server.requests.contains { $0.path == server.cookiePath + "attachment" })
        }
    }

    func verifyCompletedFile() throws {
        let record = try #require(owner.snapshot.records.first)
        #expect(record.receivedBytes == Int64(server.payload.count))
        owner.execute(.init(snapshot: owner.snapshot, action: .present(record.id, .share)))
        let request = try #require(owner.snapshot.presentation)
        let url = try #require(owner.presentationURL(for: request))
        let bytes = try Data(contentsOf: url)
        #expect(bytes.count == server.payload.count)
        #expect(SHA256.hash(data: bytes) == SHA256.hash(data: server.payload))
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect(attributes[.type] as? FileAttributeType == .typeRegular)
        #expect(attributes[.ownerAccountID] as? UInt32 == getuid())
        #expect(try url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
        #if !targetEnvironment(simulator)
        try BrowserDownloadScratchStore.verifyNativeProtection(url)
        #endif
        owner.execute(.init(snapshot: owner.snapshot, action: .dismissPresentation(request.requestID)))
        owner.execute(.init(snapshot: owner.snapshot, action: .discard(record.id)))
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(owner.snapshot.records.isEmpty)
        #expect(owner.retainedCount == 0)
    }

    func wait(_ milestone: String, _ predicate: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !predicate(), Date() < deadline {
            window.rootViewController?.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(
            predicate(),
            Comment(
                rawValue:
                "\(milestone): requests=\(server.requests.count) handoffs=\(observations.handoffs.count) "
                    + "conversions=\(observations.conversions) failures=\(observations.failures) active=\(owner.activeCount) "
                    + "records=\(owner.snapshot.records.count) notice=\(String(describing: owner.snapshot.notice))"
                    + " accepted=\(server.acceptedCount) ready=\(server.ready) profileReady=\(adapter.profileIsConfigured)"
                    + " commands=\(String(describing: observations.commands)) pending=\(String(describing: store.pendingWebAction))"
                    + " content=\(String(describing: store.selectedTab?.content)) expectedURL=\(String(describing: requestedPage))"
                    + " attached=\(webView.window === window) bounds=\(webView.bounds) loading=\(webView.isLoading)"
                    + " nativeURL=\(String(describing: webView.url)) events=\(observations.events.count)"
                    + " nativeErrors=\(observations.nativeErrors)",
            ),
        )
    }

    func remove() async {
        owner.invalidateAuthorization()
        subscription?.cancel()
        adapter.destroyContext(for: tabID)
        adapter.downloadHandoffObserver = nil
        adapter.nativeNavigationFailureObserver = nil
        server.stop()
        let cookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
        for cookie in cookies where cookie.name == server.cookieName && cookie.path == server.cookiePath {
            webView.configuration.websiteDataStore.httpCookieStore.delete(cookie)
        }
        window.isHidden = true
        window.rootViewController = nil
        let deadline = Date().addingTimeInterval(5)
        while owner.privacyCleanupPending, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        #expect(
            !owner.privacyCleanupPending,
            "Native writer must acknowledge cancellation before fixture scratch removal",
        )
        if !owner.privacyCleanupPending {
            try? FileManager.default.removeItem(at: scratchRoot)
        }
    }
}
