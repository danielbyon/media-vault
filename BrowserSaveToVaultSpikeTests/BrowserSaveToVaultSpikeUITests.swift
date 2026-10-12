//
//  BrowserSaveToVaultSpikeUITests.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import XCTest

@MainActor
final class BrowserSaveToVaultSpikeUITests: XCTestCase {
    func testExplicitSaveReceiptAndContainmentMatrix() async throws {
        let app = XCUIApplication()
        app.launch()

        let pagePath = app.staticTexts["current-page-path"]
        let transferState = app.staticTexts["transfer-state"]
        XCTAssertTrue(pagePath.waitForExistence(timeout: 30))
        XCTAssertTrue(transferState.waitForExistence(timeout: 10))
        _ = try await waitForEvidence(timeout: 15) { evidence in
            evidence.requests.contains { $0["path"] as? String == "/" }
        }

        tapFixtureLink("save-link-still", in: app)
        waitForState("save-link-still: receipt accepted", transferState)
        let firstReceiptEvidence = try await waitForEvidence(timeout: 10) { evidence in
            evidence.events.contains { event in
                event["kind"] as? String == "receipt-accepted"
                    && (event["fields"] as? [String: Any])?["case_id"] as? String == "save-link-still"
            }
        }
        let stillReceipt = try XCTUnwrap(event(
            kind: "receipt-accepted",
            caseID: "save-link-still",
            in: firstReceiptEvidence.events,
        ))
        let stillFields = try XCTUnwrap(stillReceipt["fields"] as? [String: Any])
        XCTAssertEqual(stillFields["transfer_to_receipt_bytes_identical"] as? String, "true")
        XCTAssertEqual(stillFields["protection_requested"] as? String, "completeUnlessOpen")

        tapFixtureLink("save-link-still", in: app)
        waitForState("save-link-still: rejected unsupported content", transferState)
        let duplicateReceiptEvidence = try await waitForEvidence(timeout: 10) { evidence in
            evidence.events.contains { event in
                event["kind"] as? String == "receipt-rejected"
                    && (event["fields"] as? [String: Any])?["case_id"] as? String == "save-link-still"
            }
        }
        XCTAssertEqual(duplicateReceiptEvidence.events.count(where: { event in
            event["kind"] as? String == "receipt-accepted"
                && (event["fields"] as? [String: Any])?["case_id"] as? String == "save-link-still"
        }), 1)

        tapFixtureLink("save-signed-still", in: app)
        waitForState("save-signed-still: receipt accepted", transferState)
        let signedEvidence = try await waitForEvidence(timeout: 10) { evidence in
            evidence.requests.contains { $0["path"] as? String == "/signed/pre-request" }
        }
        let signedRequest = try XCTUnwrap(signedEvidence.requests
            .first { $0["path"] as? String == "/signed/pre-request" })
        XCTAssertEqual(signedRequest["status"] as? Int, 200)
        XCTAssertEqual(signedRequest["single_use_token_state"] as? String, "first-use")

        tapFixtureLink("save-video", in: app)
        waitForState("save-video: receipt accepted", transferState)

        tapFixtureLink("save-truncated-video", in: app)
        waitForState("save-truncated-video: rejected unsupported content", transferState)

        tapFixtureLink("save-same-origin", in: app)
        waitForTerminalState("save-same-origin", transferState)
        let sameOriginEvidence = try await waitForEvidence(timeout: 10) { evidence in
            evidence.requests.contains { $0["path"] as? String == "/resource/same-origin-final" }
        }
        XCTAssertTrue(sameOriginEvidence.requests.contains { $0["path"] as? String == "/redirect/same-origin" })
        XCTAssertTrue(sameOriginEvidence.requests.contains { $0["path"] as? String == "/redirect/same-origin-hop-2" })
        XCTAssertTrue(sameOriginEvidence.events.contains { event in
            event["kind"] as? String == "redirect-decision"
                && (event["fields"] as? [String: Any])?["allowed"] as? String == "true"
                && (event["fields"] as? [String: Any])?["reason"] as? String == "same-origin"
        })

        tapFixtureLink("save-cross-origin", in: app)
        waitForTerminalState("save-cross-origin", transferState)
        let crossOriginEvidence = try await waitForEvidence(timeout: 10) { evidence in
            evidence.requests.contains { $0["path"] as? String == "/redirect/cross-origin" }
                && evidence.events.contains { event in
                    event["kind"] as? String == "redirect-decision"
                        && (event["fields"] as? [String: Any])?["reason"] as? String == "cross-origin"
                }
        }
        XCTAssertFalse(crossOriginEvidence.requests.contains { ($0["path"] as? String) == "/prohibited/cross-origin" })
        XCTAssertTrue(crossOriginEvidence.events.contains { event in
            event["kind"] as? String == "redirect-decision"
                && (event["fields"] as? [String: Any])?["reason"] as? String == "cross-origin"
                && (event["fields"] as? [String: Any])?["allowed"] as? String == "false"
        })

        tapFixtureLink("save-https-downgrade", in: app)
        waitForTerminalState("save-https-downgrade", transferState)
        let downgradeEvidence = try await waitForEvidence(timeout: 10) { evidence in
            evidence.requests.contains { $0["path"] as? String == "/redirect/https-downgrade" }
                && evidence.events.contains { event in
                    event["kind"] as? String == "redirect-decision"
                        && (event["fields"] as? [String: Any])?["reason"] as? String == "https-downgrade"
                }
        }
        XCTAssertFalse(downgradeEvidence.requests.contains { ($0["path"] as? String) == "/prohibited/https-downgrade" })

        tapFixtureLink("save-non-media", in: app)
        waitForState("save-non-media: rejected unsupported content", transferState)
        tapFixtureLink("save-claimed-image", in: app)
        waitForState("save-claimed-image: rejected unsupported content", transferState)
        tapFixtureLink("save-missing", in: app)
        waitForTerminalState("save-missing", transferState)

        app.buttons["fixture-home"].tap()
        tapFixtureLink("login-persistent", in: app)
        let loginEvidence = try await waitForEvidence(timeout: 10) { evidence in
            evidence.requests.count(where: { $0["path"] as? String == "/" }) >= 2
        }
        XCTAssertTrue(loginEvidence.requests.contains { request in
            request["path"] as? String == "/"
                && (request["query_keys"] as? [String])?.contains("login") == true
        })
        tapFixtureLink("open-cookie-resource", in: app)
        let browserCookieEvidence = try await waitForEvidence(timeout: 10) { evidence in
            evidence.requests.contains { request in
                request["path"] as? String == "/cookie/resource"
                    && request["status"] as? Int == 200
                    && request["cookie_auth_valid"] as? Bool == true
            }
        }
        let browserCookieRequest = try XCTUnwrap(browserCookieEvidence.requests.last {
            $0["path"] as? String == "/cookie/resource"
                && $0["cookie_auth_valid"] as? Bool == true
        })
        XCTAssertEqual(browserCookieRequest["cookie_names"] as? [String], ["spike_http_only"])

        app.buttons["fixture-home"].tap()
        let returnedHomeEvidence = try await waitForEvidence(timeout: 10) { evidence in
            evidence.requests.count(where: { $0["path"] as? String == "/" }) >= 3
        }
        XCTAssertFalse(returnedHomeEvidence.requests.isEmpty)
        let persistentCookieRequestCount = returnedHomeEvidence.requests.count(where: {
            $0["path"] as? String == "/cookie/resource"
        })
        tapFixtureLink("save-cookie-media", in: app)
        waitForTerminalState("save-cookie-media", transferState)
        let persistentCookieEvidence = try await waitForEvidence(timeout: 10) { evidence in
            evidence.requests.count(where: { $0["path"] as? String == "/cookie/resource" })
                > persistentCookieRequestCount
        }
        let persistentCookieRequest = try XCTUnwrap(persistentCookieEvidence.requests.last {
            $0["path"] as? String == "/cookie/resource"
        })

        app.buttons["profile-ephemeral"].tap()
        let ephemeralHomeEvidence = try await waitForEvidence(timeout: 10) { evidence in
            evidence.requests.contains { request in
                request["path"] as? String == "/"
                    && (request["query_keys"] as? [String])?.contains("profile") == true
            }
        }
        XCTAssertFalse(ephemeralHomeEvidence.requests.isEmpty)
        let ephemeralCookieRequestCount = ephemeralHomeEvidence.requests.count(where: {
            $0["path"] as? String == "/cookie/resource"
        })
        tapFixtureLink("save-cookie-media", in: app)
        waitForTerminalState("save-cookie-media", transferState)
        let cookieRequests = try await waitForEvidence(timeout: 10) { evidence in
            evidence.requests.count(where: { $0["path"] as? String == "/cookie/resource" })
                > ephemeralCookieRequestCount
        }
        let ephemeralCookieRequest = try XCTUnwrap(cookieRequests.requests.last {
            $0["path"] as? String == "/cookie/resource"
        })

        app.buttons["profile-persistent"].tap()
        tapFixtureLink("ordinary-navigation", in: app)
        let normalNavigationEvidence = try await waitForEvidence(timeout: 10) { evidence in
            evidence.requests.contains { $0["path"] as? String == "/normal" }
        }
        XCTAssertTrue(normalNavigationEvidence.requests.contains { $0["path"] as? String == "/normal" })

        app.buttons["fixture-home"].tap()
        tapFixtureLink("reject-post", in: app)
        waitForState("reject-post: rejected method-not-get", transferState)
        tapFixtureLink("reject-blob", in: app)
        waitForState("reject-blob: rejected http-origin-required", transferState)
        tapFixtureLink("reject-data", in: app)
        waitForState("reject-data: rejected http-origin-required", transferState)

        tapFixtureLink("save-slow-cancel", in: app)
        waitForState("save-slow-cancel: downloading", transferState)
        app.buttons["cancel-transfer"].tap()
        waitForState("save-slow-cancel: cancelled", transferState)
        let cancelledEvidence = try await waitForEvidence(timeout: 15) { evidence in
            evidence.transferEvents.contains { $0["path"] as? String == "/resource/slow-cancel" }
        }
        let slowTransfer = try XCTUnwrap(cancelledEvidence.transferEvents.first {
            $0["path"] as? String == "/resource/slow-cancel"
        })

        app.buttons["fixture-home"].tap()
        app.buttons["open-direct-still"].tap()
        let directStillNavigationEvidence = try await waitForEvidence(timeout: 10) { evidence in
            evidence.requests.contains { $0["path"] as? String == "/resource/direct-image" }
        }
        XCTAssertTrue(directStillNavigationEvidence.requests
            .contains { $0["path"] as? String == "/resource/direct-image" })
        waitForPagePath("/resource/direct-image", pagePath)
        app.buttons["save-current-page"].tap()
        waitForState("direct-page-still: receipt accepted", transferState)

        app.buttons["fixture-home"].tap()
        tapFixtureLink("ordinary-navigation", in: app)
        waitForPagePath("/normal", pagePath)

        app.buttons["fixture-home"].tap()
        let directVideoBaseline = try await readEvidence().requests.count(where: {
            $0["path"] as? String == "/resource/direct-video"
        })
        app.buttons["open-direct-video"].tap()
        waitForPagePath("/resource/direct-video", pagePath)
        let directVideoPageEvidence = try await waitForEvidence(timeout: 10) { evidence in
            evidence.requests.count(where: { $0["path"] as? String == "/resource/direct-video" }) > directVideoBaseline
        }
        XCTAssertTrue(directVideoPageEvidence.requests.contains { request in
            request["path"] as? String == "/resource/direct-video"
                && request["referer_present"] as? Bool == true
        })
        let directVideoSaveButton = app.buttons["save-current-page"]
        let directVideoSaveControlWasHittable = directVideoSaveButton.isHittable
        if directVideoSaveControlWasHittable {
            directVideoSaveButton.tap()
            _ = try await waitForEvidence(timeout: 5) { evidence in
                evidence.events.contains { event in
                    (event["fields"] as? [String: Any])?["case_id"] as? String == "direct-page-video"
                        &&
                        (event["kind"] as? String == "transfer-started" || event["kind"] as? String ==
                            "acquisition-rejected")
                }
            }
        }
        XCTContext.runActivity(named: "Direct video current-page selection result") { activity in
            let hitTest = XCTAttachment(
                string: "Save control hittable while direct MP4 page is shown: \(directVideoSaveControlWasHittable).",
            )
            hitTest.name = "direct-video-save-control-hit-test"
            hitTest.lifetime = .keepAlways
            activity.add(hitTest)
            let hierarchy = XCTAttachment(
                string: "Save control frame: \(directVideoSaveButton.frame); app window count: \(app.windows.count).\n\n"
                    + "Accessibility hierarchy:\n\(app.debugDescription)",
            )
            hierarchy.name = "direct-video-save-control-accessibility"
            hierarchy.lifetime = .keepAlways
            activity.add(hierarchy)
            let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            screenshot.name = "direct-video-save-control-state"
            screenshot.lifetime = .keepAlways
            activity.add(screenshot)
        }

        let finalEvidence = try await readEvidence()
        XCTAssertTrue(finalEvidence.requests.contains { $0["path"] as? String == "/resource/direct-image" })
        XCTAssertTrue(finalEvidence.requests.contains { $0["path"] as? String == "/resource/direct-video" })
        XCTAssertEqual(browserCookieRequest["cookie_auth_valid"] as? Bool, true)
        XCTAssertEqual(persistentCookieRequest["status"] as? Int, 401)
        XCTAssertEqual(persistentCookieRequest["cookie_auth_valid"] as? Bool, false)
        XCTAssertEqual(persistentCookieRequest["cookie_names"] as? [String], [])
        XCTAssertEqual(ephemeralCookieRequest["cookie_auth_valid"] as? Bool, false)
        XCTAssertEqual(ephemeralCookieRequest["cookie_names"] as? [String], [])
        XCTAssertEqual(finalEvidence.postSideEffectCount, 0)
        XCTAssertEqual(slowTransfer["body_complete"] as? Bool, false)
        if let directVideoReceipt = event(
            kind: "receipt-accepted",
            caseID: "direct-page-video",
            in: finalEvidence.events,
        ) {
            let fields = try XCTUnwrap(directVideoReceipt["fields"] as? [String: Any])
            XCTAssertEqual(fields["byte_count"] as? String, "1478")
            XCTAssertEqual(
                fields["sha256"] as? String,
                "b366c8ac6b93776ef6d6196fc365e8e41312055bacbf546504c218b7875693f8",
            )
            XCTAssertEqual(fields["canonical_library_committed"] as? String, "false")
        }
    }

