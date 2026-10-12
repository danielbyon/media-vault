//
//  BridgePayloadTests.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import XCTest
@testable import BridgePayload

final class BridgePayloadTests: XCTestCase {
    private let mainFrame = NativeMessageMetadata(
        contentWorld: .defaultClient,
        isMainFrame: true,
        securityOrigin: "http://127.0.0.1:18755",
        requestURL: URL(string: "http://127.0.0.1:18755/case/linked-image"),
    )

    func testLinkedImageKeepsMediaSeparateFromEnclosingLink() {
        let payload = fixtureBody(
            currentSrc: "http://127.0.0.1:18755/media/selected.jpg",
            src: "/media/fallback.jpg",
            linkHref: "http://127.0.0.1:18755/destination",
        )

        let result = BridgeMessageDecoder.decode(payload, native: mainFrame, activeCaseID: "linked-image")
        guard case let .accepted(observation) = result else {
            XCTFail("A trusted linked image should decode")
            return
        }

        XCTAssertEqual(observation.mediaURL?.path, "/media/selected.jpg")
        XCTAssertEqual(observation.linkURL?.path, "/destination")
        XCTAssertNotEqual(observation.mediaURL, observation.linkURL)
        XCTAssertEqual(observation.tagName, "IMG")
        XCTAssertEqual(observation.native.securityOrigin, "http://127.0.0.1:18755")
        XCTAssertEqual(observation.pageFrameOrigin, "http://127.0.0.1:18755")
    }

    func testRelativeSourceUsesTrustedFrameRequestAsFallbackBase() {
        let payload = fixtureBody(currentSrc: nil, src: "../media/selected.jpg", linkHref: nil)
        let result = BridgeMessageDecoder.decode(payload, native: mainFrame, activeCaseID: "linked-image")
        guard case let .accepted(observation) = result else {
            XCTFail("A relative source should decode")
            return
        }

        XCTAssertEqual(observation.mediaURL?.absoluteString, "http://127.0.0.1:18755/media/selected.jpg")
    }

    func testOpaqueDataSourceNeverRetainsEncodedBytes() {
        let payload = fixtureBody(currentSrc: "data:", src: nil, linkHref: nil)
        let result = BridgeMessageDecoder.decode(payload, native: mainFrame, activeCaseID: "linked-image")
        guard case let .accepted(observation) = result else {
            XCTFail("A redacted opaque source should decode")
            return
        }

        XCTAssertNil(observation.mediaURL)
        XCTAssertEqual(observation.mediaScheme, "data")
    }

    func testOpaqueBlobSourceNeverBecomesTransferURL() {
        let result = BridgeMessageDecoder.decode(
            fixtureBody(currentSrc: "blob:", src: nil, linkHref: nil),
            native: mainFrame,
            activeCaseID: "linked-image",
        )
        guard case let .accepted(observation) = result else {
            XCTFail("A redacted blob marker should remain observable")
            return
        }

        XCTAssertNil(observation.mediaURL)
        XCTAssertEqual(observation.mediaScheme, "blob")
    }

    func testSyntheticContextMenuEventIsRejected() {
        var payload = fixtureBody(currentSrc: "/media/selected.jpg", src: nil, linkHref: nil)
        payload["isTrusted"] = false
        XCTAssertEqual(
            BridgeMessageDecoder.decode(payload, native: mainFrame, activeCaseID: "linked-image"),
            .rejected("synthetic-event"),
        )
    }

    func testPageWorldMessageIsRejected() {
        let pageFrame = NativeMessageMetadata(
            contentWorld: .page,
            isMainFrame: true,
            securityOrigin: mainFrame.securityOrigin,
            requestURL: mainFrame.requestURL,
        )
        XCTAssertEqual(
            BridgeMessageDecoder.decode(
                fixtureBody(currentSrc: "/media/selected.jpg", src: nil, linkHref: nil),
                native: pageFrame,
                activeCaseID: "linked-image",
            ),
            .rejected("wrong-content-world"),
        )
    }

    func testRetiredOrMismatchedPageMessageIsRejected() {
        let payload = fixtureBody(currentSrc: "/media/selected.jpg", src: nil, linkHref: nil)
        XCTAssertEqual(
            BridgeMessageDecoder.decode(payload, native: mainFrame, activeCaseID: nil),
            .rejected("stale-navigation"),
        )
        XCTAssertEqual(
            BridgeMessageDecoder.decode(payload, native: mainFrame, activeCaseID: "unlinked-image"),
            .rejected("stale-navigation"),
        )
    }

    func testMatchingPathOnUntrustedOriginIsRejected() {
        let untrustedFrame = NativeMessageMetadata(
            contentWorld: .defaultClient,
            isMainFrame: true,
            securityOrigin: "https://attacker.example",
            requestURL: URL(string: "https://attacker.example/case/linked-image"),
        )

        XCTAssertEqual(
            BridgeMessageDecoder.decode(
                fixtureBody(currentSrc: "/media/selected.jpg", src: nil, linkHref: nil),
                native: untrustedFrame,
                activeCaseID: "linked-image",
            ),
            .rejected("stale-navigation"),
        )
    }

