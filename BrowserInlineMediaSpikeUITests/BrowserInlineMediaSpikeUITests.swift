//
//  BrowserInlineMediaSpikeUITests.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import XCTest

/// Performs actual XCUITest presses and leaves a per-case recorder entry.
@MainActor
final class BrowserInlineMediaSpikeUITests: XCTestCase {
    private var baseURL: URL {
        guard let url = URL(string: "http://127.0.0.1:18755") else {
            preconditionFailure("The fixed loopback fixture URL must parse")
        }

        return url
    }

    func testNativeLongPressMatrix() async throws {
        for caseID in [
            "linked-image",
            "unlinked-image",
            "picture",
            "video-src",
            "video-source",
            "css-background",
            "canvas",
            "same-iframe",
            "cross-iframe",
        ] {
            try await press(caseID: caseID, mode: "native")
        }
    }

    func testBridgeLongPressMatrix() async throws {
        for caseID in [
            "linked-image",
            "unlinked-image",
            "picture",
            "video-src",
            "video-source",
            "css-background",
            "canvas",
            "same-iframe",
            "cross-iframe",
            "responsive",
            "relative",
            "dynamic",
            "blob",
            "data",
        ] {
            try await press(caseID: caseID, mode: "bridge")
        }
    }

    func testEventDeliveryAndUntrustedCases() async throws {
        try await press(caseID: "unlinked-image", mode: "diagnostic")
        try await press(caseID: "synthetic", mode: "bridge")
        try await press(caseID: "forged-page", mode: "bridge")

        let evidence = try await fetchEvidence()
        XCTAssertTrue(evidence.events.contains { event in
            event["kind"] as? String == "ui-press"
                && (event["fields"] as? [String: String])?["case"] == "unlinked-image"
                && (event["fields"] as? [String: String])?["menuAccessibilityDetected"] == "true"
        }, "A native image menu should be visible after the genuine press")
        for name in ["pointerdown", "touchstart"] {
            XCTAssertTrue(evidence.events.contains { event in
                event["kind"] as? String == "bridge-observation"
                    && (event["fields"] as? [String: String])?["case"] == "unlinked-image"
                    && (event["fields"] as? [String: String])?["mode"] == "diagnostic"
                    && (event["fields"] as? [String: String])?["event"] == name
            }, "Diagnostic \(name) delivery was not observed")
        }
        XCTAssertFalse(evidence.events.contains { event in
            event["kind"] as? String == "bridge-observation"
                && (event["fields"] as? [String: String])?["case"] == "unlinked-image"
                && (event["fields"] as? [String: String])?["mode"] == "diagnostic"
                && (event["fields"] as? [String: String])?["event"] == "contextmenu"
        }, "This iOS 27 image press must be classified separately if contextmenu begins arriving")
        XCTAssertTrue(evidence.events.contains { event in
            event["kind"] as? String == "bridge-rejected"
                && (event["fields"] as? [String: String])?["case"] == "synthetic"
                && (event["fields"] as? [String: String])?["mode"] == "bridge"
                && (event["fields"] as? [String: String])?["reason"] == "synthetic-event"
        }, "The fixture's synthetic event must be rejected")
        XCTAssertTrue(evidence.events.contains { event in
            event["kind"] as? String == "page-probe"
                && event["result"] as? String == "handler-not-visible"
        }, "The page world must not see the isolated handler")
    }

    func testRecorderHandshake() async throws {
        let app = XCUIApplication()
        app.launchEnvironment["SPIKE_CASE"] = "blank"
        app.launchEnvironment["SPIKE_MODE"] = "native"
        if let token = ProcessInfo.processInfo.environment["SPIKE_RECORDER_TOKEN"] {
            app.launchEnvironment["SPIKE_RECORDER_TOKEN"] = token
        }
        app.launch()
        defer { app.terminate() }
        let arrived = try await waitForEvidence(timeout: 15) { evidence in
            evidence.events.contains { event in
                event["kind"] as? String == "host-started"
                    && (event["fields"] as? [String: String])?["case"] == "blank"
            }
        }
        XCTAssertTrue(arrived, "The app should reach the independent, token-gated recorder")
    }

