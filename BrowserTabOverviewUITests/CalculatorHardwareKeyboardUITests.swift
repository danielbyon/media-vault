//
//  CalculatorHardwareKeyboardUITests.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import GameController
import XCTest

@MainActor
final class CalculatorHardwareKeyboardUITests: XCTestCase {
    func testFocusedCalculatorSurfaceReceivesHardwareKeyInput() throws {
        guard GCKeyboard.coalesced != nil else {
            throw XCTSkip("Connect a hardware keyboard to run this focused-surface UI test.")
        }

        let app = XCUIApplication()
        app.launchArguments = ["--calculator-keyboard"]
        app.launch()

        let surface = app.scrollViews["calculator.keyboard-input-surface"]
        let display = app.staticTexts["Calculator display"]
        let initialFocusTarget = app.buttons["Clear"]
        XCTAssertTrue(surface.waitForExistence(timeout: 10))
        XCTAssertTrue(display.waitForExistence(timeout: 10))
        XCTAssertTrue(initialFocusTarget.waitForExistence(timeout: 10))
        XCTAssertEqual(display.value as? String, "0")

        let initialFocus = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "hasFocus == true"),
            object: initialFocusTarget,
        )
        XCTAssertEqual(XCTWaiter.wait(for: [initialFocus], timeout: 5), .completed)

        let twoButton = app.buttons["Two"]
        twoButton.tap()
        let restoredFocus = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "hasFocus == true"),
            object: twoButton,
        )
        XCTAssertEqual(XCTWaiter.wait(for: [restoredFocus], timeout: 5), .completed)

        twoButton.typeText("7")

        let updatedDisplay = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", "27"),
            object: display,
        )
        XCTAssertEqual(XCTWaiter.wait(for: [updatedDisplay], timeout: 5), .completed)

        let copyButton = app.buttons["Copy"]
        XCTAssertTrue(copyButton.waitForExistence(timeout: 5))
        for _ in 0 ..< 32 {
            if copyButton.hasFocus {
                break
            }
            app.typeKey(.tab, modifierFlags: .shift)
        }
        XCTAssertTrue(copyButton.hasFocus)

        copyButton.typeText("8")

        let updatedFromSiblingControl = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", "278"),
            object: display,
        )
        XCTAssertEqual(XCTWaiter.wait(for: [updatedFromSiblingControl], timeout: 5), .completed)
    }
}