    func testTerminalEventRetainsOriginatingProfileAfterProfileSwitch() async throws {
        let app = XCUIApplication()
        app.launch()

        let pagePath = app.staticTexts["current-page-path"]
        let transferState = app.staticTexts["transfer-state"]
        XCTAssertTrue(pagePath.waitForExistence(timeout: 30))
        XCTAssertTrue(transferState.waitForExistence(timeout: 10))
        _ = try await waitForEvidence(timeout: 15) { evidence in
            evidence.requests.contains { $0["path"] as? String == "/" }
        }
        let previousOperationIDs = try await Set(readEvidence().events.compactMap { $0["operation_id"] as? String })

        tapFixtureLink("save-slow-cancel", in: app)
        waitForState("save-slow-cancel: downloading", transferState)
        let startedEvidence = try await waitForEvidence(timeout: 10) { evidence in
            evidence.events.contains { event in
                let operationID = event["operation_id"] as? String
                let fields = event["fields"] as? [String: Any]
                return event["kind"] as? String == "transfer-started"
                    && fields?["case_id"] as? String == "save-slow-cancel"
                    && operationID.map { !previousOperationIDs.contains($0) } == true
            }
        }
        let startedEvent = try XCTUnwrap(startedEvidence.events.last { event in
            let operationID = event["operation_id"] as? String
            let fields = event["fields"] as? [String: Any]
            return event["kind"] as? String == "transfer-started"
                && fields?["case_id"] as? String == "save-slow-cancel"
                && operationID.map { !previousOperationIDs.contains($0) } == true
        })
        let operationID = try XCTUnwrap(startedEvent["operation_id"] as? String)
        let originatingProfileID = try XCTUnwrap(startedEvent["profile_id"] as? String)
        let originatingProfile = try XCTUnwrap(startedEvent["profile"] as? String)
        XCTAssertEqual(originatingProfile, "persistent")

        app.buttons["profile-ephemeral"].tap()
        _ = try await waitForEvidence(timeout: 10) { evidence in
            evidence.events.contains { event in
                event["kind"] as? String == "profile-selected"
                    && event["profile"] as? String == "ephemeral"
                    && event["profile_id"] as? String != originatingProfileID
            }
        }

        let terminalEvidence = try await waitForEvidence(timeout: 15) { evidence in
            evidence.events.contains { event in
                event["kind"] as? String == "receipt-rejected"
                    && event["operation_id"] as? String == operationID
            }
        }
        let terminalEvent = try XCTUnwrap(terminalEvidence.events.first { event in
            event["kind"] as? String == "receipt-rejected"
                && event["operation_id"] as? String == operationID
        })
        let fields = try XCTUnwrap(terminalEvent["fields"] as? [String: Any])
        waitForState("save-slow-cancel: rejected unsupported content", transferState, timeout: 5)
        XCTAssertEqual(terminalEvent["operation_id"] as? String, operationID)
        XCTAssertEqual(terminalEvent["profile_id"] as? String, originatingProfileID)
        XCTAssertEqual(terminalEvent["profile"] as? String, originatingProfile)
        XCTAssertEqual(fields["case_id"] as? String, "save-slow-cancel")
        XCTAssertEqual(fields["receipt_published"] as? String, "false")
    }