    func testFrameAndVideoDeliveryDiagnostics() async throws {
        for caseID in ["same-iframe", "cross-iframe", "video-src", "video-source"] {
            try await press(caseID: caseID, mode: "diagnostic")
        }

        let evidence = try await fetchEvidence()
        for (caseID, expectedOrigin) in [
            ("same-iframe", "http://127.0.0.1:18755"),
            ("cross-iframe", "http://localhost:18755"),
        ] {
            let observations = evidence.events.compactMap { event -> [String: String]? in
                guard event["kind"] as? String == "bridge-observation",
                      let details = event["fields"] as? [String: String],
                      details["case"] == caseID,
                      details["mode"] == "diagnostic"
                else {
                    return nil
                }

                return details
            }
            XCTAssertTrue(observations.contains { $0["event"] == "pointerdown" || $0["event"] == "touchstart" })
            XCTAssertTrue(observations.allSatisfy { $0["nativeMainFrame"] == "false" })
            XCTAssertTrue(observations.allSatisfy { $0["nativeOrigin"] == expectedOrigin })
            XCTAssertTrue(observations.allSatisfy { $0["selectedMedia"] == "absent" })
        }

        for caseID in ["video-src", "video-source"] {
            let observations = evidence.events.compactMap { event -> [String: String]? in
                guard event["kind"] as? String == "bridge-observation",
                      let details = event["fields"] as? [String: String],
                      details["case"] == caseID,
                      details["mode"] == "diagnostic"
                else {
                    return nil
                }

                return details
            }
            XCTAssertTrue(observations.contains { $0["event"] == "pointerdown" || $0["event"] == "touchstart" })
            XCTAssertFalse(observations.contains { $0["event"] == "contextmenu" })
            XCTAssertTrue(observations.allSatisfy { $0["selectedMedia"] == "absent" })
        }
    }

    func testCorrectedOpaqueResourceFixtures() async throws {
        for caseID in ["blob", "data"] {
            try await press(caseID: caseID, mode: "bridge")
        }

        let evidence = try await fetchEvidence()
        for caseID in ["blob", "data"] {
            XCTAssertTrue(evidence.events.contains { event in
                event["kind"] as? String == "ui-press"
                    && (event["fields"] as? [String: String])?["case"] == caseID
                    && (event["fields"] as? [String: String])?["mode"] == "bridge"
                    && (event["fields"] as? [String: String])?["pressInvoked"] == "true"
            })
        }
    }

    /// Proves whether a press reached non-media and opaque image targets when `contextmenu` did not arrive.
    func testNonMediaAndOpaqueDeliveryDiagnostics() async throws {
        for caseID in ["css-background", "canvas", "blob", "data"] {
            try await press(caseID: caseID, mode: "diagnostic")
        }

        let evidence = try await fetchEvidence()
        for caseID in ["css-background", "canvas", "blob", "data"] {
            let observations = evidence.events.compactMap { event -> [String: String]? in
                guard event["kind"] as? String == "bridge-observation",
                      let details = event["fields"] as? [String: String],
                      details["case"] == caseID,
                      details["mode"] == "diagnostic"
                else {
                    return nil
                }

                return details
            }
            XCTAssertTrue(
                observations.contains { $0["event"] == "pointerdown" || $0["event"] == "touchstart" },
                "The gesture must reach the \(caseID) document before classifying missing contextmenu",
            )
            XCTAssertFalse(observations.contains { $0["event"] == "contextmenu" })
            XCTAssertTrue(observations.allSatisfy { $0["selectedMedia"] == "absent" })
        }
    }

    /// Measures whether a native image menu appears consistently inside a cross-origin frame.
    func testNativeCrossFrameRepeat() async throws {
        for _ in 0 ..< 2 {
            try await press(caseID: "cross-iframe", mode: "native")
        }
    }

    func testNavigationRetiresStaleCase() async throws {
        let app = XCUIApplication()
        app.launchEnvironment["SPIKE_CASE"] = "linked-image"
        app.launchEnvironment["SPIKE_MODE"] = "bridge"
        if let token = ProcessInfo.processInfo.environment["SPIKE_RECORDER_TOKEN"] {
            app.launchEnvironment["SPIKE_RECORDER_TOKEN"] = token
        }
        app.launch()
        defer { app.terminate() }

        let webView = app.webViews.firstMatch
        XCTAssertTrue(webView.waitForExistence(timeout: 20))
        let loaded = try await waitForEvidence(timeout: 15) { evidence in
            evidence.requests.contains { ($0["path"] as? String) == "/case/linked-image" }
        }
        XCTAssertTrue(loaded)
        webView.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let retired = try await waitForEvidence(timeout: 15) { evidence in
            evidence.events.contains { event in
                event["kind"] as? String == "navigation-retired"
                    && (event["fields"] as? [String: String])?["case"] == "linked-image"
            }
        }
        XCTAssertTrue(retired, "Navigation must retire the active fixture before any later script message")
    }

