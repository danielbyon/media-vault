import XCTest

@MainActor
final class BrowserWKDownloadSpikeUITests: XCTestCase {
    private let fixtureBase = URL(string: "http://127.0.0.1:18753")!

    func testOriginPolicyUsesFullHTTPOrigin() throws {
        XCTAssertTrue(
            WKDownloadOriginPolicy.allowsRedirect(
                from: URL(string: "https://Example.test/path")!,
                to: URL(string: "https://example.test:443/next")!,
                initial: URL(string: "https://example.test/start")!
            )
        )
        XCTAssertFalse(
            WKDownloadOriginPolicy.allowsRedirect(
                from: URL(string: "https://example.test./path")!,
                to: URL(string: "https://EXAMPLE.test:443/next")!,
                initial: URL(string: "https://example.test/start")!
            )
        )
        XCTAssertFalse(
            WKDownloadOriginPolicy.allowsRedirect(
                from: URL(string: "https://example.test/start")!,
                to: URL(string: "https://.example.test/next")!,
                initial: URL(string: "https://example.test/start")!
            )
        )
        XCTAssertFalse(
            WKDownloadOriginPolicy.allowsRedirect(
                from: URL(string: "http://127.0.0.1:18753/start")!,
                to: URL(string: "http://localhost:18753/next")!,
                initial: URL(string: "http://127.0.0.1:18753/start")!
            )
        )
        XCTAssertFalse(
            WKDownloadOriginPolicy.allowsRedirect(
                from: URL(string: "https://example.test/start")!,
                to: URL(string: "http://example.test/start")!,
                initial: URL(string: "https://example.test/start")!
            )
        )
        XCTAssertFalse(
            WKDownloadOriginPolicy.allowsRedirect(
                from: URL(string: "https://example.test/start")!,
                to: URL(string: "https://example.test:444/next")!,
                initial: URL(string: "https://example.test/start")!
            )
        )
    }