    func testMissingNativeFrameRequestCannotAuthenticateNavigation() {
        let missingRequest = NativeMessageMetadata(
            contentWorld: .defaultClient,
            isMainFrame: true,
            securityOrigin: mainFrame.securityOrigin,
            requestURL: nil,
        )
        XCTAssertEqual(
            BridgeMessageDecoder.decode(
                fixtureBody(currentSrc: "/media/selected.jpg", src: nil, linkHref: nil),
                native: missingRequest,
                activeCaseID: "linked-image",
            ),
            .rejected("native-frame-request-unavailable"),
        )
    }

    func testMalformedAndOversizedMessagesAreRejected() {
        XCTAssertEqual(
            BridgeMessageDecoder.decode(["eventType": "contextmenu"], native: mainFrame, activeCaseID: "linked-image"),
            .rejected("malformed-message"),
        )
        let oversized = fixtureBody(currentSrc: String(repeating: "x", count: 4_097), src: nil, linkHref: nil)
        XCTAssertEqual(
            BridgeMessageDecoder.decode(oversized, native: mainFrame, activeCaseID: "linked-image"),
            .rejected("malformed-message"),
        )
        var oversizedCase = fixtureBody(currentSrc: nil, src: nil, linkHref: nil)
        oversizedCase["caseID"] = String(repeating: "x", count: 81)
        XCTAssertEqual(
            BridgeMessageDecoder.decode(oversizedCase, native: mainFrame, activeCaseID: "linked-image"),
            .rejected("malformed-message"),
        )
    }

    func testDiagnosticPointerObservationCannotIdentifyResource() {
        var payload = fixtureBody(currentSrc: nil, src: nil, linkHref: nil)
        payload["eventType"] = "pointerdown"
        let result = BridgeMessageDecoder.decode(payload, native: mainFrame, activeCaseID: "linked-image")
        guard case let .accepted(observation) = result else {
            XCTFail("A trusted diagnostic pointer event should decode")
            return
        }

        XCTAssertEqual(observation.eventType, .pointerdown)
        XCTAssertNil(observation.mediaURL)
        XCTAssertNil(observation.linkURL)

        payload["src"] = "/media/forged.jpg"
        XCTAssertEqual(
            BridgeMessageDecoder.decode(payload, native: mainFrame, activeCaseID: "linked-image"),
            .rejected("malformed-message"),
        )
    }

    func testUnsupportedOrCredentialBearingSourceCannotBecomeMediaURL() {
        for source in ["file:///secret", "http://user:password@127.0.0.1/media/image.jpg"] {
            let result = BridgeMessageDecoder.decode(
                fixtureBody(currentSrc: source, src: nil, linkHref: nil),
                native: mainFrame,
                activeCaseID: "linked-image",
            )
            guard case let .accepted(observation) = result else {
                XCTFail("The event should remain observable")
                return
            }

            XCTAssertNil(observation.mediaURL)
        }
    }

    func testNonMediaElementCannotClaimAnImmediateSource() {
        var payload = fixtureBody(currentSrc: nil, src: "/media/image.jpg", linkHref: nil)
        payload["tagName"] = "CANVAS"
        XCTAssertEqual(
            BridgeMessageDecoder.decode(payload, native: mainFrame, activeCaseID: "linked-image"),
            .rejected("malformed-message"),
        )
    }

    func testCrossOriginFrameRetainsNativeAndPageOriginsSeparately() {
        let frame = NativeMessageMetadata(
            contentWorld: .defaultClient,
            isMainFrame: false,
            securityOrigin: "http://localhost:18755",
            requestURL: URL(string: "http://localhost:18755/frame/cross-origin"),
        )
        var payload = fixtureBody(currentSrc: "/media/selected.jpg", src: nil, linkHref: nil)
        payload["caseID"] = "cross-origin"
        payload["frameOrigin"] = "http://forged.invalid"
        let result = BridgeMessageDecoder.decode(payload, native: frame, activeCaseID: "cross-origin")
        guard case let .accepted(observation) = result else {
            XCTFail("The frame report should remain observable")
            return
        }

        XCTAssertEqual(observation.native.securityOrigin, "http://localhost:18755")
        XCTAssertEqual(observation.pageFrameOrigin, "http://forged.invalid")
        XCTAssertEqual(observation.mediaURL?.host, "localhost")
    }

    private func fixtureBody(currentSrc: String?, src: String?, linkHref: String?) -> [String: Any] {
        [
            "eventType": "contextmenu",
            "isTrusted": true,
            "caseID": "linked-image",
            "tagName": "IMG",
            "currentSrc": currentSrc as Any? ?? NSNull(),
            "src": src as Any? ?? NSNull(),
            "linkHref": linkHref as Any? ?? NSNull(),
            "frameURL": "http://127.0.0.1:18755/case/linked-image",
            "frameOrigin": "http://127.0.0.1:18755",
        ]
    }
}