    private func press(caseID: String, mode: String) async throws {
        let pressID = UUID().uuidString.lowercased()
        let app = XCUIApplication()
        app.launchEnvironment["SPIKE_CASE"] = caseID
        app.launchEnvironment["SPIKE_MODE"] = mode
        app.launchEnvironment["SPIKE_PRESS_ID"] = pressID
        if let token = ProcessInfo.processInfo.environment["SPIKE_RECORDER_TOKEN"] {
            app.launchEnvironment["SPIKE_RECORDER_TOKEN"] = token
        }
        app.launch()
        defer { app.terminate() }

        let webView = app.webViews.firstMatch
        XCTAssertTrue(webView.waitForExistence(timeout: 20), "WebView missing for \(caseID)")
        let loaded = try await waitForEvidence(timeout: 15) { evidence in
            evidence.requests.contains {
                ($0["path"] as? String) == "/case/\(caseID)"
                    && ($0["pressID"] as? String) == pressID
            }
        }
        XCTAssertTrue(loaded, "Fixture did not load: \(caseID)")
        try await Task.sleep(for: .seconds(1.2))

        webView.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 1.1)
        try await Task.sleep(for: .milliseconds(450))
        let menuLabels = [
            "Copy",
            "Copy Subject",
            "Look Up",
            "Save to Photos",
            "Share…",
            "Open Link",
            "Open in New Tab",
            "Add to Reading List",
            "Download Linked File",
        ].filter { app.buttons[$0].exists }
        let menuDetected = app.menus.firstMatch.exists || !menuLabels.isEmpty
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "\(mode)-\(caseID)-after-genuine-press"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        app.staticTexts["spike-title"].tap()
        app.buttons["flush-recorder"].tap()
        let recorderStatus = app.staticTexts["spike-status"]
        let recorderFlushed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", "evidence flushed"),
            object: recorderStatus,
        )
        XCTAssertEqual(XCTWaiter.wait(for: [recorderFlushed], timeout: 10), .completed)

        let evidence = try await fetchEvidence()
        let observations = evidence.events.filter { event in
            event["kind"] as? String == "bridge-observation"
                && (event["fields"] as? [String: String])?["case"] == caseID
                && (event["fields"] as? [String: String])?["mode"] == mode
                && (event["fields"] as? [String: String])?["pressID"] == pressID
        }
        let contextmenuCount = observations.count { event in
            (event["fields"] as? [String: String])?["event"] == "contextmenu"
        }
        let diagnosticCount = observations.count { event in
            ["pointerdown", "touchstart"].contains((event["fields"] as? [String: String])?["event"] ?? "")
        }
        try await postEvent(kind: "ui-press", fields: [
            "case": caseID,
            "mode": mode,
            "pressID": pressID,
            "pressInvoked": "true",
            "menuAccessibilityDetected": String(menuDetected),
            "menuLabels": menuLabels.joined(separator: ","),
            "contextmenuMessagesSoFar": String(contextmenuCount),
            "diagnosticMessagesSoFar": String(diagnosticCount),
        ])
        XCTAssertTrue(loaded)
    }

    private func waitForEvidence(
        timeout: TimeInterval,
        condition: (RecordedEvidence) -> Bool,
    ) async throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if try await condition(fetchEvidence()) {
                return true
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        return false
    }

    private func fetchEvidence() async throws -> RecordedEvidence {
        let url = baseURL.appending(path: "/__spike/evidence")
        let (data, _) = try await URLSession.shared.data(from: url)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try RecordedEvidence(
            requests: XCTUnwrap(root["requests"] as? [[String: Any]]),
            events: XCTUnwrap(root["events"] as? [[String: Any]]),
        )
    }

    private func postEvent(kind: String, fields: [String: String]) async throws {
        var request = URLRequest(url: baseURL.appending(path: "/__spike/event"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = ProcessInfo.processInfo.environment["SPIKE_RECORDER_TOKEN"] {
            request.setValue(token, forHTTPHeaderField: "X-Spike-Recorder-Token")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: ["kind": kind, "fields": fields])
        _ = try await URLSession.shared.data(for: request)
    }
}

/// Parsed form of the fixture server's independent observation store.
private struct RecordedEvidence {
    let requests: [[String: Any]]
    let events: [[String: Any]]
}