    func testRuntimeFixturesAndIndependentServerEvidence() async throws {
        let app = XCUIApplication()
        app.launchEnvironment["SPIKE_BASE_URL"] = fixtureBase.absoluteString
        app.launch()

        XCTAssertTrue(app.staticTexts["spike-state"].waitForExistence(timeout: 30))
        XCTAssertTrue(waitForLabel(app.staticTexts["spike-state"], containing: "READY", timeout: 30))

        for scenario in [
            "ordinary",
            "visible-control",
            "visible-image",
            "direct-image",
            "visible-video",
            "direct-video",
            "visible-basic",
            "attachment",
            "same-origin",
            "cross-origin",
            "https-downgrade",
            "post",
            "signed-pre-request",
            "signed-response",
            "http-cookie",
            "separate-store",
            "basic-auth",
            "secure-cookie",
            "visible-secure-cookie",
            "secure-cookie-http-negative",
            "blob",
            "cancel-resume",
            "profile-switch",
            "ephemeral-cookie",
            "ephemeral-destroy",
        ] {
            try startScenario(app, scenario: scenario)
            XCTAssertTrue(
                waitForScenarioCompletion(app, scenario: scenario, timeout: 35),
                "scenario did not report a terminal result: \(scenario)"
            )
        }

        try await Task.sleep(for: .seconds(1))
        let evidence = try await fetchEvidence()
        XCTAssertTrue(evidence.requests.contains { $0.path == "/normal" })
        XCTAssertTrue(evidence.requests.contains { $0.path == "/control/attachment" })
        XCTAssertTrue(evidence.requests.contains { $0.path == "/resource/attachment" })
        XCTAssertTrue(evidence.requests.contains { $0.path == "/control/direct-image" })
        XCTAssertTrue(evidence.requests.contains { $0.path == "/resource/direct-image" })
        XCTAssertTrue(evidence.requests.contains { $0.path == "/control/direct-video" })
        XCTAssertTrue(evidence.requests.contains { $0.path == "/resource/direct-video" })
        XCTAssertTrue(evidence.requests.contains { $0.path == "/resource/same-origin-final" })
        XCTAssertTrue(evidence.requests.contains { $0.path == "/redirect/same-origin-hop-2" })
        XCTAssertFalse(evidence.requests.contains { $0.path == "/prohibited/cross-origin" })
        XCTAssertFalse(evidence.requests.contains { $0.path == "/prohibited/https-downgrade" })
        XCTAssertEqual(evidence.requests.filter { $0.path == "/post" }.count, 1)
        XCTAssertTrue(evidence.requests.contains { $0.path == "/signed/pre-request" && $0.status == 200 })
        XCTAssertTrue(evidence.requests.contains { $0.path == "/signed/response-triggered" && $0.status == 200 })
        XCTAssertTrue(evidence.requests.contains { $0.path == "/signed/response-triggered" && $0.status == 403 })
        XCTAssertTrue(evidence.requests.contains {
            $0.path == "/cookie/resource" && $0.status == 401 && !$0.cookieNames.contains("spike_http_only")
        })
        XCTAssertFalse(evidence.requests.contains {
            $0.path == "/cookie/resource" && $0.cookieNames.contains("spike_http_only")
        })
        XCTAssertTrue(evidence.requests.contains { $0.path == "/basic/resource" && $0.authorizationScheme == "Basic" })
        XCTAssertTrue(evidence.requests.contains { $0.path == "/basic/resource" && $0.status == 200 })
        XCTAssertTrue(evidence.requests.contains { $0.path == "/basic/resource" && $0.status == 401 })
        XCTAssertTrue(evidence.requests.contains { $0.path == "/secure/resource" && $0.cookieNames.contains("spike_secure") })
        XCTAssertTrue(evidence.requests.contains { $0.path == "/secure/resource" && $0.status == 401 && !$0.cookieNames.contains("spike_secure") })
        XCTAssertEqual(evidence.postSideEffectCount, 1)

        let visibleControl = try XCTUnwrap(evidence.requests.first { $0.path == "/control/attachment" })
        let companionControl = try XCTUnwrap(evidence.requests.first { $0.path == "/resource/attachment" })
        XCTAssertEqual(visibleControl.method, companionControl.method)
        XCTAssertEqual(visibleControl.bodyLength, companionControl.bodyLength)
        XCTAssertEqual(visibleControl.bodySHA256, companionControl.bodySHA256)
        XCTAssertEqual(visibleControl.refererSanitized, companionControl.refererSanitized)
        XCTAssertEqual(visibleControl.originSanitized, companionControl.originSanitized)
        XCTAssertEqual(visibleControl.userAgentSHA256, companionControl.userAgentSHA256)
        XCTAssertEqual(visibleControl.authorizationScheme, companionControl.authorizationScheme)
        XCTAssertEqual(visibleControl.responseSHA256, companionControl.responseSHA256)
        XCTAssertTrue(visibleControl.cookieNames.contains("spike_http_only"))
        XCTAssertFalse(companionControl.cookieNames.contains("spike_http_only"))

        for scenario in ["visible-control", "visible-image", "visible-video"] {
            let selection = try XCTUnwrap(evidence.appEvents.first {
                $0.kind == "scenario-selected" && $0.fields["scenario"] == scenario
            })
            let response = try XCTUnwrap(evidence.appEvents.first {
                $0.kind == "visible-webpage-control-response-observed" && $0.operationID == selection.operationID
            })
            XCTAssertEqual(response.fields["webpage_response_policy"], "download")
            XCTAssertEqual(response.fields["webpage_file_lifecycle_available"], "false")
            XCTAssertFalse(evidence.appEvents.contains {
                $0.kind == "download-complete" && $0.operationID == selection.operationID
            })
        }

        for (scenario, controlPath, companionPath, contentType) in [
            ("direct-image", "/control/direct-image", "/resource/direct-image", "image/jpeg"),
            ("direct-video", "/control/direct-video", "/resource/direct-video", "video/mp4")
        ] {
            let visibleMedia = try XCTUnwrap(evidence.requests.first { $0.path == controlPath })
            let companionMedia = try XCTUnwrap(evidence.requests.first { $0.path == companionPath })
            XCTAssertEqual(visibleMedia.method, "GET")
            XCTAssertEqual(companionMedia.method, "GET")
            XCTAssertEqual(visibleMedia.responseContentType, contentType)
            XCTAssertEqual(companionMedia.responseContentType, contentType)
            XCTAssertEqual(visibleMedia.responseBytes, companionMedia.responseBytes)
            XCTAssertEqual(visibleMedia.responseSHA256, companionMedia.responseSHA256)

            let selection = try XCTUnwrap(evidence.appEvents.first {
                $0.kind == "scenario-selected" && $0.fields["scenario"] == scenario
            })
            let completion = try XCTUnwrap(evidence.appEvents.first {
                $0.kind == "download-complete" && $0.operationID == selection.operationID
            })
            XCTAssertEqual(completion.fields["file_exists"], "true")
            XCTAssertEqual(completion.fields["verified_receipt_published"], "true")
            XCTAssertEqual(completion.fields["byte_count"], String(companionMedia.responseBytes))
            XCTAssertEqual(completion.fields["sha256"], companionMedia.responseSHA256)
        }

        let visiblePost = try XCTUnwrap(evidence.requests.first { $0.path == "/post" })
        XCTAssertEqual(visiblePost.method, "POST")
        XCTAssertEqual(visiblePost.bodyLength, 0)
        XCTAssertEqual(visiblePost.postSideEffectCount, 1)
        let observedPostAction = try XCTUnwrap(evidence.appEvents.first {
            $0.kind == "webpage-action-observed" && $0.fields["scenario"] == "post"
        })
        XCTAssertEqual(observedPostAction.fields["method"], "POST")
        XCTAssertEqual(observedPostAction.fields["body_available"], "true")
        XCTAssertGreaterThan(Int(observedPostAction.fields["body_length"] ?? "0") ?? 0, 0)
        XCTAssertNotEqual(observedPostAction.fields["body_sha256"], visiblePost.bodySHA256)
        XCTAssertEqual(observedPostAction.fields["request_preserved_without_reconstruction"], "true")
        XCTAssertEqual(evidence.requests.filter { $0.path == "/post" }.count, 1)

        let httpCookieSelection = try XCTUnwrap(evidence.appEvents.first {
            $0.kind == "scenario-selected" && $0.fields["scenario"] == "http-cookie"
        })
        let httpCookieLookup = try XCTUnwrap(evidence.appEvents.first {
            $0.kind == "companion-cookie-lookup" && $0.operationID == httpCookieSelection.operationID
        })
        XCTAssertTrue(httpCookieLookup.fields["http_only_cookie_names"]?.contains("spike_http_only") == true)
        XCTAssertEqual(httpCookieLookup.fields["store_is_originating_page_store"], "true")

        let separateStoreSelection = try XCTUnwrap(evidence.appEvents.first {
            $0.kind == "scenario-selected" && $0.fields["scenario"] == "separate-store"
        })
        let separateStoreLookup = try XCTUnwrap(evidence.appEvents.first {
            $0.kind == "companion-cookie-lookup" && $0.operationID == separateStoreSelection.operationID
        })
        XCTAssertEqual(separateStoreLookup.fields["store_is_originating_page_store"], "false")

        let capturedAttachment = try XCTUnwrap(evidence.appEvents.first {
            $0.kind == "request-captured" && $0.fields["scenario"] == "attachment"
        })
        let completedAttachment = try XCTUnwrap(evidence.appEvents.first {
            $0.kind == "download-complete" && $0.operationID == capturedAttachment.operationID
        })
        let serverAttachment = try XCTUnwrap(evidence.requests.first { $0.path == "/resource/attachment" })
        XCTAssertEqual(completedAttachment.fields["sha256"], serverAttachment.responseSHA256)
        XCTAssertTrue(evidence.appEvents.contains {
            $0.kind == "companion-created"
                && $0.operationID == capturedAttachment.operationID
                && $0.fields["exact_store_instance"] == "true"
                && $0.fields["companion_attached_to_window"] == "false"
        })
        XCTAssertTrue(evidence.appEvents.contains {
            $0.kind == "download-progress" && $0.fields["source"] == "WKDownload.progress"
        })
        XCTAssertTrue(evidence.appEvents.contains {
            $0.kind == "redirect-decision" && $0.fields["allowed"] == "true" && $0.fields["reason"] == "allowed"
        })
        XCTAssertGreaterThanOrEqual(
            evidence.appEvents.filter { $0.kind == "redirect-decision" && $0.fields["allowed"] == "true" }.count,
            2
        )
        XCTAssertTrue(evidence.appEvents.contains {
            $0.kind == "redirect-decision" && $0.fields["allowed"] == "false" && $0.fields["reason"] == "cross-origin"
        })
        XCTAssertTrue(evidence.appEvents.contains {
            $0.kind == "redirect-decision" && $0.fields["allowed"] == "false" && $0.fields["reason"] == "https-downgrade"
        })

        let switched = try XCTUnwrap(evidence.appEvents.first { $0.kind == "active-profile-switched-during-download" })
        let originalProfileID = switched.profileID
        XCTAssertNotEqual(switched.fields["active_profile_id_after_switch"], originalProfileID)
        XCTAssertEqual(switched.fields["underlying_session_destroyed"], "false")
        let switchedRequest = try XCTUnwrap(evidence.appEvents.first {
            $0.kind == "request-captured" && $0.operationID == switched.operationID
        })
        let switchedCompletion = try XCTUnwrap(evidence.appEvents.first {
            $0.kind == "download-complete" && $0.operationID == switched.operationID
        })
        XCTAssertEqual(switchedRequest.profileID, originalProfileID)
        XCTAssertEqual(switchedCompletion.profileID, originalProfileID)
        XCTAssertEqual(switchedCompletion.fields["scratch_profile_id"], originalProfileID)
        XCTAssertEqual(switchedCompletion.fields["scratch_operation_id"], switched.operationID)
        let switchedEvents = evidence.appEvents.filter { $0.operationID == switched.operationID }
        for callback in switchedEvents where [
            "companion-created",
            "request-captured",
            "download-started",
            "download-progress",
            "download-destination-selected",
            "download-complete",
            "download-operation-reconciled"
        ].contains(callback.kind) {
            XCTAssertEqual(callback.profileID, originalProfileID, "profile switched during callback \(callback.kind)")
        }

        let ephemeralSelection = try XCTUnwrap(evidence.appEvents.first {
            $0.kind == "scenario-selected" && $0.fields["scenario"] == "ephemeral-cookie"
        })
        XCTAssertEqual(ephemeralSelection.profile, "ephemeral")
        XCTAssertTrue(evidence.appEvents.contains {
            $0.kind == "companion-created"
                && $0.operationID == ephemeralSelection.operationID
                && $0.profileID == ephemeralSelection.profileID
                && $0.fields["exact_store_instance"] == "true"
        })
        let ephemeralLookup = try XCTUnwrap(evidence.appEvents.first {
            $0.kind == "companion-cookie-lookup" && $0.operationID == ephemeralSelection.operationID
        })
        XCTAssertTrue(ephemeralLookup.fields["http_only_cookie_names"]?.contains("spike_http_only") == true)
        XCTAssertEqual(ephemeralLookup.fields["store_is_originating_page_store"], "true")

        let secureCookieSelection = try XCTUnwrap(evidence.appEvents.first {
            $0.kind == "scenario-selected" && $0.fields["scenario"] == "secure-cookie"
        })
        let secureCookieLookup = try XCTUnwrap(evidence.appEvents.first {
            $0.kind == "companion-cookie-lookup" && $0.operationID == secureCookieSelection.operationID
        })
        XCTAssertTrue(secureCookieLookup.fields["secure_cookie_names"]?.contains("spike_secure") == true)
        XCTAssertEqual(secureCookieLookup.fields["store_is_originating_page_store"], "true")
        let destroyed = try XCTUnwrap(evidence.appEvents.first { $0.kind == "ephemeral-store-destroyed" })
        XCTAssertEqual(destroyed.fields["profile_identity_changed"], "true")
        XCTAssertEqual(destroyed.fields["replacement_cookie_count"], "0")
        XCTAssertNotEqual(destroyed.fields["old_store_id"], destroyed.fields["replacement_store_id"])

        let cancelResumeSelection = try XCTUnwrap(evidence.appEvents.first {
            $0.kind == "scenario-selected" && $0.fields["scenario"] == "cancel-resume"
        })
        let cancellation = try XCTUnwrap(evidence.appEvents.first {
            $0.kind == "download-cancellation" && $0.operationID == cancelResumeSelection.operationID
        })
        let resumeData = try XCTUnwrap(evidence.appEvents.first {
            $0.kind == "resume-data-observed" && $0.operationID == cancellation.operationID
        })
        if resumeData.fields["available"] == "true" {
            let resumed = try XCTUnwrap(evidence.appEvents.first {
                $0.kind == "download-resumed" && $0.fields["parent_operation_id"] == cancellation.operationID
            })
            XCTAssertNotEqual(resumed.operationID, cancellation.operationID)
            let resumedProgress = evidence.appEvents.compactMap { event -> Double? in
                guard event.kind == "download-progress", event.operationID == resumed.operationID else { return nil }
                return event.fields["fraction_completed"].flatMap(Double.init)
            }.max() ?? 0
            XCTAssertGreaterThanOrEqual(resumedProgress, 1)
            let resumedCompletion = evidence.appEvents.first {
                $0.kind == "download-complete" && $0.operationID == resumed.operationID
            }
            let fullPayloadHash = try XCTUnwrap(evidence.transferEvents.first {
                $0.path == "/resource/slow-cancel"
            }?.expectedFullSHA256)
            let completedServerTransfers = evidence.transferEvents.filter {
                $0.path == "/resource/slow-cancel" && $0.bodyComplete
            }
            XCTAssertFalse(completedServerTransfers.isEmpty)
            for transfer in completedServerTransfers {
                XCTAssertEqual(transfer.expectedFullSHA256, fullPayloadHash)
                XCTAssertGreaterThanOrEqual(transfer.expectedFullBytes, transfer.expectedBytes)
                if transfer.expectedBytes == transfer.expectedFullBytes {
                    XCTAssertEqual(transfer.responseSHA256, fullPayloadHash)
                } else {
                    XCTAssertNotEqual(transfer.responseSHA256, fullPayloadHash)
                }
            }
            if let resumedCompletion {
                XCTAssertEqual(resumedCompletion.fields["sha256"], fullPayloadHash)
                XCTAssertEqual(resumedCompletion.fields["byte_count"], String(completedServerTransfers.last?.expectedFullBytes ?? 0))
            } else {
                XCTAssertFalse(evidence.appEvents.contains {
                    $0.kind == "download-destination-selected" && $0.operationID == resumed.operationID
                })
                let resumeFailure = try XCTUnwrap(evidence.appEvents.first {
                    $0.kind == "download-failed-final" && $0.operationID == resumed.operationID
                })
                XCTAssertEqual(resumeFailure.fields["reason"], "finish-callback-without-complete-file")
                XCTAssertEqual(resumeFailure.fields["incomplete_receipt_published"], "false")
            }
        } else {
            XCTAssertFalse(evidence.appEvents.contains { $0.kind == "download-resumed" })
        }

        try writeEvidence(evidence)
        app.terminate()
    }

