import GameController
import XCTest

@MainActor
final class CalculatorHardwareKeyboardUITests: XCTestCase {
    func testHardwareKeyboardUsesCalculatorActionsAndPreservesNativeActivation() throws {
        try requireHardwareKeyboard()

        let app = launchCalculator(seededHistory: true)
        let one = app.buttons["One"]
        XCTAssertTrue(one.waitForExistence(timeout: 10))
        one.tap()

        app.typeText("+2=")

        let display = app.staticTexts["Calculator display"]
        let showsExpectedResult = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", "3"),
            object: display,
        )
        XCTAssertEqual(XCTWaiter.wait(for: [showsExpectedResult], timeout: 5), .completed)

        let clearHistory = app.buttons["calculator.clear-history"]
        XCTAssertTrue(clearHistory.waitForExistence(timeout: 10))

        var tabCount = 0
        while !clearHistory.hasFocus && tabCount < 40 {
            app.typeKey(XCUIKeyboardKey.tab, modifierFlags: [])
            tabCount += 1
        }
        XCTAssertTrue(clearHistory.hasFocus, "Tab navigation should focus the history action")
        app.typeKey(XCUIKeyboardKey.return, modifierFlags: [])

        let historyWasCleared = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: clearHistory,
        )
        XCTAssertEqual(XCTWaiter.wait(for: [historyWasCleared], timeout: 5), .completed)
    }

    func testCalculatorControlsExposeAccessibleNamesAndActions() {
        let app = launchCalculator(seededHistory: true)

        let display = app.staticTexts["Calculator display"]
        XCTAssertTrue(display.waitForExistence(timeout: 10))
        XCTAssertEqual(display.value as? String, "0")

        for label in ["Seven", "Add to memory", "Open parenthesis", "Copy", "Paste", "Clear history"] {
            let control = app.buttons[label]
            XCTAssertTrue(control.exists, "Expected an accessible button named \(label)")
            XCTAssertTrue(control.isHittable, "Expected \(label) to remain available to assistive interaction")
        }

        app.buttons["calculator.clear-history"].tap()
        XCTAssertFalse(app.buttons["calculator.clear-history"].exists)
    }

    private func launchCalculator(seededHistory: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--calculator-basic"]
        if seededHistory {
            app.launchArguments.append("--calculator-seeded-history")
        }
        app.launch()
        return app
    }

    private func requireHardwareKeyboard() throws {
        guard GCKeyboard.coalesced != nil else {
            throw XCTSkip("This simulator run has no connected hardware keyboard.")
        }
    }
}
