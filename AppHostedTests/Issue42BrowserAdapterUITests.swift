//
//  Issue42BrowserAdapterUITests.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import CoreGraphics
import Foundation
import XCTest
import XCUIAutomation

/// Exercises the real Root-to-WebKit bridge rather than a separately mounted test browser.
@MainActor
final class Issue42BrowserAdapterUITests: XCTestCase {
    private enum Failure: Error { case deadline, observations }

    func testMountedBrowserUsesCommandAdapterAndReturnsFromOverview() throws {
        let app = XCUIApplication(bundleIdentifier: "com.danielbyon.mediavault.issue42qualificationhost")
        app.launchArguments = [
            "--issue42-production-download-qualification",
            "--issue42-simulated-protection-readback",
        ]
        app.launch()
        defer { app.terminate() }
        try wait(app, "fixture controls") { app.buttons["issue42OpenFixturePage"].isHittable }
        app.buttons["issue42OpenFixturePage"].tap()
        var registeredBridge: [String: String]?
        try wait(app, "mounted WebKit command bridge registration") {
            registeredBridge = (try? self.observations(app))?.last { $0["event"] == "mountedWebKitBridge" }
            return registeredBridge != nil
        }
        let bridge = try XCTUnwrap(registeredBridge)
        // A blank page must fail on the ownership mismatch, not be accepted as a healthy baseline.
        XCTAssertEqual(bridge["adapterIdentity"], bridge["commandAdapterIdentity"])
        XCTAssert(bridge["adapterIdentity"] == bridge["commandAdapterIdentity"])
        var committed: [String: String]?
        try wait(app, "real HTML commit and attached originating WebKit view") {
            committed = (try? self.observations(app))?.last { $0["event"] == "fixtureNavigationCommitted" }
            return committed?["documentMatches"] == "true" && committed?["webViewAttached"] == "true"
        }
        let webViewIdentity = try XCTUnwrap(committed?["webViewIdentity"])
        let page = app.webViews.staticTexts["Issue42 first"]
        try wait(app, "visible fixture HTML") { page.exists && !page.frame.isEmpty }
        app.buttons["Show Tabs, 1 tabs"].tap()
        let overview = app.scrollViews["browser.tab-overview.scroll-view"]
        try wait(app, "mounted tab overview") { overview.exists }
        let card = overview.buttons
            .matching(NSPredicate(
                format: "label CONTAINS %@ AND NOT label BEGINSWITH %@",
                "Issue42 first",
                "Close ",
            ))
            .firstMatch
        try wait(app, "selected card body") { card.isHittable }
        card.tap()
        try wait(app, "actual browsing return") { !overview.exists && page.exists && !page.frame.isEmpty }
        let final = try observations(app)
        let execution = try XCTUnwrap(final
            .last { $0["event"] == "transitionExecution" && $0["direction"] == "toBrowsing" })
        XCTAssertEqual(execution["contentPresent"], "true")
        XCTAssertEqual(execution["contentAttached"], "true")
        XCTAssertEqual(final.last { $0["event"] == "fixtureNavigationCommitted" }?["webViewIdentity"], webViewIdentity)
        attach(app, "Root browser returned using its originating WebKit view")
    }

    private func observations(_ app: XCUIApplication) throws -> [[String: String]] {
        let refresh = app.buttons["issue42RefreshObservations"]
        guard refresh.isHittable else {
            throw Failure.observations
        }

        refresh.tap()
        guard let value = app.staticTexts["issue42QualificationObservations"].value as? String else {
            throw Failure.observations
        }

        return try JSONDecoder().decode([[String: String]].self, from: Data(value.utf8))
    }

    private func wait(_ app: XCUIApplication, _ milestone: String, condition: @escaping @MainActor () -> Bool) throws {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            MainActor.assumeIsolated { condition() }
        }, object: nil)
        guard XCTWaiter.wait(for: [expectation], timeout: 10) == .completed else {
            attach(app, "FAILED " + milestone)
            XCTFail("Timed out: " + milestone)
            throw Failure.deadline
        }
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        for attachment in [XCTAttachment(screenshot: app.screenshot()), XCTAttachment(string: app.debugDescription)] {
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }
}