    func testEphemeralTeardownCancelsOnlyRetiringProfileDownloads() async throws {
        let app = XCUIApplication()
        app.launchEnvironment["SPIKE_BASE_URL"] = fixtureBase.absoluteString
        app.launch()
        XCTAssertTrue(app.staticTexts["spike-state"].waitForExistence(timeout: 30))
        XCTAssertTrue(waitForLabel(app.staticTexts["spike-state"], containing: "READY", timeout: 30))

        try startScenario(app, scenario: "ephemeral-active-teardown")
        XCTAssertTrue(waitForLabel(app.staticTexts["scenario-status"], containing: "ephemeral-active-teardown: started", timeout: 10))
        var evidence = try await waitForEvidence(timeout: 15) { current in
            guard let selected = current.appEvents.first(where: {
                $0.kind == "scenario-selected" && $0.fields["scenario"] == "ephemeral-active-teardown"
            }) else { return false }
            return current.requests.contains { $0.path == "/resource/slow-ephemeral-teardown" }
                && current.appEvents.contains { $0.kind == "download-progress" && $0.operationID == selected.operationID }
        }
        let retiringSelection = try XCTUnwrap(evidence.appEvents.first {
            $0.kind == "scenario-selected" && $0.fields["scenario"] == "ephemeral-active-teardown"
        })
        let retiringStore = try XCTUnwrap(evidence.appEvents.first {
            $0.kind == "companion-created" && $0.operationID == retiringSelection.operationID
        }.flatMap { $0.fields["website_data_store_id"] })

        try startScenario(app, scenario: "persistent-survivor-teardown")
        XCTAssertTrue(waitForLabel(app.staticTexts["scenario-status"], containing: "persistent-survivor-teardown: started", timeout: 10))
        evidence = try await waitForEvidence(timeout: 10) { current in
            guard let selected = current.appEvents.first(where: {
                $0.kind == "scenario-selected" && $0.fields["scenario"] == "persistent-survivor-teardown"
            }) else { return false }
            return current.requests.contains { $0.path == "/resource/slow-persistent-survivor" }
                && current.appEvents.contains { $0.kind == "download-progress" && $0.operationID == selected.operationID }
        }
        let survivorSelection = try XCTUnwrap(evidence.appEvents.first {
            $0.kind == "scenario-selected" && $0.fields["scenario"] == "persistent-survivor-teardown"
        })
        let survivorStore = try XCTUnwrap(evidence.appEvents.first {
            $0.kind == "companion-created" && $0.operationID == survivorSelection.operationID
        }.flatMap { $0.fields["website_data_store_id"] })
        XCTAssertNotEqual(retiringStore, survivorStore)

        let retireButton = app.buttons["destroy-ephemeral-store"]
        XCTAssertTrue(retireButton.waitForExistence(timeout: 5))
        retireButton.tap()
        XCTAssertTrue(waitForLabel(app.staticTexts["scenario-status"], containing: "ephemeral-destroy: complete", timeout: 15))

        evidence = try await waitForEvidence(timeout: 20) { current in
            current.transferEvents.contains { $0.path == "/resource/slow-ephemeral-teardown" }
                && current.transferEvents.contains { $0.path == "/resource/slow-persistent-survivor" && $0.bodyComplete }
                && current.appEvents.contains {
                    $0.kind == "download-complete" && $0.operationID == survivorSelection.operationID
                }
                && current.appEvents.contains { $0.kind == "ephemeral-store-destroyed" }
        }
        let cancellation = try XCTUnwrap(evidence.appEvents.first {
            $0.kind == "download-cancellation-reconciled" && $0.operationID == retiringSelection.operationID
        })
        let destroyed = try XCTUnwrap(evidence.appEvents.first { $0.kind == "ephemeral-store-destroyed" })
        let retiredTransfer = try XCTUnwrap(evidence.transferEvents.first {
            $0.path == "/resource/slow-ephemeral-teardown"
        })
        XCTAssertFalse(retiredTransfer.bodyComplete)
        XCTAssertGreaterThan(retiredTransfer.bytesSent, 0)
        XCTAssertLessThan(retiredTransfer.bytesSent, retiredTransfer.expectedBytes)
        XCTAssertLessThan(retiredTransfer.timestamp, destroyed.timestamp)
        XCTAssertLessThan(cancellation.timestamp, destroyed.timestamp)
        XCTAssertEqual(destroyed.fields["teardown_reconciled"], "true")
        XCTAssertEqual(destroyed.fields["retired_profile_id"], retiringSelection.profileID)
        XCTAssertEqual(destroyed.fields["old_store_id"], retiringStore)
        XCTAssertNotEqual(destroyed.fields["old_store_id"], destroyed.fields["replacement_store_id"])
        XCTAssertEqual(destroyed.fields["replacement_cookie_count"], "0")
        XCTAssertTrue(destroyed.fields["unrelated_operation_ids_preserved"]?.contains(survivorSelection.operationID) == true)
        XCTAssertFalse(evidence.appEvents.contains {
            $0.kind == "download-complete" && $0.operationID == retiringSelection.operationID
        })
        XCTAssertFalse(evidence.appEvents.contains {
            $0.kind == "download-complete" && $0.operationID == retiringSelection.operationID
                && $0.fields["verified_receipt_published"] == "true"
        })

        let retiredCallbacks = evidence.appEvents.filter {
            $0.operationID == retiringSelection.operationID && $0.kind.hasPrefix("download-")
        }
        XCTAssertTrue(retiredCallbacks.contains { $0.kind == "download-destination-selected" })
        XCTAssertTrue(retiredCallbacks.contains { $0.kind == "download-progress" })
        XCTAssertTrue(retiredCallbacks.contains { $0.kind == "download-operation-reconciled" })
        for callback in retiredCallbacks {
            XCTAssertEqual(callback.profileID, retiringSelection.profileID, callback.kind)
            XCTAssertEqual(callback.fields["website_data_store_id"], retiringStore, callback.kind)
            XCTAssertEqual(callback.fields["scenario_run_id"], retiringSelection.fields["scenario_run_id"], callback.kind)
            XCTAssertEqual(callback.fields["scratch_profile_id"], retiringSelection.profileID, callback.kind)
            XCTAssertEqual(callback.fields["scratch_operation_id"], retiringSelection.operationID, callback.kind)
        }

        let survivorTransfer = try XCTUnwrap(evidence.transferEvents.first {
            $0.path == "/resource/slow-persistent-survivor"
        })
        let survivorCompletion = try XCTUnwrap(evidence.appEvents.first {
            $0.kind == "download-complete" && $0.operationID == survivorSelection.operationID
        })
        XCTAssertTrue(survivorTransfer.bodyComplete)
        XCTAssertGreaterThan(survivorTransfer.timestamp, destroyed.timestamp)
        XCTAssertEqual(survivorCompletion.profileID, survivorSelection.profileID)
        XCTAssertEqual(survivorCompletion.fields["website_data_store_id"], survivorStore)
        XCTAssertEqual(survivorCompletion.fields["scratch_profile_id"], survivorSelection.profileID)
        XCTAssertFalse(evidence.appEvents.contains {
            $0.kind == "download-cancellation-reconciled" && $0.operationID == survivorSelection.operationID
        })
        let survivorCallbacks = evidence.appEvents.filter {
            $0.operationID == survivorSelection.operationID && $0.kind.hasPrefix("download-")
        }
        XCTAssertTrue(survivorCallbacks.contains { $0.kind == "download-operation-reconciled" })
        for callback in survivorCallbacks {
            XCTAssertEqual(callback.profileID, survivorSelection.profileID, callback.kind)
            XCTAssertEqual(callback.fields["website_data_store_id"], survivorStore, callback.kind)
            XCTAssertEqual(callback.fields["scenario_run_id"], survivorSelection.fields["scenario_run_id"], callback.kind)
            XCTAssertEqual(callback.fields["scratch_profile_id"], survivorSelection.profileID, callback.kind)
            XCTAssertEqual(callback.fields["scratch_operation_id"], survivorSelection.operationID, callback.kind)
        }
        XCTAssertEqual(app.staticTexts["scenario-status"].label, "ephemeral-destroy: complete")
        try writeEvidence(evidence)
        app.terminate()
    }