    private func tapFixtureLink(
        _ identifier: String,
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line,
    ) {
        let labels = [
            "ordinary-navigation": "ordinary navigation",
            "login-persistent": "log in to the HttpOnly fixture",
            "open-cookie-resource": "open logged-in media in this browser",
            "save-link-still": "Save linked still to Vault",
            "save-video": "Save linked video to Vault",
            "save-truncated-video": "Reject truncated video container",
            "save-signed-still": "Save one-use still to Vault",
            "save-same-origin": "Save through same-origin redirects",
            "save-cross-origin": "Probe cross-origin redirect",
            "save-https-downgrade": "Probe HTTPS downgrade",
            "save-cookie-media": "Save logged-in media to Vault",
            "save-non-media": "Save unsupported binary to Vault",
            "save-claimed-image": "Save invalid claimed image to Vault",
            "save-missing": "Save missing resource to Vault",
            "save-slow-cancel": "Start cancellable transfer",
            "reject-post": "Reject POST acquisition",
            "reject-blob": "Reject blob URL",
            "reject-data": "Reject data URL",
        ]
        let label = labels[identifier] ?? identifier
        let link = app.links.matching(NSPredicate(format: "label == %@", label)).firstMatch
        XCTAssertTrue(link.waitForExistence(timeout: 15), "Missing fixture link: \(identifier)", file: file, line: line)
        if !link.isHittable {
            app.webViews.firstMatch.swipeUp()
        }
        XCTAssertTrue(link.isHittable, "Fixture link is not hittable: \(identifier)", file: file, line: line)
        link.tap()
    }

