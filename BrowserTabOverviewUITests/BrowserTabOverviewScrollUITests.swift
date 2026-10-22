//
//  BrowserTabOverviewScrollUITests.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import CoreFoundation
import CoreGraphics
import Foundation
import XCTest
import XCUIAutomation

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

    func testShowTabsSelectedCardPlacementRegressionFixtureA() {
        runShowTabsFixture(
            fixture: "A",
            selectedIndex: 8,
            anchorIndex: 0,
        )
    }

    func testShowTabsSelectedCardPlacementControlFixtureB() {
        runShowTabsFixture(
            fixture: "B",
            selectedIndex: 0,
            anchorIndex: 12,
        )
    }

    func testShowTabsSelectedCardPlacementAlreadyVisibleControlFixtureC() {
        runShowTabsFixture(
            fixture: "C",
            selectedIndex: 8,
            anchorIndex: 8,
            expectsTransitionTargetRequest: false,
        )
    }

    func testShowTabsSelectedCardPlacementCompactRegressionFixtureA() {
        runShowTabsFixture(
            fixture: "A",
            selectedIndex: 8,
            anchorIndex: 0,
            sizeClass: "compact",
        )
    }

    func testShowTabsSelectedCardPlacementCompactControlFixtureB() {
        runShowTabsFixture(
            fixture: "B",
            selectedIndex: 0,
            anchorIndex: 12,
            sizeClass: "compact",
        )
    }

    func testShowTabsSelectedCardPlacementCompactAlreadyVisibleControlFixtureC() {
        runShowTabsFixture(
            fixture: "C",
            selectedIndex: 8,
            anchorIndex: 8,
            sizeClass: "compact",
            expectsTransitionTargetRequest: false,
        )
    }

    private func runShowTabsFixture(
        fixture: String,
        selectedIndex: Int,
        anchorIndex: Int,
        sizeClass: String = "regular",
        expectsTransitionTargetRequest: Bool = true,
    ) {
        for run in 1 ... 3 {
            let context = "fixture \(fixture), run \(run)"
            let app = XCUIApplication()
            app.launchArguments = [
                "--show-tabs-placement",
                "--show-tabs-placement-size-class=" + sizeClass,
                "--show-tabs-placement-fixture=\(fixture)",
            ]
            app.launch()

            let status = app.staticTexts["browser.show-tabs-placement.status"]
            XCTAssertTrue(
                status.waitForExistence(timeout: 15),
                "\(context): status did not appear",
            )
            XCTAssertEqual(
                app.staticTexts
                    .matching(
                        identifier: "browser.show-tabs-placement.status",
                    )
                    .count,
                1,
                "\(context): expected one fixture status",
            )

            let showTabs = app.buttons
                .matching(
                    NSPredicate(format: "label == %@", "Show Tabs, 24 tabs"),
                )
                .firstMatch
            XCTAssertTrue(
                showTabs.waitForExistence(timeout: 10),
                "\(context): production Show Tabs button did not appear",
            )
            XCTAssertTrue(
                showTabs.isHittable,
                "\(context): production Show Tabs button was not hittable",
            )

            let initialStatus = ShowTabsPlacementStatusFields(status.label)
            XCTAssertEqual(initialStatus.value(for: "fixture"), fixture, context)
            XCTAssertEqual(
                initialStatus.value(for: "selected"),
                "\(selectedIndex)",
                context,
            )
            XCTAssertEqual(
                initialStatus.value(for: "anchor"),
                "\(anchorIndex)",
                context,
            )
            XCTAssertEqual(initialStatus.value(for: "sizeClass"), sizeClass, context)

            showTabs.tap()

            let transitionFinished = XCTNSPredicateExpectation(
                predicate: NSPredicate { object, _ in
                    guard let statusElement = object as? XCUIElement else {
                        return false
                    }

                    let label = statusElement.label
                    let failed = label.contains("sawMissingDestination=true")
                        || label.contains("sawPresentationUnavailable=true")
                    let completed = label.contains("animatorCompleted=true")
                        && label.contains("transitionReleased=true")
                    return failed || completed
                },
                object: status,
            )
            XCTAssertEqual(
                XCTWaiter.wait(for: [transitionFinished], timeout: 30),
                .completed,
                "\(context): transition did not reach a terminal observation",
            )

            let finalStatus = ShowTabsPlacementStatusFields(status.label)
            let finalContext = "\(context): \(status.label)"
            XCTAssertEqual(
                finalStatus.value(for: "targetRequested"),
                String(expectsTransitionTargetRequest),
                finalContext,
            )
            XCTAssertEqual(finalStatus.value(for: "targetReady"), "true", finalContext)
            XCTAssertEqual(
                finalStatus.value(for: "targetContainedAtReady"),
                "true",
                finalContext,
            )
            XCTAssertEqual(finalStatus.value(for: "readySettled"), "true", finalContext)
            XCTAssertEqual(finalStatus.value(for: "readyObservationCount"), "1", finalContext)
            XCTAssertEqual(finalStatus.value(for: "readinessViolation"), "false", finalContext)
            XCTAssertEqual(finalStatus.value(for: "sawMissingDestination"), "false", finalContext)
            XCTAssertEqual(
                finalStatus.value(for: "sawPresentationUnavailable"),
                "false",
                finalContext,
            )
            XCTAssertEqual(finalStatus.value(for: "targetContained"), "true", finalContext)
            XCTAssertEqual(finalStatus.value(for: "scrollPhase"), "idle", finalContext)
            XCTAssertEqual(finalStatus.value(for: "animatorCreated"), "true", finalContext)
            XCTAssertEqual(finalStatus.value(for: "animatorCompleted"), "true", finalContext)
            XCTAssertEqual(finalStatus.value(for: "animatorCompletion"), "end", finalContext)
            XCTAssertEqual(finalStatus.value(for: "execution"), "geometry", finalContext)
            XCTAssertEqual(finalStatus.value(for: "terminal"), "revealed", finalContext)
            XCTAssertEqual(finalStatus.value(for: "transitionActive"), "false", finalContext)
            XCTAssertEqual(
                finalStatus.value(for: "transitionRequestCount"),
                expectsTransitionTargetRequest ? "1" : "0",
                finalContext,
            )
            XCTAssertEqual(
                finalStatus.value(for: "transitionReleaseCount"),
                expectsTransitionTargetRequest ? "1" : "0",
                finalContext,
            )
            XCTAssertEqual(finalStatus.value(for: "transitionReleased"), "true", finalContext)
            XCTAssertEqual(
                finalStatus.value(for: "anchor"),
                "\(anchorIndex)",
                "\(context): saved logical anchor changed",
            )

            XCTAssertEqual(finalStatus.value(for: "anchorChangeCount"), "0", finalContext)
            XCTAssertEqual(finalStatus.value(for: "anchorMissing"), "false", finalContext)
            XCTAssertEqual(
                finalStatus.value(for: "live"),
                String(selectedIndex),
                finalContext + ": live transition destination did not match selected tab",
            )

            let statusAttachment = XCTAttachment(string: status.label)
            statusAttachment.name = "show-tabs-placement-\(fixture)-run-\(run)"
            statusAttachment.lifetime = .keepAlways
            add(statusAttachment)
            app.terminate()
        }
    }
}

private struct ShowTabsPlacementStatusFields {
    private let values: [String: String]

    init(_ label: String) {
        values = Dictionary(
            uniqueKeysWithValues: label.split(separator: "|").compactMap { component in
                guard let separator = component.firstIndex(of: "=") else {
                    return nil
                }

                let key = String(component[..<separator])
                let value = String(component[component.index(after: separator)...])
                return (key, value)
            },
        )
    }

    func value(for key: String) -> String? {
        values[key]
    }
}