    func testLateTerminalOutcomeCannotChangeNewerScenarioStatus() async throws {
        let app = XCUIApplication()
        app.launchEnvironment["SPIKE_BASE_URL"] = fixtureBase.absoluteString
        app.launchArguments = ["--enable-spike-regression-controls"]
        app.launch()
        XCTAssertTrue(app.staticTexts["spike-state"].waitForExistence(timeout: 30))
        XCTAssertTrue(waitForLabel(app.staticTexts["spike-state"], containing: "READY", timeout: 30))

        try startScenario(app, scenario: "late-callback-probe")
        XCTAssertTrue(waitForLabel(app.staticTexts["scenario-status"], containing: "late-callback-probe: blocked-timeout-cancelled", timeout: 10))
        var evidence = try await waitForEvidence(timeout: 15) { current in
            current.transferEvents.contains { $0.path == "/resource/slow-late-callback" && !$0.bodyComplete }
                && current.appEvents.contains { $0.kind == "download-cancellation-reconciled" }
        }
        let oldSelection = try XCTUnwrap(evidence.appEvents.first {
            $0.kind == "scenario-selected" && $0.fields["scenario"] == "late-callback-probe"
        })
        let oldTransfer = try XCTUnwrap(evidence.transferEvents.first {
            $0.path == "/resource/slow-late-callback"
        })

        try startScenario(app, scenario: "ordinary")
        XCTAssertTrue(waitForScenarioCompletion(app, scenario: "ordinary", timeout: 10))
        let statusBeforeReplay = app.staticTexts["scenario-status"].label
        XCTAssertTrue(statusBeforeReplay.hasPrefix("ordinary:"), statusBeforeReplay)
        let newerSelectionEvidence = try await waitForEvidence(timeout: 10) { current in
            current.requests.contains { $0.path == "/normal" }
                && current.appEvents.contains { $0.kind == "scenario-selected" && $0.fields["scenario"] == "ordinary" }
        }
        let newerSelection = try XCTUnwrap(newerSelectionEvidence.appEvents.first {
            $0.kind == "scenario-selected" && $0.fields["scenario"] == "ordinary"
        })

        let replay = app.buttons["replay-previous-terminal-outcome"]
        XCTAssertTrue(replay.waitForExistence(timeout: 5))
        replay.tap()
        evidence = try await waitForEvidence(timeout: 10) { current in
            current.appEvents.contains {
                $0.kind == "stale-scenario-terminal-ignored"
                    && $0.fields["source"] == "regression-replay"
                    && $0.operationID == oldSelection.operationID
            }
        }
        let ignored = try XCTUnwrap(evidence.appEvents.first {
            $0.kind == "stale-scenario-terminal-ignored"
                && $0.fields["source"] == "regression-replay"
                && $0.operationID == oldSelection.operationID
        })
        XCTAssertGreaterThan(ignored.timestamp, newerSelection.timestamp)
        XCTAssertLessThan(oldTransfer.timestamp, ignored.timestamp)
        XCTAssertEqual(ignored.fields["outcome_scenario_run_id"], oldSelection.fields["scenario_run_id"])
        XCTAssertEqual(ignored.fields["current_scenario_run_id"], newerSelection.fields["scenario_run_id"])
        XCTAssertEqual(ignored.fields["current_status_operation_id"], newerSelection.operationID)
        XCTAssertEqual(ignored.fields["scenario_status_before"], statusBeforeReplay)
        XCTAssertEqual(ignored.fields["scenario_status_after"], statusBeforeReplay)
        XCTAssertEqual(app.staticTexts["scenario-status"].label, statusBeforeReplay)
        try writeEvidence(evidence)
        app.terminate()
    }