    private func waitForState(_ fragment: String, _ state: XCUIElement, timeout: TimeInterval = 30) {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS %@", fragment),
            object: state,
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [expectation], timeout: timeout),
            .completed,
            "Waiting for state: \(fragment)",
        )
    }

    private func waitForTerminalState(_ caseID: String, _ state: XCUIElement, timeout: TimeInterval = 30) {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(
                format: "label BEGINSWITH %@ AND NOT label CONTAINS %@",
                "\(caseID):",
                "downloading",
            ),
            object: state,
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [expectation], timeout: timeout),
            .completed,
            "Waiting for terminal state: \(caseID)",
        )
    }

    private func waitForPagePath(_ path: String, _ element: XCUIElement, timeout: TimeInterval = 30) {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", path),
            object: element,
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [expectation], timeout: timeout),
            .completed,
            "Waiting for page path: \(path)",
        )
    }

    private func waitForEvidence(
        timeout: TimeInterval,
        where predicate: (FixtureEvidence) -> Bool,
    ) async throws -> FixtureEvidence {
        let deadline = Date().addingTimeInterval(timeout)
        var latest = try await readEvidence()
        while Date() < deadline {
            if predicate(latest) {
                return latest
            }
            try await Task.sleep(for: .milliseconds(200))
            latest = try await readEvidence()
        }
        XCTAssertTrue(predicate(latest), "Fixture evidence did not reach the required state")
        return latest
    }

    private func readEvidence() async throws -> FixtureEvidence {
        let baseURL = try XCTUnwrap(URL(string: "http://127.0.0.1:18753"))
        let url = baseURL.appending(path: "/__spike/evidence")
            .appending(queryItems: [URLQueryItem(name: "cache-buster", value: UUID().uuidString)])
        let (data, _) = try await URLSession(configuration: .ephemeral).data(from: url)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return FixtureEvidence(
            requests: json["requests"] as? [[String: Any]] ?? [],
            events: json["app_events"] as? [[String: Any]] ?? [],
            transferEvents: json["transfer_events"] as? [[String: Any]] ?? [],
            postSideEffectCount: json["post_side_effect_count"] as? Int ?? -1,
        )
    }

    private func event(kind: String, caseID: String, in events: [[String: Any]]) -> [String: Any]? {
        events.first { event in
            event["kind"] as? String == kind
                && (event["fields"] as? [String: Any])?["case_id"] as? String == caseID
        }
    }
}

private struct FixtureEvidence {
    let requests: [[String: Any]]
    let events: [[String: Any]]
    let transferEvents: [[String: Any]]
    let postSideEffectCount: Int
}
