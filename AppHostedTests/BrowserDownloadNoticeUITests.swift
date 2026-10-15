//
//  BrowserDownloadNoticeUITests.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import CoreGraphics
import Foundation
import XCTest
import XCUIAutomation

/// External accessibility observations qualify SwiftUI-rendered notice text. In-process UIKit
/// container traversal does not expose the full SwiftUI semantic tree in the hosted test runner.
@MainActor
final class BrowserDownloadNoticeUITests: XCTestCase {
    func testNoticeReplacement() {
        let app = XCUIApplication(bundleIdentifier: "com.danielbyon.mediavault.issue42qualificationhost")
        app.launchArguments = ["--issue42-browser-notice-qualification"]
        app.launch()
        defer { app.terminate() }

        let notices = app.staticTexts.matching(identifier: "browserDownloadNotice")
        let notice = notices.firstMatch
        let capacity = "Download limit reached. Four downloads can transfer at once. Cancel an active download and try again."
        XCTAssertTrue(notice.waitForExistence(timeout: 10))
        capture(app, milestone: "capacity notice")
        XCTAssert(notice.exists)

        XCTAssertEqual(notices.count, 1)
        XCTAssertEqual(notice.label, capacity)
        assertOnscreen(notice, in: app)

        let retainedLimit = "Download limit reached. Eight downloads are kept in the list. Discard a download and try again."
        let showRetainedLimit = app.buttons["issue42ShowRetainedLimitNotice"]
        XCTAssertTrue(showRetainedLimit.exists)
        XCTAssertTrue(showRetainedLimit.isHittable)
        showRetainedLimit.tap()
        let retained = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", retainedLimit),
            object: notice,
        )
        XCTAssertEqual(XCTWaiter.wait(for: [retained], timeout: 10), .completed)
        capture(app, milestone: "retained-limit notice")
        XCTAssertEqual(notices.count, 1)
        XCTAssertEqual(notice.label, retainedLimit)
        XCTAssertFalse(app.staticTexts[capacity].exists)
        assertOnscreen(notice, in: app)

        let replace = app.buttons["issue42ReplaceDownloadNotice"]
        XCTAssertTrue(replace.exists)
        XCTAssertTrue(replace.isHittable)
        replace.tap()
        let replaced = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", "The download could not be completed safely."),
            object: notice,
        )
        XCTAssertEqual(XCTWaiter.wait(for: [replaced], timeout: 10), .completed)
        capture(app, milestone: "replacement notice")
        XCTAssertEqual(notices.count, 1)
        XCTAssertEqual(notice.label, "The download could not be completed safely.")
        XCTAssertFalse(app.staticTexts[capacity].exists)
        assertOnscreen(notice, in: app)
    }

    private func assertOnscreen(_ notice: XCUIElement, in app: XCUIApplication) {
        XCTAssertFalse(notice.frame.isEmpty)
        XCTAssertTrue(app.frame.intersects(notice.frame))
        XCTAssertTrue(notice.isHittable)
    }

    /// Keep both pixels and external semantic-tree evidence for each milestone, including failures.
    private func capture(_ app: XCUIApplication, milestone: String) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = milestone
        screenshot.lifetime = .keepAlways
        add(screenshot)
        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = "\(milestone) accessibility tree"
        tree.lifetime = .keepAlways
        add(tree)
    }
}