    func testBackgroundAndHarnessTerminationAreRecordedSeparately() async throws {
        let app = XCUIApplication()
        app.launchEnvironment["SPIKE_BASE_URL"] = fixtureBase.absoluteString
        app.launch()
        XCTAssertTrue(app.staticTexts["spike-state"].waitForExistence(timeout: 30))
        XCTAssertTrue(waitForLabel(app.staticTexts["spike-state"], containing: "READY", timeout: 30))

        try startScenario(app, scenario: "background-transfer")
        try await Task.sleep(for: .milliseconds(400))
        XCUIDevice.shared.press(.home)
        try await Task.sleep(for: .seconds(4))
        app.activate()
        XCTAssertTrue(app.staticTexts["spike-state"].waitForExistence(timeout: 15))

        try startScenario(app, scenario: "termination-transfer")
        try await Task.sleep(for: .milliseconds(400))
        try await postHarnessMarker("harness-termination-requested")
        app.terminate()
        try await postHarnessMarker("harness-termination-observed")
        let firstLaunchCount = try await fetchEvidence().appEvents.filter { $0.kind == "app-launched" }.count
        app.launch()
        XCTAssertTrue(app.staticTexts["spike-state"].waitForExistence(timeout: 30))
        XCTAssertTrue(waitForLabel(app.staticTexts["spike-state"], containing: "READY", timeout: 30))
        try await postHarnessMarker("explicit-relaunch-observed")
        let evidence = try await fetchEvidence()
        XCTAssertGreaterThanOrEqual(evidence.appEvents.filter { $0.kind == "app-launched" }.count, firstLaunchCount + 1)
        XCTAssertTrue(evidence.appEvents.contains { $0.kind == "scene-phase" && $0.fields["phase"] == "background" })
        XCTAssertTrue(evidence.appEvents.contains { $0.kind == "harness-termination-requested" })
        XCTAssertTrue(evidence.appEvents.contains { $0.kind == "harness-termination-observed" })
        XCTAssertTrue(evidence.appEvents.contains { $0.kind == "explicit-relaunch-observed" })

        let backgroundRequest = try XCTUnwrap(evidence.appEvents.first {
            $0.kind == "request-captured" && $0.fields["scenario"] == "background-transfer"
        })
        let backgroundStart = try XCTUnwrap(evidence.appEvents.first {
            $0.kind == "scene-phase" && $0.fields["phase"] == "background"
        })
        let resumedForeground = try XCTUnwrap(evidence.appEvents.first {
            $0.kind == "scene-phase"
                && $0.fields["phase"] == "active"
                && $0.timestamp > backgroundStart.timestamp
        })
        let backgroundCompletion = try XCTUnwrap(evidence.appEvents.first {
            $0.kind == "download-complete" && $0.operationID == backgroundRequest.operationID
        })
        XCTAssertGreaterThan(backgroundCompletion.timestamp, backgroundStart.timestamp)
        XCTAssertLessThan(backgroundCompletion.timestamp, resumedForeground.timestamp)
        let fixtureBackgroundTransfer = try XCTUnwrap(evidence.transferEvents.first {
            $0.path == "/resource/slow-background"
        })
        XCTAssertTrue(fixtureBackgroundTransfer.bodyComplete)
        XCTAssertGreaterThan(fixtureBackgroundTransfer.timestamp, backgroundStart.timestamp)
        XCTAssertLessThan(fixtureBackgroundTransfer.timestamp, resumedForeground.timestamp)

        let terminationRequest = try XCTUnwrap(evidence.appEvents.first {
            $0.kind == "request-captured" && $0.fields["scenario"] == "termination-transfer"
        })
        let terminatedTransfer = try XCTUnwrap(evidence.transferEvents.first {
            $0.path == "/resource/slow-termination"
        })
        XCTAssertFalse(terminatedTransfer.bodyComplete)
        XCTAssertGreaterThan(terminatedTransfer.bytesSent, 0)
        XCTAssertLessThan(terminatedTransfer.bytesSent, terminatedTransfer.expectedBytes)
        XCTAssertFalse(evidence.appEvents.contains {
            $0.kind == "download-complete" && $0.operationID == terminationRequest.operationID
        })
        let processIDs = Set(evidence.appEvents.filter { $0.kind == "app-launched" }.compactMap { $0.fields["process_id"] })
        XCTAssertGreaterThanOrEqual(processIDs.count, 2)
        try writeEvidence(evidence)
        app.terminate()
    }

