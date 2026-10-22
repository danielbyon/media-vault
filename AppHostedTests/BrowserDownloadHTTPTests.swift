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
        @Test("Active polling budget charges work and discounts only sleep overrun")
        func activePollingBudgetChargesWorkAndDiscountsSleepOverrun() {
            var budget = AppHostedActivePollBudget(timeout: .seconds(10))
            budget.chargeActiveWork(after: .seconds(3))
            #expect(budget.remaining == .seconds(7))

            budget.chargePollSleep(after: .seconds(369))
            #expect(budget.remaining == .milliseconds(6_980))

            for _ in 0 ..< 349 {
                budget.chargePollSleep(after: .milliseconds(20))
            }
            #expect(!budget.canPoll)
            #expect(budget.remaining == .zero)
        }

        @Test("A slow predicate cannot satisfy the active budget")
        func slowPredicateCannotSatisfyActiveBudget() async throws {
            let satisfied = try await waitForAppHostedPolling(timeout: .milliseconds(1)) {
                Thread.sleep(forTimeInterval: 0.02)
                return true
            }
            #expect(!satisfied)
        }

        @Test("Active polling propagates cancellation")
        func activePollingPropagatesCancellation() async {
            let preCanceled = Task { @MainActor in
                withUnsafeCurrentTask { $0?.cancel() }
                do {
                    _ = try await waitForAppHostedPolling(timeout: .seconds(10)) { true }
                    return false
                } catch is CancellationError {
                    return true
                } catch {
                    return false
                }
            }
            let preCanceledResult = await preCanceled.value
            #expect(preCanceledResult)

            let waiting = Task { @MainActor in
                var enteredBeforeSleep = false
                var sleepInvoked = false
                do {
                    _ = try await waitForAppHostedPolling(
                        timeout: .seconds(10),
                        onBeforeSleep: {
                            enteredBeforeSleep = true
                            withUnsafeCurrentTask { $0?.cancel() }
                        },
                        pollSleep: { _ in
                            sleepInvoked = true
                            throw CancellationError()
                        },
                    ) { false }
                    return (
                        enteredBeforeSleep: enteredBeforeSleep,
                        sleepInvoked: sleepInvoked,
                        cancellationCaught: false,
                    )
                } catch is CancellationError {
                    return (
                        enteredBeforeSleep: enteredBeforeSleep,
                        sleepInvoked: sleepInvoked,
                        cancellationCaught: true,
                    )
                } catch {
                    return (
                        enteredBeforeSleep: enteredBeforeSleep,
                        sleepInvoked: sleepInvoked,
                        cancellationCaught: false,
                    )
                }
            }
            let outcome = await waiting.value
            #expect(outcome.enteredBeforeSleep)
            #expect(!outcome.sleepInvoked)
            #expect(outcome.cancellationCaught)
        }

        @Test("HTTP failure evidence is sanitized and lossless")
        func failureEvidenceIsSanitizedAndLossless() throws {
            let firstOperationID = BrowserNavigationOperationID()
            let inlineOperationID = BrowserNavigationOperationID()
            let tabID = BrowserTabID()
            let privateNamespace = "private-namespace"
            let firstURL = try #require(
                URL(string: "http://127.0.0.1:8080/\(privateNamespace)/first"),
            )
            let inlineURL = try #require(
                URL(string: "http://127.0.0.1:8080/\(privateNamespace)/inline"),
            )
            let commands: [BrowserWebKitCommand] = [
                .load(tabID: tabID, url: firstURL, operationID: firstOperationID),
                .load(tabID: tabID, url: inlineURL, operationID: inlineOperationID),
            ]
            let events: [BrowserWebKitEvent] = [
                .navigationCommitted(
                    tabID: tabID,
                    metadata: BrowserTab.Metadata(
                        committedURL: firstURL,
                        title: "private title",
                        isLoading: true,
                    ),
                    correlation: .operation(firstOperationID),
                ),
                .metadata(
                    tabID: tabID,
                    metadata: BrowserTab.Metadata(
                        committedURL: inlineURL,
                        title: "private title",
                        isLoading: false,
                        estimatedProgress: 1,
                    ),
                    correlation: .untracked,
                ),
                .navigationFailed(
                    tabID: tabID,
                    error: .noInternet(inlineURL),
                    correlation: .operation(inlineOperationID),
                ),
                .navigationStarted(tabID: tabID),
                .navigationConvertedToDownload(
                    tabID: tabID,
                    correlation: .operation(inlineOperationID),
                ),
                .processTerminated(tabID: tabID),
                .siteCreatedTab(
                    openerID: BrowserTabID(),
                    tabID: BrowserTabID(),
                    url: inlineURL,
                    foreground: true,
                ),
                .scriptCloseRequested(tabID: tabID),
                .javaScriptDialogChanged(tabID: tabID, isPresented: true),
                .backForwardEntries(tabID: tabID, direction: .back, entries: []),
                .preview(tabID: tabID, revision: .init(), pngData: nil),
                .linkContextAction(tabID: tabID, action: .copyLink, url: inlineURL),
            ]

            let evidence = HTTPDownloadDiagnosticEvidence.eventLines(events, commands: commands)
            let expectedLines = [
                "event[0]=navigationCommitted op=op1:load:first route=first loading=1 progress=0.00",
                "event[1]=metadata op=untracked route=inline loading=0 progress=1.00",
                "event[2]=navigationFailed op=op2:load:inline category=noInternet route=inline",
                "event[3]=navigationStarted",
                "event[4]=navigationConvertedToDownload op=op2:load:inline",
                "event[5]=processTerminated",
                "event[6]=siteCreatedTab route=inline foreground=true",
                "event[7]=scriptCloseRequested",
                "event[8]=javaScriptDialogChanged presented=true",
                "event[9]=backForwardEntries direction=back count=0",
                "event[10]=preview hasPNG=false",
                "event[11]=linkContextAction action=copyLink route=inline",
            ]
            #expect(evidence.split(separator: "\n").map(String.init) == expectedLines)
            #expect(!evidence.contains("127.0.0.1"))
            #expect(!evidence.contains(privateNamespace))
            #expect(!evidence.contains("private title"))
        }

        @Test("HTTP failure evidence is deterministically capped")
        func failureEvidenceIsDeterministicallyCapped() throws {
            let tabID = BrowserTabID()
            let route = try #require(
                URL(string: "http://127.0.0.1:8080/private-namespace/inline"),
            )
            let events = Array(repeating: BrowserWebKitEvent.navigationStarted(tabID: tabID), count: 30)
                + [
                    .navigationFailed(
                        tabID: tabID,
                        error: .connectionFailed(route),
                        correlation: .untracked,
                    ),
                    .processTerminated(tabID: tabID),
                ]

            let lines = HTTPDownloadDiagnosticEvidence
                .eventLines(events, commands: [])
                .split(separator: "\n")
                .map(String.init)

            #expect(lines.count == HTTPDownloadDiagnosticEvidence.maximumEventLineCount)
            #expect(lines.first == "event[0]=navigationStarted")
            #expect(lines[4] == "adapterEventsTruncated total=32 omitted=17")
            #expect(
                Array(lines.suffix(2)) == [
                    "event[30]=navigationFailed op=untracked category=connectionFailed route=inline",
                    "event[31]=processTerminated",
                ],
            )
        }

        @Test("HTTP command and native-error evidence is deterministically capped")
        func commandAndNativeErrorEvidenceIsDeterministicallyCapped() throws {
            let tabID = BrowserTabID()
            let route = try #require(
                URL(string: "http://127.0.0.1:8080/private-namespace/inline"),
            )
            var commands = (0 ..< 20).map { _ in
                BrowserWebKitCommand.load(
                    tabID: tabID,
                    url: route,
                    operationID: BrowserNavigationOperationID(),
                )
            }
            commands.append(.dismissJavaScriptDialog(tabID: tabID))

            let commandEvidence = HTTPDownloadDiagnosticEvidence.commandList(commands)
            #expect(
                commandEvidence.contains("commandsTruncated total=21 omitted=10"),
            )
            #expect(commandEvidence.hasSuffix(",dismissJavaScriptDialog"))
            #expect(!commandEvidence.contains("127.0.0.1"))
            #expect(!commandEvidence.contains("private-namespace"))

            let nativeErrors = (0 ..< 12).map { "WebKitErrorDomain:\($0)" }
            let nativeErrorEvidence = HTTPDownloadDiagnosticEvidence.nativeErrorList(nativeErrors)
            #expect(
                nativeErrorEvidence.contains("nativeErrorsTruncated total=12 omitted=5"),
            )
            #expect(nativeErrorEvidence.hasSuffix("WebKitErrorDomain:11"))
        }

        @Test("Adapter commit evidence must follow the request baseline")
        func adapterCommitEvidenceRequiresPostBaselineEvent() throws {
            let tabID = BrowserTabID()
            let otherTabID = BrowserTabID()
            let firstOperationID = BrowserNavigationOperationID()
            let inlineOperationID = BrowserNavigationOperationID()
            let firstURL = try #require(
                URL(string: "http://127.0.0.1:8080/private-namespace/first"),
            )
            let inlineURL = try #require(
                URL(string: "http://127.0.0.1:8080/private-namespace/inline"),
            )
            let stale = BrowserWebKitEvent.navigationCommitted(
                tabID: tabID,
                metadata: .init(committedURL: firstURL),
                correlation: .operation(firstOperationID),
            )
            let inline = BrowserWebKitEvent.navigationCommitted(
                tabID: tabID,
                metadata: .init(committedURL: inlineURL),
                correlation: .operation(inlineOperationID),
            )

            #expect(
                !HTTPDownloadDiagnosticEvidence.hasNavigationCommit(
                    in: [stale],
                    tabID: tabID,
                    url: inlineURL,
                    operationID: inlineOperationID,
                    afterEventIndex: 0,
                ),
            )
            #expect(
                !HTTPDownloadDiagnosticEvidence.hasNavigationCommit(
                    in: [stale, inline],
                    tabID: tabID,
                    url: inlineURL,
                    operationID: inlineOperationID,
                    afterEventIndex: 2,
                ),
            )
            #expect(
                HTTPDownloadDiagnosticEvidence.hasNavigationCommit(
                    in: [stale, inline],
                    tabID: tabID,
                    url: inlineURL,
                    operationID: inlineOperationID,
                    afterEventIndex: 1,
                ),
            )
            #expect(
                !HTTPDownloadDiagnosticEvidence.hasNavigationCommit(
                    in: [inline],
                    tabID: otherTabID,
                    url: inlineURL,
                    operationID: inlineOperationID,
                    afterEventIndex: 0,
                ),
            )
        }

        @Test("Navigation commit evidence requires the submitted operation identity")
        func navigationCommitEvidenceRequiresOperationIdentity() throws {
            let tabID = BrowserTabID()
            let inlineURL = try #require(
                URL(string: "http://127.0.0.1:8080/private-namespace/inline"),
            )
            let submittedOperationID = BrowserNavigationOperationID()
            let unrelatedOperationID = BrowserNavigationOperationID()
            let commands: [BrowserWebKitCommand] = [
                .load(
                    tabID: tabID,
                    url: inlineURL,
                    operationID: submittedOperationID,
                ),
            ]
            #expect(
                HTTPDownloadDiagnosticEvidence.navigationOperationID(
                    in: commands,
                    tabID: tabID,
                    url: inlineURL,
                    afterCommandIndex: 0,
                ) == submittedOperationID,
            )

            let unrelatedCommit = BrowserWebKitEvent.navigationCommitted(
                tabID: tabID,
                metadata: .init(committedURL: inlineURL),
                correlation: .operation(unrelatedOperationID),
            )
            #expect(
                !HTTPDownloadDiagnosticEvidence.hasNavigationCommit(
                    in: [unrelatedCommit],
                    tabID: tabID,
                    url: inlineURL,
                    operationID: submittedOperationID,
                    afterEventIndex: 0,
                ),
            )

            let submittedCommit = BrowserWebKitEvent.navigationCommitted(
                tabID: tabID,
                metadata: .init(committedURL: inlineURL),
                correlation: .operation(submittedOperationID),
            )
            #expect(
                HTTPDownloadDiagnosticEvidence.hasNavigationCommit(
                    in: [unrelatedCommit, submittedCommit],
                    tabID: tabID,
                    url: inlineURL,
                    operationID: submittedOperationID,
                    afterEventIndex: 1,
                ),
            )
        }

        @Test("Dispatch readiness requires an exact new GET for the cookie-prefixed fixture path")
        func dispatchReadinessRequiresExactNewGET() {
            let cookiePath = "/fixture-cookie/"

            func request(_ method: String, _ route: String) -> BrowserDownloadLoopbackServer.Request {
                .init(
                    method: method,
                    path: cookiePath + route,
                    headers: [:],
                    body: Data(),
                )
            }

            let stale = [request("GET", "first")]
            #expect(
                !hasParsedGET(
                    "first",
                    cookiePath: cookiePath,
                    afterBaseline: stale.count,
                    requests: stale,
                ),
            )

            let wrongRoute = [request("GET", "first"), request("GET", "committed")]
            #expect(
                !hasParsedGET(
                    "first",
                    cookiePath: cookiePath,
                    afterBaseline: 1,
                    requests: wrongRoute,
                ),
            )

            let sameTerminalWrongRoute = [
                request("GET", "first"),
                request("GET", "other/first"),
            ]
            #expect(
                !hasParsedGET(
                    "first",
                    cookiePath: cookiePath,
                    afterBaseline: 1,
                    requests: sameTerminalWrongRoute,
                ),
            )

            let wrongMethod = [request("GET", "first"), request("POST", "first")]
            #expect(
                !hasParsedGET(
                    "first",
                    cookiePath: cookiePath,
                    afterBaseline: 1,
                    requests: wrongMethod,
                ),
            )

            let exactNewGET = [request("GET", "first"), request("GET", "first?commit=fixture")]
            #expect(
                hasParsedGET(
                    "first",
                    cookiePath: cookiePath,
                    afterBaseline: 1,
                    requests: exactNewGET,
                ),
            )
        }

        @Test("Non-Root adapter commits one first page at Root WebKit geometry")
        func nonRootAdapterCommitsFirstPageAtRootGeometry() async throws {
            try await withSinglePageHTTPDownloadFixture { fixture, firstURL in
                let selectedTab = fixture.store.selectedTab
                let tab = try #require(selectedTab)
                let firstRouteRequests = fixture.server.requests.filter { fixtureRouteName($0.path) == "first" }
                let matchingGET = firstRouteRequests.contains { $0.method == "GET" }
                let windowSize = fixture.window.bounds.size
                let webViewSize = fixture.webView.bounds.size
                let titleMatches = tab.metadata.title == "Browser download first"
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
                let firstURL = try fixture.server.url("first")
                #expect(fixture.adapter.hasCommittedDocument(for: fixture.tabID))
                #expect(fixture.server.requests.contains {
                    $0.method == "GET" && $0.path == fixture.server.cookiePath + "first"
                })
                #expect(fixture.store.selectedTab?.metadata.committedURL == firstURL)
                #expect(fixture.webView.url == firstURL)
                #expect(fixture.webView.backForwardList.currentItem?.url == firstURL)
                #expect(!fixture.webView.isLoading)
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
                let requestBaseline = fixture.server.requests.count
                let adapterEventBaseline = fixture.observations.events.count
                let adapterCommandBaseline = fixture.observations.commands.count
                try await fixture.trigger(row)
                if row == .inline {
                    let inlineURL = try #require(fixture.inlineURL)
                    // Request receipt and reducer projection are separate asynchronous
                    // milestones. Establish the exact GET first so its 60-second budget
                    // cannot hide commit delay inside the unchanged settle deadline.
                    try await fixture.waitForDispatchedRequest("inline", baseline: requestBaseline)
                    let inlineOperationID = try #require(
                        HTTPDownloadDiagnosticEvidence.navigationOperationID(
                            in: fixture.observations.commands,
                            tabID: fixture.tabID,
                            url: inlineURL,
                            afterCommandIndex: adapterCommandBaseline,
                        ),
                    )
                    try await fixture.wait("inline PDF commits without download") {
                        fixture.store.selectedTab?.metadata.committedURL == inlineURL
                            && fixture.store.selectedTab?.metadata.isLoading == false
                            && fixture.adapter.hasCommittedDocument(for: fixture.tabID)
                            && fixture.store.previewState.operation(for: fixture.tabID) == nil
                            && HTTPDownloadDiagnosticEvidence.hasNavigationCommit(
                                in: fixture.observations.events,
                                tabID: fixture.tabID,
                                url: inlineURL,
                                operationID: inlineOperationID,
                                afterEventIndex: adapterEventBaseline,
                            )
                    }
                    #expect(fixture.adapter.hasCommittedDocument(for: fixture.tabID))
                    #expect(fixture.store.previewState.operation(for: fixture.tabID) == nil)
                    #expect(
                        HTTPDownloadDiagnosticEvidence.hasNavigationCommit(
                            in: fixture.observations.events,
                            tabID: fixture.tabID,
                            url: inlineURL,
                            operationID: inlineOperationID,
                            afterEventIndex: adapterEventBaseline,
                        ),
                    )
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

        /// The one-page setup above covers every classification row. This dedicated regression
        /// keeps a second committed page so the prior-page and back/forward history contract is
        /// still exercised against a real native download conversion for both browsing profiles.
        /// The row is fixed because every row kind shares the same conversion contract in the
        /// classification matrix; only the history dimension is unique here.
        @Test(
            "Prior page and back-forward history survive a native download conversion",
            arguments: [BrowserBrowsingProfile.persistentPrivate, .ephemeral],
        )
        func priorPageHistorySurvivesNativeDownloadConversion(
            profile: BrowserBrowsingProfile,
        ) async throws {
            try await withHTTPDownloadFixture(profile) { fixture in
                try await fixture.loadCommittedHistory()
                let before = try #require(fixture.store.selectedTab?.metadata)
                // Reducer metadata cannot prove the native list survived conversion, so pin
                // the real WKWebView entries: current document is the second committed page
                // and its back destination is the first page.
                let firstURL = try fixture.server.url("first")
                let committedURL = try fixture.server.url("committed")
                let listBefore = fixture.webView.backForwardList
                let currentBefore = try #require(listBefore.currentItem)
                let backBefore = try #require(listBefore.backItem)
                let backURLsBefore = listBefore.backList.map(\.url)
                let forwardURLsBefore = listBefore.forwardList.map(\.url)
                #expect(currentBefore.url == committedURL)
                #expect(backBefore.url == firstURL)
                try await fixture.trigger(.attribute)
                try await fixture.wait("completed attribute download keeps prior page history") {
                    fixture.owner.snapshot.records.first?.isReady == true
                        && fixture.observations.conversions == 1
                        && fixture.store.selectedTab?.metadata.isLoading == false
                        && fixture.store.previewState.operation(for: fixture.tabID) == nil
                }
                #expect(fixture.store.selectedTab?.metadata.canGoBack == true)
                let listAfter = fixture.webView.backForwardList
                #expect(listAfter.currentItem?.url == currentBefore.url)
                #expect(listAfter.backItem?.url == backBefore.url)
                #expect(listAfter.backList.map(\.url) == backURLsBefore)
                #expect(listAfter.forwardList.map(\.url) == forwardURLsBefore)
                fixture.assertPreservedDocument(before)
                #expect(fixture.observations.handoffs.count == 1)
                #expect(fixture.owner.retainedCount == 1)
                try fixture.verifyCompletedFile()
                fixture.assertNativeRequest(.attribute)
                #expect(fixture.observations.failures == 0)
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
                #expect(partial.receivedBytes < Int64(BrowserDownloadLoopbackServer.slowPayload.count))
                if knownLength {
                    #expect(partial.expectedBytes == Int64(BrowserDownloadLoopbackServer.slowPayload.count))
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

private func fixtureRouteName(_ requestPath: String) -> String {
    let lastComponent = requestPath.split(separator: "/").last ?? ""
    return String(lastComponent.split(separator: "?", maxSplits: 1).first ?? "")
}

private func hasParsedGET(
    _ route: String,
    cookiePath: String,
    afterBaseline baseline: Int,
    requests: [BrowserDownloadLoopbackServer.Request],
) -> Bool {
    guard requests.count > baseline else {
        return false
    }

    let expectedPath = cookiePath + route
    return requests.suffix(from: baseline).contains {
        let requestPath = $0.path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? ""
        return requestPath == expectedPath && $0.method == "GET"
    }
}

private enum HTTPDownloadDiagnosticEvidence {
    /// Keeps failure output below host truncation limits while retaining the initial
    /// correlation window and the latest WebKit callbacks.
    static let maximumEventLineCount = 16
    private static let leadingEventLineCount = 4
    static let maximumCommandCount = 12
    private static let leadingCommandCount = 4
    static let maximumNativeErrorCount = 8
    private static let leadingNativeErrorCount = 2

    /// Maps fixture and external locations to stable labels without recording origins,
    /// namespaces, titles, or other values that make CI failures noisy.
    static func routeLabel(_ url: URL?) -> String {
        guard let url else {
            return "nil"
        }

        switch url.lastPathComponent {
        case "first",
             "committed",
             "attachment",
             "inline",
             "octet",
             "redirect",
             "protected",
             "post",
             "blob",
             "attribute",
             "blob-bytes",
             "slow-known",
             "slow-unknown":
            return url.lastPathComponent
        default:
            return url.host == "127.0.0.1" ? "loopback-other" : "external"
        }
    }

    static func operationLabels(
        _ commands: [BrowserWebKitCommand],
    ) -> [BrowserNavigationOperationID: String] {
        var labels: [BrowserNavigationOperationID: String] = [:]
        var ordinal = 0
        for command in commands {
            guard case let .load(_, url, operationID) = command else {
                continue
            }

            ordinal += 1
            labels[operationID] = "op\(ordinal):load:\(routeLabel(url))"
        }
        return labels
    }

    static func operationLabel(
        _ operationID: BrowserNavigationOperationID?,
        labels: [BrowserNavigationOperationID: String],
    ) -> String {
        guard let operationID else {
            return "none"
        }

        return labels[operationID] ?? "unregistered"
    }

    /// Finds the unique reducer-issued load identity for one route after the fixture baseline.
    static func navigationOperationID(
        in commands: [BrowserWebKitCommand],
        tabID: BrowserTabID,
        url: URL,
        afterCommandIndex commandIndex: Int,
    ) -> BrowserNavigationOperationID? {
        var matchingOperationID: BrowserNavigationOperationID?
        for command in commands.dropFirst(commandIndex) {
            guard case let .load(commandTabID, commandURL, operationID) = command,
                  commandTabID == tabID,
                  commandURL == url
            else {
                continue
            }
            guard matchingOperationID == nil else {
                return nil
            }

            matchingOperationID = operationID
        }
        return matchingOperationID
    }

    /// Requires a post-baseline adapter callback for this tab, route and operation.
    /// A prior page or unrelated navigation cannot satisfy the assertion.
    static func hasNavigationCommit(
        in events: [BrowserWebKitEvent],
        tabID: BrowserTabID,
        url: URL,
        operationID: BrowserNavigationOperationID,
        afterEventIndex eventIndex: Int,
    ) -> Bool {
        events.dropFirst(eventIndex).contains { event in
            guard case let .navigationCommitted(eventTabID, metadata, correlation) = event else {
                return false
            }

            return eventTabID == tabID && metadata.committedURL == url
                && correlation.operationID == operationID
        }
    }

    static func commandList(_ commands: [BrowserWebKitCommand]) -> String {
        let labels = commands.map { command in
            switch command {
            case .configureProfile:
                "configureProfile"
            case .ensureContext:
                "ensureContext"
            case let .load(_, url, _):
                "load:\(routeLabel(url))"
            case .destroyContext:
                "destroyContext"
            case .goBack:
                "goBack"
            case .goForward:
                "goForward"
            case .reload:
                "reload"
            case .stop:
                "stop"
            case let .showBackForwardList(_, direction):
                "showBackForwardList:\(directionLabel(direction))"
            case .find:
                "find"
            case .goToBackForwardEntry:
                "goToBackForwardEntry"
            case .capturePreview:
                "capturePreview"
            case .dismissJavaScriptDialog:
                "dismissJavaScriptDialog"
            }
        }
        return boundedLabels(
            labels,
            maximum: maximumCommandCount,
            leading: leadingCommandCount,
            emptyLabel: "commands=none",
            separator: ",",
            marker: { total, omitted in
                "commandsTruncated total=\(total) omitted=\(omitted)"
            },
        )
    }

    static func nativeErrorList(_ errors: [String]) -> String {
        boundedLabels(
            errors,
            maximum: maximumNativeErrorCount,
            leading: leadingNativeErrorCount,
            emptyLabel: "nativeErrors=none",
            separator: ",",
            marker: { total, omitted in
                "nativeErrorsTruncated total=\(total) omitted=\(omitted)"
            },
        )
    }

    static func eventLines(
        _ events: [BrowserWebKitEvent],
        commands: [BrowserWebKitCommand],
    ) -> String {
        let labels = operationLabels(commands)
        var lines: [String] = []
        for (index, event) in events.enumerated() {
            let summary =
                switch event {
                case .navigationStarted:
                    "navigationStarted"
                case let .navigationCommitted(_, metadata, correlation):
                    "navigationCommitted op=\(correlationLabel(correlation, labels: labels)) "
                        + metadataEvidence(metadata)
                case let .navigationConvertedToDownload(_, correlation):
                    "navigationConvertedToDownload op=\(correlationLabel(correlation, labels: labels))"
                case let .metadata(_, metadata, correlation):
                    "metadata op=\(correlationLabel(correlation, labels: labels)) "
                        + metadataEvidence(metadata)
                case let .navigationFailed(_, error, correlation):
                    "navigationFailed op=\(correlationLabel(correlation, labels: labels)) "
                        + "category=\(errorCategory(error)) route=\(routeLabel(error.url))"
                case .processTerminated:
                    "processTerminated"
                case let .siteCreatedTab(_, _, url, foreground):
                    "siteCreatedTab route=\(routeLabel(url)) foreground=\(foreground)"
                case .scriptCloseRequested:
                    "scriptCloseRequested"
                case let .javaScriptDialogChanged(_, isPresented):
                    "javaScriptDialogChanged presented=\(isPresented)"
                case let .backForwardEntries(_, direction, entries):
                    "backForwardEntries direction=\(directionLabel(direction)) count=\(entries.count)"
                case let .preview(_, _, pngData):
                    "preview hasPNG=\(pngData != nil)"
                case let .linkContextAction(_, action, url):
                    "linkContextAction action=\(linkActionLabel(action)) route=\(routeLabel(url))"
                }
            lines.append("event[\(index)]=\(summary)")
        }
        return boundedEventLines(lines)
    }

    private static func boundedEventLines(_ lines: [String]) -> String {
        boundedLabels(
            lines,
            maximum: maximumEventLineCount,
            leading: leadingEventLineCount,
            emptyLabel: "adapterEvents=none",
            separator: "\n",
            marker: { total, omitted in
                "adapterEventsTruncated total=\(total) omitted=\(omitted)"
            },
        )
    }

    private static func boundedLabels(
        _ labels: [String],
        maximum: Int,
        leading: Int,
        emptyLabel: String,
        separator: String,
        marker: (_ total: Int, _ omitted: Int) -> String,
    ) -> String {
        guard !labels.isEmpty else {
            return emptyLabel
        }
        guard labels.count > maximum else {
            return labels.joined(separator: separator)
        }

        let trailingCount = maximum - leading - 1
        let omittedCount = labels.count - leading - trailingCount
        var boundedLabels = Array(labels.prefix(leading))
        boundedLabels.append(marker(labels.count, omittedCount))
        boundedLabels.append(contentsOf: labels.suffix(trailingCount))
        return boundedLabels.joined(separator: separator)
    }

    private static func correlationLabel(
        _ correlation: BrowserWebKitEventCorrelation,
        labels: [BrowserNavigationOperationID: String],
    ) -> String {
        guard let operationID = correlation.operationID else {
            return "untracked"
        }

        return labels[operationID] ?? "unregistered"
    }

    private static func metadataEvidence(_ metadata: BrowserTab.Metadata) -> String {
        "route=\(routeLabel(metadata.committedURL)) loading=\(metadata.isLoading ? 1 : 0) "
            + "progress=\(String(format: "%.2f", metadata.estimatedProgress))"
    }

    private static func errorCategory(_ error: BrowserNavigationError) -> String {
        switch error {
        case .noInternet:
            "noInternet"
        case .serverNotFound:
            "serverNotFound"
        case .connectionFailed:
            "connectionFailed"
        case .pageCouldNotLoad:
            "pageCouldNotLoad"
        }
    }

    private static func directionLabel(_ direction: BrowserNavigationDirection) -> String {
        switch direction {
        case .back:
            "back"
        case .forward:
            "forward"
        }
    }

    private static func linkActionLabel(_ action: BrowserLinkContextAction) -> String {
        switch action {
        case .open:
            "open"
        case .openInNewTab:
            "openInNewTab"
        case .copyLink:
            "copyLink"
        case .shareLink:
            "shareLink"
        }
    }
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
    let server: BrowserDownloadLoopbackServer
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
        server = try BrowserDownloadLoopbackServer()
        scratchRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
            "BrowserDownloadHTTP-\(UUID().uuidString)",
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
        let requestBaseline = server.requests.count
        store.send(.navigate(firstURL))
        // The first navigation pays the system's NetworkProcess launch. Local cold-start
        // evidence included a 45.4 s WebContent launch plus NetworkProcess suspension/resume.
        // The shared 60 s receipt budget covers startup without extending committed-page or
        // download-completion deadlines.
        try await waitForDispatchedRequest("first", baseline: requestBaseline)
        try await waitForSinglePageControl("native page committed: first") {
            store.selectedTab?.metadata.committedURL == firstURL
                && store.selectedTab?.metadata.title == "Browser download first"
                && store.selectedTab?.metadata.isLoading == false && !webView.isLoading
                && webView.window === window && adapter.hasCommittedDocument(for: tabID)
        }
        return firstURL
    }

    /// Bounded wait for observable native progress. The default ten-second window covers the
    /// committed-page assertion; environment preconditions (the first network-process dispatch)
    /// pass an explicit timeout. Waiting sleeps so WebKit and loopback main-queue callbacks keep
    /// running during cross-process startup.
    private func waitForSinglePageControl(
        _ milestone: String,
        timeout: Duration = .seconds(10),
        until predicate: @MainActor () -> Bool,
    ) async throws {
        let satisfied = try await waitForAppHostedPolling(
            timeout: timeout,
            pollInterval: .milliseconds(10),
        ) {
            window.rootViewController?.view.layoutIfNeeded()
            return predicate()
        }
        try #require(
            satisfied,
            Comment(
                rawValue:
                "Timed out: \(milestone) requests=\(server.requests.count) "
                    + "accepted=\(server.acceptedCount) subscribed=\(observations.subscribed) "
                    + "profileReady=\(adapter.profileIsConfigured) "
                    + "committed=\(adapter.hasCommittedDocument(for: tabID)) "
                    + "reducerLoading=\(String(describing: store.selectedTab?.metadata.isLoading)) "
                    + "nativeLoading=\(webView.isLoading) attached=\(webView.window === window) "
                    + "bounds=\(webView.bounds.size) errors=\(observations.nativeErrors.count) "
                    + failureTransportEvidence(),
            ),
        )
    }

    /// Waits until the loopback server parses GET `route` dispatched after
    /// `baseline`, so a stale, wrong-route, wrong-method, or incomplete request
    /// cannot satisfy navigation readiness. Later navigations in the fixture also
    /// pay network-process startup, so receipt uses the same bounded window as the
    /// first-page path; committed-page checks stay on the unchanged ten-second bound.
    /// The 60 s receipt budget covers measured WebKit cold-start and process-suspension
    /// intervals; request parsing, route, method, and baseline must all still match.
    fileprivate func waitForDispatchedRequest(
        _ route: String,
        baseline: Int,
        timeout: Duration = .seconds(60),
    ) async throws {
        try await waitForSinglePageControl("native navigation dispatched: \(route)", timeout: timeout) {
            hasParsedGET(
                route,
                cookiePath: server.cookiePath,
                afterBaseline: baseline,
                requests: server.requests,
            )
        }
    }

    func prepare() async throws {
        try await server.start()
        inlineURL = try server.url("inline")
        try await wait("event subscription and actual active hosting scene") {
            observations.subscribed && window.windowScene?.activationState == .foregroundActive
                && store.downloads.revision == owner.snapshot.revision
        }
        try await loadPage("first")
        #expect(adapter.hasCommittedDocument(for: tabID))
    }

    /// Loads a second committed page so prior-page and back/forward history exists before a
    /// download row runs. Dedicated history regressions call this after the one-page `prepare()`.
    func loadCommittedHistory() async throws {
        try await loadPage("committed")
        #expect(store.selectedTab?.metadata.canGoBack == true)
        #expect(adapter.hasCommittedDocument(for: tabID))
    }

    private func loadPage(_ route: String) async throws {
        let url = try server.url(route)
        requestedPage = url
        let requestBaseline = server.requests.count
        store.send(.navigate(url))
        try await waitForDispatchedRequest(route, baseline: requestBaseline)
        try await wait("native page committed: \(route)") {
            store.selectedTab?.metadata.committedURL == url && store.selectedTab?.metadata.title == "Browser download \(route)"
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
        let satisfied = try await waitForAppHostedPolling(timeout: .seconds(10)) {
            window.rootViewController?.view.layoutIfNeeded()
            return predicate()
        }

        let operationLabels = HTTPDownloadDiagnosticEvidence.operationLabels(observations.commands)
        let pendingOperation = HTTPDownloadDiagnosticEvidence.operationLabel(
            store.previewState.operation(for: tabID),
            labels: operationLabels,
        )
        let navigationOrigin = HTTPDownloadDiagnosticEvidence.routeLabel(
            store.previewState.navigationOrigin(for: tabID)?.metadata.committedURL,
        )
        let reducerCommitted = HTTPDownloadDiagnosticEvidence.routeLabel(
            store.selectedTab?.metadata.committedURL,
        )
        try #require(
            satisfied,
            Comment(
                rawValue:
                "\(milestone): requests=\(server.requests.count) handoffs=\(observations.handoffs.count) "
                    + "conversions=\(observations.conversions) failures=\(observations.failures) "
                    + "active=\(owner.activeCount) records=\(owner.snapshot.records.count) "
                    + "bytes=\(owner.snapshot.records.first?.receivedBytes ?? 0) "
                    + "ready=\(owner.snapshot.records.first?.isReady == true) "
                    + "notice=\(String(describing: owner.snapshot.notice)) "
                    + "accepted=\(server.acceptedCount) serverReady=\(server.ready) "
                    + "profileReady=\(adapter.profileIsConfigured) "
                    + "commands=\(HTTPDownloadDiagnosticEvidence.commandList(observations.commands)) "
                    + "pendingOperation=\(pendingOperation) "
                    + "navigationOrigin=\(navigationOrigin) "
                    + "reducerCommitted=\(reducerCommitted) "
                    + "reducerLoading=\(store.selectedTab?.metadata.isLoading == true) "
                    + "generation=\(store.downloads.revision)/\(owner.snapshot.revision) "
                    + "expectedRoute=\(HTTPDownloadDiagnosticEvidence.routeLabel(requestedPage)) "
                    + "attached=\(webView.window === window) bounds=\(webView.bounds) "
                    + "loading=\(webView.isLoading) nativeRoute=\(HTTPDownloadDiagnosticEvidence.routeLabel(webView.url)) "
                    + "events=\(observations.events.count) "
                    + "nativeErrors=\(HTTPDownloadDiagnosticEvidence.nativeErrorList(observations.nativeErrors)) "
                    + "\(failureTransportEvidence())",
            ),
        )
    }

    /// Bounded failure-only transport and adapter diagnostics. Serializes the
    /// loopback server's per-connection records and the observed WebKit events
    /// while the fixture is still alive, so a stalled wait can be classified
    /// from test output alone without changing what the wait asserts.
    private func failureTransportEvidence() -> String {
        let connections =
            if let data = try? JSONSerialization.data(
                withJSONObject: server.connectionEvidence,
                options: [.sortedKeys],
            ), let text = String(data: data, encoding: .utf8) {
                String(text.prefix(6_000))
            } else {
                "transport evidence serialization failed"
            }
        let events = HTTPDownloadDiagnosticEvidence.eventLines(
            observations.events,
            commands: observations.commands,
        )
        return "connectionEvidence=\(connections)"
            + " adapterCommitted=\(adapter.hasCommittedDocument(for: tabID))"
            + "\n\(events)"
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
