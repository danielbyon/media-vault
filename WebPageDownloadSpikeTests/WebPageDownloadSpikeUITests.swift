import XCTest

final class WebPageDownloadSpikeUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()

        XCTAssertTrue(
            app.staticTexts["server-ready"].waitForExistence(timeout: 15),
            "The loopback fixture server must be ready before the WebPage loads."
        )
        XCTAssertTrue(
            webpageControl("Fixture menu ready").waitForExistence(timeout: 15),
            "The rendered fixture menu did not finish loading."
        )
    }

    func testRenderedNavigationAndDownloadFixtureMatrix() throws {
        var matrix: [FixtureObservation] = []

        let normalBaseline = try readEvents()
        let normalBaselineIndex = normalBaseline.last?.index ?? 0
        tapWebpageControl("Normal HTML navigation")
        _ = try waitForServerRequests(
            paths: ["/normal"],
            fixture: "normal-html-navigation",
            afterEventIndex: normalBaselineIndex
        )
        XCTAssertTrue(
            webpageControl("Normal HTML destination loaded").waitForExistence(timeout: 10),
            "The ordinary HTML link did not navigate to its destination."
        )
        XCTAssertTrue(
            waitForServerTransfers(
                paths: ["/normal"],
                fixture: "normal-html-navigation",
                afterEventIndex: normalBaselineIndex,
                timeout: 10
            ),
            "The server did not finish sending the normal HTML response."
        )
        let normalEvents = try readEvents()
        XCTAssertTrue(
            normalEvents.contains {
                $0.index > normalBaselineIndex
                    && $0.fixture == "normal-html-navigation"
                    && $0.kind == "navigation-event"
                    && $0.navigationEvent?.localizedCaseInsensitiveContains("committed") == true
            },
            "The normal control must produce a public WebPage navigation commit event."
        )
        assertServerResponseEvidence(
            fixture: "normal-html-navigation",
            path: "/normal",
            afterEventIndex: normalBaselineIndex,
            in: normalEvents,
            expectedStatus: 200,
            expectedContentType: "text/html; charset=utf-8",
            declaredLength: 114,
            bodyLength: 114,
            expectedTransferOutcome: "response-body-sent"
        )
        matrix.append(
            observation(
                fixture: "normal-html-navigation",
                trigger: "XCUITest tapped the rendered HTML anchor",
                expected: "A normal navigation is allowed and commits the destination page.",
                events: normalEvents,
                windowSeconds: 0,
                afterEventIndex: normalBaselineIndex
            )
        )
        resetToFixtureMenu()

        let downloadFixtures: [DownloadFixture] = [
            .init(
                id: "download-attribute",
                controlLabel: "Download attribute",
                requestPaths: ["/download-attribute"],
                expected: "A real anchor with a download attribute requests a file; action intent and the returned policy are recorded.",
                expectedPolicyKind: .action,
                responsePolicyExpectation: nil,
            ),
            .init(
                id: "content-disposition-attachment",
                controlLabel: "Content-Disposition attachment",
                requestPaths: ["/attachment"],
                expected: "A displayable text response marked attachment is classified by its Content-Disposition header.",
                expectedPolicyKind: .response,
                responsePolicyExpectation: .init(
                    path: "/attachment",
                    status: 200,
                    mimeType: "text/plain",
                    canShowMIMEType: true,
                    contentDispositionContains: "attachment"
                )
            ),
            .init(
                id: "non-displayable-mime",
                controlLabel: "Non-displayable MIME response",
                requestPaths: ["/non-displayable"],
                expected: "A successful response with an unsupported MIME type is classified using canShowMimeType.",
                expectedPolicyKind: .response,
                responsePolicyExpectation: .init(
                    path: "/non-displayable",
                    status: 200,
                    mimeType: "application/x-spike-binary",
                    canShowMIMEType: false,
                    contentDispositionContains: nil,
                )
            ),
            .init(
                id: "redirect-to-attachment",
                controlLabel: "Redirect to attachment",
                requestPaths: ["/redirect", "/attachment"],
                expected: "The initial 302 and final attachment response are independently classified and recorded.",
                expectedPolicyKind: .response,
                responsePolicyExpectation: .init(
                    path: "/attachment",
                    status: 200,
                    mimeType: "text/plain",
                    canShowMIMEType: true,
                    contentDispositionContains: "attachment"
                )
            ),
            .init(
                id: "cookie-authenticated-attachment",
                controlLabel: "Cookie-authenticated attachment",
                requestPaths: ["/cookie-attachment"],
                expected: "The WebPage sends the fixture cookie and receives an attachment response.",
                expectedPolicyKind: .response,
                responsePolicyExpectation: .init(
                    path: "/cookie-attachment",
                    status: 200,
                    mimeType: "text/plain",
                    canShowMIMEType: true,
                    contentDispositionContains: "attachment"
                )
            ),
        ]

        for fixture in downloadFixtures {
            let before = try readEvents()
            let fixtureBaselineIndex = before.last?.index ?? 0
            tapWebpageControl(fixture.controlLabel)
            _ = try waitForServerRequests(
                paths: fixture.requestPaths,
                fixture: fixture.id,
                afterEventIndex: fixtureBaselineIndex
            )
            XCTAssertTrue(
                waitForServerTransfers(
                    paths: fixture.requestPaths,
                    fixture: fixture.id,
                    afterEventIndex: fixtureBaselineIndex,
                    timeout: 15
                ),
                "The server did not finish recording all responses for \(fixture.id)."
            )
            waitForObservationWindow(seconds: 10)
            let finalEvents = try readEvents()

            assertDownloadPolicyWasReturned(
                for: fixture,
                in: finalEvents,
                afterEventIndex: fixtureBaselineIndex
            )

            switch fixture.id {
            case "download-attribute":
                assertServerResponseEvidence(
                    fixture: fixture.id,
                    path: "/download-attribute",
                    afterEventIndex: fixtureBaselineIndex,
                    in: finalEvents,
                    expectedStatus: 200,
                    expectedContentType: "text/plain; charset=utf-8",
                    declaredLength: 27,
                    bodyLength: 27,
                    expectedTransferOutcome: "response-body-sent"
                )
            case "content-disposition-attachment":
                assertServerResponseEvidence(
                    fixture: fixture.id,
                    path: "/attachment",
                    afterEventIndex: fixtureBaselineIndex,
                    in: finalEvents,
                    expectedStatus: 200,
                    expectedContentType: "text/plain; charset=utf-8",
                    expectedContentDispositionContains: "attachment",
                    declaredLength: 28,
                    bodyLength: 28,
                    expectedTransferOutcome: "response-body-sent"
                )
            case "non-displayable-mime":
                assertServerResponseEvidence(
                    fixture: fixture.id,
                    path: "/non-displayable",
                    afterEventIndex: fixtureBaselineIndex,
                    in: finalEvents,
                    expectedStatus: 200,
                    expectedContentType: "application/x-spike-binary",
                    declaredLength: 7,
                    bodyLength: 7,
                    expectedTransferOutcome: "response-body-sent"
                )
            case "redirect-to-attachment":
                assertServerResponseEvidence(
                    fixture: fixture.id,
                    path: "/redirect",
                    afterEventIndex: fixtureBaselineIndex,
                    in: finalEvents,
                    expectedStatus: 302,
                    expectedContentType: "text/plain; charset=utf-8",
                    expectedLocation: "/attachment?source=redirect",
                    expectedRequestTarget: "/redirect",
                    declaredLength: 0,
                    bodyLength: 0,
                    expectedTransferOutcome: "response-body-sent"
                )
                assertServerResponseEvidence(
                    fixture: fixture.id,
                    path: "/attachment",
                    afterEventIndex: fixtureBaselineIndex,
                    in: finalEvents,
                    expectedStatus: 200,
                    expectedContentType: "text/plain; charset=utf-8",
                    expectedContentDispositionContains: "attachment",
                    expectedRequestTarget: "/attachment?source=redirect",
                    declaredLength: 28,
                    bodyLength: 28,
                    expectedTransferOutcome: "response-body-sent"
                )
            case "cookie-authenticated-attachment":
                assertServerResponseEvidence(
                    fixture: fixture.id,
                    path: "/cookie-attachment",
                    afterEventIndex: fixtureBaselineIndex,
                    in: finalEvents,
                    expectedStatus: 200,
                    expectedContentType: "text/plain; charset=utf-8",
                    expectedContentDispositionContains: "attachment",
                    expectedCookieContains: "spike-auth=runtime-27",
                    declaredLength: 29,
                    bodyLength: 29,
                    expectedTransferOutcome: "response-body-sent"
                )
            default:
                XCTFail("No HTTP response assertions are defined for \(fixture.id).")
            }

            matrix.append(
                observation(
                    fixture: fixture.id,
                    trigger: "XCUITest tapped the rendered HTML anchor",
                    expected: fixture.expected,
                    events: finalEvents,
                    windowSeconds: 10,
                    afterEventIndex: fixtureBaselineIndex
                )
            )
            resetToFixtureMenu()
        }

        let blobFixture = DownloadFixture(
            id: "blob-download",
            controlLabel: "Create blob download",
            requestPaths: [],
            expected: "A rendered-page button runs JavaScript that creates and clicks a blob URL anchor.",
            expectedPolicyKind: .action,
            responsePolicyExpectation: nil,
        )
        let blobBaseline = try readEvents()
        let blobBaselineIndex = blobBaseline.last?.index ?? 0
        tapWebpageControl(blobFixture.controlLabel)
        XCTAssertTrue(
            webpageControl("Blob trigger executed from rendered page").waitForExistence(timeout: 10),
            "The rendered page did not report that its user-triggered blob download ran."
        )
        waitForObservationWindow(seconds: 10)
        let blobEvents = try readEvents()
        let blobServerRequests = blobEvents.filter {
            $0.index > blobBaselineIndex
                && $0.fixture == blobFixture.id
                && $0.kind == "server-request"
        }
        XCTAssertTrue(
            blobServerRequests.isEmpty,
            "The generated blob is page-side evidence and must not be attributed to loopback HTTP."
        )
        assertDownloadPolicyWasReturned(
            for: blobFixture,
            in: blobEvents,
            afterEventIndex: blobBaselineIndex
        )
        matrix.append(
            observation(
                fixture: blobFixture.id,
                trigger: "XCUITest tapped the rendered page button; its JavaScript created and clicked a blob URL anchor.",
                expected: "The page-side trigger and action-level download policy are recorded separately from loopback HTTP activity.",
                events: blobEvents,
                windowSeconds: 10,
                pageSideTriggerObserved: true,
                afterEventIndex: blobBaselineIndex
            )
        )
        resetToFixtureMenu()

        let failureFixture = DownloadFixture(
            id: "truncated-attachment-failure",
            controlLabel: "Truncated attachment failure probe",
            requestPaths: ["/truncated-attachment"],
            expected: "The server closes a response before its declared Content-Length.",
            expectedPolicyKind: .response,
            responsePolicyExpectation: .init(
                path: "/truncated-attachment",
                status: 200,
                mimeType: "application/macbinary",
                canShowMIMEType: false,
                contentDispositionContains: "attachment"
            )
        )
        let failureBaseline = try readEvents()
        let failureBaselineIndex = failureBaseline.last?.index ?? 0
        tapWebpageControl(failureFixture.controlLabel)
        _ = try waitForServerRequests(
            paths: failureFixture.requestPaths,
            fixture: failureFixture.id,
            afterEventIndex: failureBaselineIndex
        )
        XCTAssertTrue(
            waitForEvent(
                kind: "server-transfer",
                fixture: failureFixture.id,
                path: "/truncated-attachment",
                transferOutcome: "truncated-response-sent",
                afterEventIndex: failureBaselineIndex,
                timeout: 10
            ),
            "The server must confirm the deliberately truncated transfer before callback observations are recorded."
        )
        waitForObservationWindow(seconds: 10)
        let failureEvents = try readEvents()
        assertDownloadPolicyWasReturned(
            for: failureFixture,
            in: failureEvents,
            afterEventIndex: failureBaselineIndex
        )
        assertServerResponseEvidence(
            fixture: failureFixture.id,
            path: "/truncated-attachment",
            afterEventIndex: failureBaselineIndex,
            in: failureEvents,
            expectedStatus: 200,
            expectedContentType: "application/octet-stream",
            expectedContentDispositionContains: "attachment",
            declaredLength: 2048,
            bodyLength: 64,
            expectedTransferOutcome: "truncated-response-sent"
        )
        matrix.append(
            observation(
                fixture: failureFixture.id,
                trigger: "XCUITest tapped the rendered HTML anchor",
                expected: "The response policy returns .download and the server confirms it sent a short body before closing.",
                events: failureEvents,
                windowSeconds: 10,
                afterEventIndex: failureBaselineIndex
            )
        )
        resetToFixtureMenu()

        let cancellationFixture = DownloadFixture(
            id: "slow-attachment-cancellation",
            controlLabel: "Slow attachment cancellation probe",
            requestPaths: ["/slow-attachment"],
            expected: "Record the server send outcome after the host calls WebPage.stopLoading().",
            expectedPolicyKind: .action,
            responsePolicyExpectation: nil,
        )
        let cancellationBaseline = try readEvents()
        let cancellationBaselineIndex = cancellationBaseline.last?.index ?? 0
        tapWebpageControl(cancellationFixture.controlLabel)
        let actionPolicyWasReturned = waitForEvent(
                kind: "action-policy",
                fixture: cancellationFixture.id,
                path: "/slow-attachment",
                decision: "download",
                shouldPerformDownload: true,
                afterEventIndex: cancellationBaselineIndex,
                timeout: 10
            )
        let observedActionPolicies = try readEvents().filter {
            $0.index > cancellationBaselineIndex
                && $0.fixture == cancellationFixture.id
                && $0.kind == "action-policy"
                && event($0, matchesPath: "/slow-attachment")
        }
        XCTAssertTrue(
            actionPolicyWasReturned,
            "The rendered download link must return action-level .download before Stop is requested. Observed policies: \(observedActionPolicies)"
        )
        _ = try waitForServerRequests(
            paths: cancellationFixture.requestPaths,
            fixture: cancellationFixture.id,
            afterEventIndex: cancellationBaselineIndex
        )
        app.buttons["stop-page-loading"].tap()
        XCTAssertTrue(
            waitForEvent(
                kind: "page-stop-loading-requested",
                fixture: cancellationFixture.id,
                path: "/slow-attachment",
                afterEventIndex: cancellationBaselineIndex,
                timeout: 5
            ),
            "The host must record its page-level Stop command against the cancellation fixture."
        )
        XCTAssertTrue(
            waitForEvent(
                kind: "server-transfer",
                fixture: cancellationFixture.id,
                path: "/slow-attachment",
                afterEventIndex: cancellationBaselineIndex,
                timeout: 20
            ),
            "The server must record whether its delayed body send completed or failed after Stop."
        )
        let cancellationEvents = try readEvents()
        assertDownloadPolicyWasReturned(
            for: cancellationFixture,
            in: cancellationEvents,
            afterEventIndex: cancellationBaselineIndex
        )
        let stopEvent = try XCTUnwrap(cancellationEvents.first {
            $0.index > cancellationBaselineIndex
                && $0.kind == "page-stop-loading-requested"
                && $0.fixture == cancellationFixture.id
                && $0.path == "/slow-attachment"
        })
        let transferEvent = try XCTUnwrap(cancellationEvents.first {
            $0.index > cancellationBaselineIndex
                && $0.kind == "server-transfer"
                && $0.fixture == cancellationFixture.id
                && $0.path == "/slow-attachment"
        })
        XCTAssertGreaterThan(
            transferEvent.index,
            stopEvent.index,
            "The server transfer outcome must be recorded after WebPage.stopLoading()."
        )
        let transferOutcome = try XCTUnwrap(transferEvent.transferOutcome)
        let transferDisposition: String
        if transferOutcome == "delayed-body-sent" {
            transferDisposition = "server send completed after WebPage.stopLoading()"
        } else if transferOutcome.hasPrefix("body-send-failed:")
                    || transferOutcome.hasPrefix("headers-send-failed:") {
            transferDisposition = "server send failed or was interrupted after WebPage.stopLoading(): \(transferOutcome)"
        } else {
            XCTFail("Unexpected delayed-transfer outcome: \(transferOutcome)")
            transferDisposition = "unclassified server transfer outcome: \(transferOutcome)"
        }
        assertServerResponseEvidence(
            fixture: cancellationFixture.id,
            path: "/slow-attachment",
            afterEventIndex: cancellationBaselineIndex,
            in: cancellationEvents,
            expectedStatus: 200,
            expectedContentType: "application/octet-stream",
            expectedContentDispositionContains: "attachment",
            declaredLength: 1024,
            bodyLength: 1024
        )
        matrix.append(
            observation(
                fixture: cancellationFixture.id,
                trigger: "XCUITest tapped the rendered HTML anchor, then the host invoked WebPage.stopLoading().",
                expected: "The server send outcome is recorded after Stop; its completion or failure is distinguished.",
                events: cancellationEvents,
                windowSeconds: 12,
                serverTransferDisposition: transferDisposition,
                afterEventIndex: cancellationBaselineIndex
            )
        )

        let data = try JSONEncoder().encode(matrix)
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "WebPage download fixture event matrix"
        attachment.lifetime = .keepAlways
        XCTContext.runActivity(named: "Export structured fixture observations") { activity in
            activity.add(attachment)
        }

        XCTAssertEqual(matrix.count, 9, "The export contains the normal control, six required cases, and two lifecycle probes.")
    }

    private func tapWebpageControl(_ label: String) {
        let element = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", label))
            .firstMatch
        XCTAssertTrue(element.waitForExistence(timeout: 10), "Missing rendered webpage control: \(label)\n\(app.debugDescription)")
        element.tap()
    }

    private func resetToFixtureMenu() {
        app.buttons["reset-to-fixture-menu"].tap()
        XCTAssertTrue(
            webpageControl("Fixture menu ready").waitForExistence(timeout: 10),
            "The host did not return WebPage to the fixture menu."
        )
    }

    private func webpageControl(_ label: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", label))
            .firstMatch
    }

    private func readEvents() throws -> [SpikeEvent] {
        let jsonElement = app.descendants(matching: .any)
            .matching(identifier: "event-records-json")
            .firstMatch
        XCTAssertTrue(
            jsonElement.waitForExistence(timeout: 5),
            "The event export element is missing. Accessibility hierarchy:\n\(app.debugDescription)"
        )
        let exportedValue = jsonElement.value as? String
        let json = exportedValue ?? jsonElement.label
        return try JSONDecoder().decode(SpikeEventExport.self, from: Data(json.utf8)).events
    }

    private func waitForServerRequests(
        paths: [String],
        fixture: String,
        afterEventIndex: Int
    ) throws -> [SpikeEvent] {
        let deadline = Date().addingTimeInterval(15)
        var latest = try readEvents()
        while Date() < deadline {
            latest = try readEvents()
            let matched = Set(latest.filter {
                $0.index > afterEventIndex
                    && $0.fixture == fixture
                    && $0.kind == "server-request"
            }.compactMap(\.path))
            if paths.allSatisfy(matched.contains) {
                return latest
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        XCTFail("Fixture server did not receive all expected requests for \(fixture): \(paths). Events: \(latest)")
        return latest
    }

    private func waitForServerTransfers(
        paths: [String],
        fixture: String,
        afterEventIndex: Int,
        timeout: TimeInterval
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let events = try? readEvents() {
                let transferredPaths = Set(events.filter {
                    $0.index > afterEventIndex
                        && $0.fixture == fixture
                        && $0.kind == "server-transfer"
                }.compactMap(\.path))
                if paths.allSatisfy(transferredPaths.contains) {
                    return true
                }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return false
    }

    private func waitForEvent(
        kind: String,
        fixture: String,
        path: String,
        decision: String? = nil,
        shouldPerformDownload: Bool? = nil,
        transferOutcome: String? = nil,
        afterEventIndex: Int,
        timeout: TimeInterval
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let events = try? readEvents(), events.contains(where: {
                $0.index > afterEventIndex
                    && $0.fixture == fixture
                    && $0.kind == kind
                    && event($0, matchesPath: path)
                    && (decision == nil || $0.decision == decision)
                    && (shouldPerformDownload == nil || $0.shouldPerformDownload == shouldPerformDownload)
                    && (transferOutcome == nil || $0.transferOutcome == transferOutcome)
            }) {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return false
    }

    private func event(_ event: SpikeEvent, matchesPath path: String) -> Bool {
        if event.path == path { return true }
        return URL(string: event.url ?? "")?.path == path
    }

    private func assertServerResponseEvidence(
        fixture: String,
        path: String,
        afterEventIndex: Int,
        in events: [SpikeEvent],
        expectedStatus: Int,
        expectedContentType: String,
        expectedContentDispositionContains: String? = nil,
        expectedLocation: String? = nil,
        expectedRequestTarget: String? = nil,
        expectedCookieContains: String? = nil,
        declaredLength: Int,
        bodyLength: Int,
        expectedTransferOutcome: String? = nil
    ) {
        let fixtureEvents = events.filter {
            $0.index > afterEventIndex
                && $0.fixture == fixture
                && $0.path == path
        }
        let request = fixtureEvents.first { $0.kind == "server-request" }
        let transfer = fixtureEvents.first { $0.kind == "server-transfer" }
        XCTAssertNotNil(request, "Missing current-fixture server request for \(fixture) \(path).")
        XCTAssertNotNil(transfer, "Missing current-fixture server transfer for \(fixture) \(path).")
        guard let request, let transfer else { return }

        for evidence in [request, transfer] {
            XCTAssertEqual(evidence.status, expectedStatus, "Unexpected HTTP status for \(fixture) \(path).")
            XCTAssertEqual(evidence.mimeType, expectedContentType, "Unexpected HTTP Content-Type for \(fixture) \(path).")
            XCTAssertEqual(evidence.location, expectedLocation, "Unexpected redirect Location for \(fixture) \(path).")
            if let expectedContentDispositionContains {
                XCTAssertTrue(
                    evidence.contentDisposition?.localizedCaseInsensitiveContains(expectedContentDispositionContains) == true,
                    "Unexpected Content-Disposition for \(fixture) \(path): \(String(describing: evidence.contentDisposition))"
                )
            } else {
                XCTAssertNil(evidence.contentDisposition, "Unexpected Content-Disposition for \(fixture) \(path).")
            }
        }

        if let expectedRequestTarget {
            XCTAssertTrue(
                request.detail?.contains("request-target=\(expectedRequestTarget)") == true,
                "Unexpected request target for \(fixture) \(path): \(String(describing: request.detail))"
            )
        }
        if let expectedCookieContains {
            XCTAssertTrue(
                request.cookie?.contains(expectedCookieContains) == true,
                "Expected cookie evidence for \(fixture) \(path)."
            )
            XCTAssertEqual(transfer.cookie, request.cookie)
        }
        XCTAssertTrue(
            transfer.detail?.contains("declared-length=\(declaredLength);body-length=\(bodyLength)") == true,
            "Unexpected response length evidence for \(fixture) \(path): \(String(describing: transfer.detail))"
        )
        if let expectedTransferOutcome {
            XCTAssertEqual(transfer.transferOutcome, expectedTransferOutcome)
        }
    }

    private func assertDownloadPolicyWasReturned(
        for fixture: DownloadFixture,
        in events: [SpikeEvent],
        afterEventIndex: Int
    ) {
        let relevant = events.filter {
            $0.index > afterEventIndex
                && $0.fixture == fixture.id
                && $0.kind == fixture.expectedPolicyKind.rawValue
                && $0.decision == "download"
        }
        XCTAssertFalse(
            relevant.isEmpty,
            "No \(fixture.expectedPolicyKind.rawValue) .download policy was recorded after the fixture baseline for \(fixture.id): \(events)"
        )
        if fixture.expectedPolicyKind == .action {
            XCTAssertTrue(
                relevant.contains { $0.shouldPerformDownload == true },
                "An action-level .download decision must record shouldPerformDownload=true for \(fixture.id)."
            )
        }

        guard let expected = fixture.responsePolicyExpectation else { return }
        let responsePolicy = events.first {
            $0.index > afterEventIndex
                && $0.fixture == fixture.id
                && $0.kind == DownloadPolicyKind.response.rawValue
                && $0.decision == "download"
                && URL(string: $0.url ?? "")?.path == expected.path
        }
        XCTAssertNotNil(
            responsePolicy,
            "No fixture-specific response-level .download policy was recorded for \(fixture.id)."
        )
        guard let responsePolicy else { return }
        XCTAssertEqual(responsePolicy.status, expected.status)
        XCTAssertEqual(responsePolicy.mimeType, expected.mimeType)
        XCTAssertEqual(responsePolicy.canShowMIMEType, expected.canShowMIMEType)
        if let expectedDisposition = expected.contentDispositionContains {
            XCTAssertTrue(
                responsePolicy.contentDisposition?.localizedCaseInsensitiveContains(expectedDisposition) == true,
                "Expected Content-Disposition to contain \(expectedDisposition) for \(fixture.id)."
            )
        } else {
            XCTAssertNil(responsePolicy.contentDisposition)
        }
    }

    private func waitForObservationWindow(seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private func observation(
        fixture: String,
        trigger: String,
        expected: String,
        events: [SpikeEvent],
        windowSeconds: Int,
        pageSideTriggerObserved: Bool = false,
        serverTransferDisposition: String? = nil,
        afterEventIndex: Int
    ) -> FixtureObservation {
        let relatedEvents = relevantEvents(
            in: events,
            fixture: fixture,
            afterEventIndex: afterEventIndex
        )
        let verdict: String
        if fixture == "normal-html-navigation" {
            verdict = "CONTROL PASS: normal HTML response and navigation commit were observed."
        } else if fixture == "blob-download" && pageSideTriggerObserved {
            verdict = "RUNTIME PASS: page-side trigger and action-level shouldPerformDownload=true/.download were observed; no loopback HTTP request was expected."
        } else {
            let policyLevel = relatedEvents.first {
                $0.decision == "download"
                    && ($0.kind == DownloadPolicyKind.action.rawValue || $0.kind == DownloadPolicyKind.response.rawValue)
            }.map {
                $0.kind == DownloadPolicyKind.action.rawValue ? "action-level" : "response-level"
            } ?? "no"
            let transfers = relatedEvents
                .filter { $0.kind == "server-transfer" }
                .map { "\($0.path ?? "unknown")=\($0.transferOutcome ?? "unknown")" }
                .joined(separator: ", ")
            verdict = "RUNTIME PASS: \(policyLevel) .download policy and exact fixture transfer evidence were recorded. Transfer outcome(s): \(transfers.isEmpty ? "none" : transfers). Public API lifecycle availability is assessed separately from SDK interface inspection."
        }
        return FixtureObservation(
            fixture: fixture,
            trigger: trigger,
            expectedBehavior: expected,
            observedCallbacks: relatedEvents.filter { $0.kind != "server-request" && $0.kind != "server-transfer" },
            serverEvidence: relatedEvents.filter { $0.kind == "server-request" || $0.kind == "server-transfer" },
            pageSideTriggerObserved: pageSideTriggerObserved,
            observationWindowSeconds: windowSeconds,
            serverTransferDisposition: serverTransferDisposition,
            verdict: verdict
        )
    }

    private func relevantEvents(
        in events: [SpikeEvent],
        fixture: String,
        afterEventIndex: Int
    ) -> [SpikeEvent] {
        events.filter { event in
            guard event.index > afterEventIndex else { return false }
            if event.fixture == fixture { return true }
            return fixture == "blob-download" && event.url?.hasPrefix("blob:") == true
        }
    }
}

private struct DownloadFixture {
    let id: String
    let controlLabel: String
    let requestPaths: [String]
    let expected: String
    let expectedPolicyKind: DownloadPolicyKind
    let responsePolicyExpectation: ResponsePolicyExpectation?
}

private enum DownloadPolicyKind: String {
    case action = "action-policy"
    case response = "response-policy"
}

private struct ResponsePolicyExpectation {
    let path: String
    let status: Int
    let mimeType: String
    let canShowMIMEType: Bool
    let contentDispositionContains: String?
}

private struct SpikeEventExport: Decodable {
    let events: [SpikeEvent]
}

private struct SpikeEvent: Codable {
    let index: Int
    let kind: String
    let fixture: String
    let url: String?
    let path: String?
    let shouldPerformDownload: Bool?
    let navigationType: String?
    let canShowMIMEType: Bool?
    let mimeType: String?
    let status: Int?
    let contentDisposition: String?
    let cookie: String?
    let location: String?
    let decision: String?
    let navigationEvent: String?
    let transferOutcome: String?
    let detail: String?
}

private struct FixtureObservation: Encodable {
    let fixture: String
    let trigger: String
    let expectedBehavior: String
    let observedCallbacks: [SpikeEvent]
    let serverEvidence: [SpikeEvent]
    let pageSideTriggerObserved: Bool
    let observationWindowSeconds: Int
    let serverTransferDisposition: String?
    let verdict: String
}