    private func waitForLabel(_ element: XCUIElement, containing text: String, timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate(format: "label CONTAINS %@", text)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    private func startScenario(_ app: XCUIApplication, scenario: String) throws {
        let list = app.scrollViews.matching(identifier: "scenario-list").firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: 10), "missing scenario list")
        let option = app.buttons.matching(identifier: "scenario.\(scenario)").firstMatch
        for _ in 0..<20 where !option.isHittable {
            list.swipeUp()
        }
        XCTAssertTrue(option.exists, "missing scenario option: \(scenario)")
        option.tap()
    }

    private func waitForScenarioCompletion(
        _ app: XCUIApplication,
        scenario: String,
        timeout: TimeInterval
    ) -> Bool {
        let element = app.staticTexts["scenario-status"]
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let value = element.label
            if value.hasPrefix("\(scenario):") && (value.contains("complete") || value.contains("blocked") || value.contains("failed")) {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        }
        return false
    }

    private func fetchEvidence() async throws -> FixtureEvidence {
        let url = fixtureBase.appending(path: "/__spike/evidence")
        let (data, response) = try await URLSession.shared.data(from: url)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        return try JSONDecoder().decode(FixtureEvidence.self, from: data)
    }

    private func waitForEvidence(
        timeout: TimeInterval,
        until predicate: (FixtureEvidence) -> Bool
    ) async throws -> FixtureEvidence {
        let deadline = Date().addingTimeInterval(timeout)
        var evidence = try await fetchEvidence()
        while Date() < deadline, !predicate(evidence) {
            try await Task.sleep(for: .milliseconds(100))
            evidence = try await fetchEvidence()
        }
        XCTAssertTrue(predicate(evidence), "fixture evidence did not reach the expected server-observed state")
        return evidence
    }

    private func postHarnessMarker(_ kind: String) async throws {
        let url = fixtureBase.appending(path: "/__spike/event")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "kind": kind,
            "timestamp": Date().timeIntervalSince1970,
            "profile_id": "xctest-process",
            "profile": "xctest",
            "operation_id": UUID().uuidString,
            "fields": ["actor": "XCUITest", "host_process_claimed": "false"]
        ])
        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 204)
    }

    private func writeEvidence(_ evidence: FixtureEvidence) throws {
        guard let directory = ProcessInfo.processInfo.environment["SPIKE_EVIDENCE_DIRECTORY"] else { return }
        let root = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(evidence)
        try data.write(to: root.appending(path: "fixture-evidence.json"), options: .atomic)
    }
}

