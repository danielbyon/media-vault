//
//  BrowserTabOverviewScrollUITests.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import XCTest

@MainActor
final class BrowserTabOverviewScrollUITests: XCTestCase {
    func testUserScrollCommitsLogicalAnchorThroughStablePositionCallback() {
        let app = XCUIApplication()
        app.launch()

        let scrollView = app.scrollViews["browser.tab-overview.scroll-view"]
        XCTAssertTrue(scrollView.waitForExistence(timeout: 10))

        let savedAnchor = app.staticTexts["browser.tab-overview.saved-anchor"]
        XCTAssertTrue(savedAnchor.waitForExistence(timeout: 10))
        let initialValue = savedAnchor.label
        XCTAssertEqual(initialValue, "anchor-0|commits-0")

        let dragStart = scrollView.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
        let dragEnd = scrollView.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2))
        dragStart.press(forDuration: 0.1, thenDragTo: dragEnd)

        let anchorWasCommitted = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label != %@", initialValue),
            object: savedAnchor,
        )
        XCTAssertEqual(XCTWaiter.wait(for: [anchorWasCommitted], timeout: 10), .completed)

        let committedValue = savedAnchor.label.split(separator: "|")
        XCTAssertEqual(committedValue.count, 2)
        XCTAssertNotEqual(committedValue[0], "anchor-0")
        XCTAssertTrue(committedValue[1].hasPrefix("commits-"))
        XCTAssertGreaterThan(Int(committedValue[1].dropFirst("commits-".count)) ?? 0, 0)
    }

    func testReducerAnchorRestorationDoesNotPersistProgrammaticScrollEchoes() {
        let app = XCUIApplication()
        app.launchArguments = ["--restore-last-tab"]
        app.launch()

        let savedAnchor = app.staticTexts["browser.tab-overview.saved-anchor"]
        XCTAssertTrue(savedAnchor.waitForExistence(timeout: 10))
        XCTAssertEqual(savedAnchor.label, "anchor-39|commits-0")

        let restoreState = app.staticTexts["browser.tab-overview.programmatic-restore-state"]
        XCTAssertTrue(restoreState.waitForExistence(timeout: 10))
        let settled = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", "settled"),
            object: restoreState,
        )
        XCTAssertEqual(XCTWaiter.wait(for: [settled], timeout: 10), .completed)
        XCTAssertEqual(savedAnchor.label, "anchor-39|commits-0")
    }

    func testTabRemovalReconciliationDoesNotPersistProgrammaticScrollEchoes() {
        let app = XCUIApplication()
        app.launchArguments = ["--reconcile-close-last-tab"]
        app.launch()

        let savedAnchor = app.staticTexts["browser.tab-overview.saved-anchor"]
        XCTAssertTrue(savedAnchor.waitForExistence(timeout: 10))
        XCTAssertEqual(savedAnchor.label, "anchor-39|commits-0")

        let restoreState = app.staticTexts["browser.tab-overview.programmatic-restore-state"]
        XCTAssertTrue(restoreState.waitForExistence(timeout: 10))
        let initialRestoreSettled = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", "settled"),
            object: restoreState,
        )
        XCTAssertEqual(XCTWaiter.wait(for: [initialRestoreSettled], timeout: 10), .completed)

        let closeButtons = app.buttons.matching(
            NSPredicate(format: "label == %@", "Close Start Page"),
        )
        XCTAssertGreaterThan(closeButtons.count, 0)
        closeButtons.element(boundBy: closeButtons.count - 1).tap()

        let reconciled = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", "anchor-38|commits-0"),
            object: savedAnchor,
        )
        XCTAssertEqual(XCTWaiter.wait(for: [reconciled], timeout: 10), .completed)
        let reconciliationSettled = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", "settled"),
            object: restoreState,
        )
        XCTAssertEqual(XCTWaiter.wait(for: [reconciliationSettled], timeout: 10), .completed)
        XCTAssertEqual(savedAnchor.label, "anchor-38|commits-0")
    }

}
