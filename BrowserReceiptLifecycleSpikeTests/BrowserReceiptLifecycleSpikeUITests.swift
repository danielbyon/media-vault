//
//  BrowserReceiptLifecycleSpikeUITests.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import XCTest

@MainActor
final class BrowserReceiptLifecycleSpikeUITests: XCTestCase {
    #if !targetEnvironment(simulator)
    /// Allows an operator to lock a physical device during a fixed slow transfer.
    func testPhysicalLockedBackgroundReceipt() throws {
        let app = XCUIApplication()
        app.launch()
        let count = try receiptCount(in: app)
        app.buttons["start-slow"].tap()
        waitForStatus("downloading", in: app, timeout: 15)
        XCUIDevice.shared.press(.home)
        NSLog("SPIKE6_LOCK_NOW")
        Thread.sleep(forTimeInterval: 65)
        NSLog("SPIKE6_UNLOCK_NOW")
        app.activate()
        XCTAssertEqual(try receiptCount(in: app), count + 1)
        app.buttons["test-unlock"].tap()
        app.buttons["verify-receipts"].tap()
        waitForStatus("verified", in: app, timeout: 20)
    }
    #endif

    func testNewTransfersWaitForRestoredTaskEnumeration() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--spike-delay-task-enumeration"]
        app.launch()

        let start = app.buttons["start-still"]
        XCTAssertTrue(start.waitForExistence(timeout: 20))
        XCTAssertFalse(start.isEnabled, "a new transfer must wait for restored background tasks")

        let ready = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "isEnabled == true"),
            object: start,
        )
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 15), .completed)
    }

    func testLockedReceiptSurvivesHarnessRelaunchAndWaitsForTestUnlock() throws {
        let app = XCUIApplication()
        app.launch()
        let count = try receiptCount(in: app)
        app.buttons["start-still"].tap()
        waitForStatus("receipt accepted", in: app, timeout: 45)
        XCTAssertEqual(try receiptCount(in: app), count + 1)

        app.terminate()
        app.launch()
        XCTAssertEqual(try receiptCount(in: app), count + 1)
        app.buttons["verify-receipts"].tap()
        waitForStatus("test unlock required", in: app, timeout: 10)
        app.buttons["test-unlock"].tap()
        app.buttons["verify-receipts"].tap()
        waitForStatus("verified", in: app, timeout: 15)
    }

    func testCancellationDoesNotPublishPartialTransfer() throws {
        let app = XCUIApplication()
        app.launch()
        let count = try receiptCount(in: app)
        app.buttons["start-slow"].tap()
        waitForStatus("downloading", in: app, timeout: 10)
        app.buttons["cancel-transfer"].tap()
        waitForStatus("cancelled (terminal callback observed)", in: app, timeout: 10)
        XCTAssertEqual(try receiptCount(in: app), count)
    }

    func testHomeBackgroundedTransferPublishesAfterForegrounding() throws {
        let app = XCUIApplication()
        app.launch()
        let count = try receiptCount(in: app)
        app.buttons["start-slow"].tap()
        waitForStatus("downloading", in: app, timeout: 10)
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 2)
        app.activate()
        waitForStatus("receipt accepted", in: app, timeout: 90)
        XCTAssertEqual(try receiptCount(in: app), count + 1)
    }

    func testBoundedTimeoutDoesNotPublishPartialTransfer() throws {
        let app = XCUIApplication()
        app.launch()
        let count = try receiptCount(in: app)
        app.buttons["start-timeout"].tap()
        waitForStatus("transfer timed out", in: app, timeout: 25)
        XCTAssertEqual(try receiptCount(in: app), count)
    }

    func testHarnessTerminatedTransferReattachesAfterExplicitLaunch() throws {
        let app = XCUIApplication()
        app.launch()
        let count = try receiptCount(in: app)
        app.buttons["start-slow"].tap()
        waitForStatus("downloading", in: app, timeout: 10)
        app.terminate()
        app.launch()
        let status = app.staticTexts["receipt-status"]
        let reattachedOrCompleted = XCTNSPredicateExpectation(
            predicate: NSPredicate(
                format: "label CONTAINS %@ OR label == %@",
                "downloading (reattached)",
                "receipt accepted",
            ),
            object: status,
        )
        XCTAssertEqual(XCTWaiter.wait(for: [reattachedOrCompleted], timeout: 30), .completed)
        if status.label.contains("reattached") {
            XCTAssertTrue(app.buttons["cancel-transfer"].isEnabled)
        }
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(
                format: "label == %@ OR label == %@",
                "receipt accepted",
                "locked; \(count + 1) receipt(s) discoverable",
            ),
            object: status,
        )
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 90), .completed)
        XCTAssertEqual(try receiptCount(in: app), count + 1)
    }

    private func receiptCount(in app: XCUIApplication) throws -> Int {
        let label = app.staticTexts["receipt-count"]
        XCTAssertTrue(label.waitForExistence(timeout: 20))
        return try XCTUnwrap(Int(label.label.replacing("Published receipts: ", with: "")))
    }

    private func waitForStatus(_ expected: String, in app: XCUIApplication, timeout: TimeInterval) {
        let status = app.staticTexts["receipt-status"]
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS %@", expected),
            object: status,
        )
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: timeout), .completed)
    }
}