private struct FixtureEvidence: Decodable, Encodable {
    let requests: [FixtureRequest]
    let appEvents: [FixtureAppEvent]
    let transferEvents: [FixtureTransferEvent]
    let postSideEffectCount: Int

    enum CodingKeys: String, CodingKey {
        case requests
        case appEvents = "app_events"
        case transferEvents = "transfer_events"
        case postSideEffectCount = "post_side_effect_count"
    }
}

private struct FixtureRequest: Decodable, Encodable {
    let requestID: Int
    let timestamp: Double
    let host: String
    let path: String
    let method: String
    let status: Int
    let bodyLength: Int
    let bodySHA256: String
    let responseBytes: Int
    let responseSHA256: String
    let responseContentType: String
    let cookieNames: [String]
    let refererPresent: Bool
    let refererSanitized: String
    let originPresent: Bool
    let originSanitized: String
    let userAgentSHA256: String
    let authorizationScheme: String?
    let postSideEffectCount: Int?

    enum CodingKeys: String, CodingKey {
        case requestID = "request_id"
        case timestamp
        case host
        case path
        case method
        case status
        case bodyLength = "body_length"
        case bodySHA256 = "body_sha256"
        case responseBytes = "response_bytes"
        case responseSHA256 = "response_sha256"
        case responseContentType = "response_content_type"
        case cookieNames = "cookie_names"
        case refererPresent = "referer_present"
        case refererSanitized = "referer_sanitized"
        case originPresent = "origin_present"
        case originSanitized = "origin_sanitized"
        case userAgentSHA256 = "user_agent_sha256"
        case authorizationScheme = "authorization_scheme"
        case postSideEffectCount = "post_side_effect_count"
    }
}

private struct FixtureAppEvent: Decodable, Encodable {
    let kind: String
    let timestamp: Double
    let profileID: String
    let profile: String
    let operationID: String
    let fields: [String: String]

    enum CodingKeys: String, CodingKey {
        case kind
        case timestamp
        case profileID = "profile_id"
        case profile
        case operationID = "operation_id"
        case fields
    }
}

private struct FixtureTransferEvent: Decodable, Encodable {
    let kind: String
    let requestID: Int
    let timestamp: Double
    let path: String
    let bytesSent: Int
    let expectedBytes: Int
    let expectedFullBytes: Int
    let expectedFullSHA256: String
    let responseSHA256: String
    let bodyComplete: Bool

    enum CodingKeys: String, CodingKey {
        case kind
        case requestID = "request_id"
        case timestamp
        case path
        case bytesSent = "bytes_sent"
        case expectedBytes = "expected_bytes"
        case expectedFullBytes = "expected_full_bytes"
        case expectedFullSHA256 = "expected_full_sha256"
        case responseSHA256 = "response_sha256"
        case bodyComplete = "body_complete"
    }
}
