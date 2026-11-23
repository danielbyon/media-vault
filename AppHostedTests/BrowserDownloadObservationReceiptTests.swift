//
//  BrowserDownloadObservationReceiptTests.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

// swiftformat:options --test-case-name-format preserve

import Foundation
import Testing

extension AppHostedUITests {
    @MainActor
    @Suite("Passive browser download qualification")
    struct BrowserDownloadObservationReceiptTests {}
}

extension AppHostedUITests.BrowserDownloadObservationReceiptTests {
    @Test("Completed attachment proof follows one new policy, handoff, and writer in the same context")
    func completedAttachmentRequiresFreshCorrelatedHandoff() {
        let context = BrowserDownloadObservationContext(
            processNonce: UUID(),
            runID: UUID().uuidString,
            authorizationGeneration: 2,
            resourceGeneration: 3,
            ingestionGeneration: 4,
            phase: "authenticated",
        )
        let base: [String: String] = [
            "event": "loopbackReady",
            "runID": context.runID,
            "monotonicSeconds": "0",
        ]
        let requestID = UUID().uuidString
        let operationID = UUID().uuidString
        let capability = UUID().uuidString
        func attachmentEvents(handoffRequestID: String, proofOperationID: String) -> [[String: String]] {
            [
                [
                    "event": "fixtureNavigationRequested",
                    "runID": context.runID,
                    "fixtureRoute": "attachment",
                    "fixtureRequest": requestID,
                    "monotonicSeconds": "1",
                ],
                [
                    "event": "policyDownloadAdmitted",
                    "runID": context.runID,
                    "operation": operationID,
                    "capability": capability,
                    "monotonicSeconds": "1.5",
                ],
                [
                    "event": "nativeDownloadHandoff",
                    "operation": operationID,
                    "runID": context.runID,
                    "fixtureRoute": "attachment",
                    "fixtureRequest": handoffRequestID,
                    "fixtureOrigin": "true",
                    "sameOrigin": "true",
                    "monotonicSeconds": "2",
                ],
                [
                    "event": "transferAdmitted",
                    "runID": context.runID,
                    "capability": capability,
                    "operation": operationID,
                    "monotonicSeconds": "3",
                ],
                [
                    "event": "writerFinished",
                    "runID": context.runID,
                    "operation": operationID,
                    "monotonicSeconds": "4",
                ],
                [
                    "event": "completedFileProof",
                    "runID": context.runID,
                    "operation": proofOperationID,
                    "processNonce": context.processNonce.uuidString,
                    "generation": String(context.authorizationGeneration),
                    "authorizationGeneration": String(context.authorizationGeneration),
                    "resourceGeneration": String(context.resourceGeneration),
                    "ingestionGeneration": String(context.ingestionGeneration),
                    "phase": context.phase,
                    "phaseRevision": String(context.phaseRevision),
                    "ready": "true",
                    "monotonicSeconds": "5",
                ],
            ]
        }

        let baseline = BrowserDownloadPassiveObservation(context: context, events: [base])
        let validEvents = attachmentEvents(handoffRequestID: requestID, proofOperationID: operationID)
        let valid = BrowserDownloadPassiveObservation(context: context, events: [base] + validEvents)
        #expect(valid.completedAttachment(after: baseline) != nil)

        let wrongCapability = validEvents.map { event in
            event["event"] == "transferAdmitted" ? event.merging(["capability": UUID().uuidString]) { $1 } : event
        }
        #expect(BrowserDownloadPassiveObservation(context: context, events: [base] + wrongCapability)
            .completedAttachment(after: baseline) == nil)

        let oldBaseline = BrowserDownloadPassiveObservation(context: context, events: [base] + validEvents)
        #expect(oldBaseline.completedAttachment(after: oldBaseline) == nil)

        let unrelatedRequest = BrowserDownloadPassiveObservation(
            context: context,
            events: [base] + attachmentEvents(handoffRequestID: UUID().uuidString, proofOperationID: operationID),
        )
        #expect(unrelatedRequest.completedAttachment(after: baseline) == nil)

        let unrelatedOperation = BrowserDownloadPassiveObservation(
            context: context,
            events: [base] + attachmentEvents(handoffRequestID: requestID, proofOperationID: UUID().uuidString),
        )
        #expect(unrelatedOperation.completedAttachment(after: baseline) == nil)

        let changedAuthorization = BrowserDownloadObservationContext(
            processNonce: context.processNonce,
            runID: context.runID,
            authorizationGeneration: context.authorizationGeneration + 1,
            resourceGeneration: context.resourceGeneration,
            ingestionGeneration: context.ingestionGeneration,
            phase: context.phase,
        )
        let staleAuthorization = BrowserDownloadPassiveObservation(
            context: changedAuthorization,
            events: [base] + validEvents,
        )
        #expect(staleAuthorization.completedAttachment(after: baseline) == nil)
    }

    @Test("Completed-file proof survives unrelated event rollover and still requires milestones")
    func completedAttachmentSurvivesIrrelevantPrefixRollover() {
        let context = BrowserDownloadObservationContext(
            processNonce: UUID(),
            runID: UUID().uuidString,
            authorizationGeneration: 2,
            resourceGeneration: 3,
            ingestionGeneration: 4,
            phase: "authenticated",
        )
        let prefixEvents: [[String: String]] = (0 ..< 256).map { index in
            [
                "event": index == 0 ? "loopbackReady" : "testDiagnosticNoise",
                "runID": context.runID,
                "monotonicSeconds": String(index),
            ]
        }
        let baseline = BrowserDownloadPassiveObservation(context: context, events: prefixEvents)
        let requestID = UUID().uuidString
        let operationID = UUID().uuidString
        let capabilityID = UUID().uuidString
        let milestones: [[String: String]] = [
            [
                "event": "fixtureNavigationRequested",
                "runID": context.runID,
                "fixtureRoute": "attachment",
                "fixtureRequest": requestID,
                "monotonicSeconds": "256",
            ],
            [
                "event": "policyDownloadAdmitted",
                "runID": context.runID,
                "operation": operationID,
                "capability": capabilityID,
                "monotonicSeconds": "257",
            ],
            [
                "event": "nativeDownloadHandoff",
                "runID": context.runID,
                "operation": operationID,
                "fixtureRoute": "attachment",
                "fixtureRequest": requestID,
                "fixtureOrigin": "true",
                "sameOrigin": "true",
                "monotonicSeconds": "258",
            ],
            [
                "event": "transferAdmitted",
                "runID": context.runID,
                "operation": operationID,
                "capability": capabilityID,
                "monotonicSeconds": "259",
            ],
            [
                "event": "writerFinished",
                "runID": context.runID,
                "operation": operationID,
                "monotonicSeconds": "260",
            ],
            [
                "event": "completedFileProof",
                "runID": context.runID,
                "operation": operationID,
                "processNonce": context.processNonce.uuidString,
                "generation": String(context.authorizationGeneration),
                "authorizationGeneration": String(context.authorizationGeneration),
                "resourceGeneration": String(context.resourceGeneration),
                "ingestionGeneration": String(context.ingestionGeneration),
                "phaseRevision": String(context.phaseRevision),
                "phase": context.phase,
                "ready": "true",
                "monotonicSeconds": "261",
            ],
        ]
        let retainedPrefix = Array(prefixEvents.dropFirst(milestones.count))
        func rolledObservation(_ evidence: [[String: String]], pad: Bool = false) -> BrowserDownloadPassiveObservation {
            var events = retainedPrefix + evidence
            if pad {
                events.append([
                    "event": "testDiagnosticNoise",
                    "runID": context.runID,
                    "monotonicSeconds": "262",
                ])
            }

            return BrowserDownloadPassiveObservation(
                context: context,
                events: events,
                discardedEventCount: milestones.count,
            )
        }

        let complete = rolledObservation(milestones)
        #expect(complete.events.count == baseline.events.count)
        #expect(complete.discardedEventCount != baseline.discardedEventCount)
        #expect(!complete.truncated)
        #expect(Array(complete.events.prefix(baseline.events.count)) != baseline.events)
        #expect(milestones.map { $0["event"] } == [
            "fixtureNavigationRequested",
            "policyDownloadAdmitted",
            "nativeDownloadHandoff",
            "transferAdmitted",
            "writerFinished",
            "completedFileProof",
        ])
        #expect(milestones[0]["fixtureRequest"] == milestones[2]["fixtureRequest"])
        #expect(milestones[1]["operation"] == milestones[2]["operation"])
        #expect(milestones[1]["operation"] == milestones[3]["operation"])
        #expect(milestones[1]["capability"] == milestones[3]["capability"])
        #expect(milestones[1]["operation"] == milestones[4]["operation"])
        let proof = complete.completedAttachment(after: baseline)
        #expect(proof?["operation"] == operationID)
        #expect(proof?["ready"] == "true")

        let missingPolicy = rolledObservation(milestones.filter { $0["event"] != "policyDownloadAdmitted" }, pad: true)
        #expect(missingPolicy.completedAttachment(after: baseline) == nil)

        let evictedFinish = rolledObservation(milestones.filter { $0["event"] != "writerFinished" }, pad: true)
        #expect(evictedFinish.completedAttachment(after: baseline) == nil)
    }

    @Test("Passive event values scope the current run and redact file proofs while locked")
    func passiveObservationScopesAndRedactsLockedFileProofs() {
        let context = BrowserDownloadObservationContext(
            processNonce: UUID(),
            runID: UUID().uuidString,
            authorizationGeneration: 4,
            resourceGeneration: 5,
            ingestionGeneration: 6,
            phase: "locked",
        )
        let operation = UUID().uuidString
        let proof: [String: String] = [
            "event": "completedFileProof",
            "runID": context.runID,
            "operation": operation,
            "allocation": "private-allocation",
            "bytes": "608",
            "sha256": "private-hash",
        ]
        let finished: [String: String] = [
            "event": "writerFinished",
            "runID": context.runID,
            "operation": operation,
            "authenticated": "false",
        ]
        let hidden: [String: String] = [
            "event": "hiddenCompletion",
            "runID": context.runID,
            "operation": operation,
            "activeWriterCount": "0",
            "retainedRecordCount": "1",
            "authenticated": "false",
            "available": "false",
            "contentEmpty": "true",
        ]
        let previousRun: [String: String] = [
            "event": "writerFinished",
            "runID": UUID().uuidString,
            "operation": UUID().uuidString,
        ]

        let value = BrowserDownloadPassiveObservation(context: context, events: [proof, finished, hidden, previousRun])

        #expect(value.events.map { $0["event"] } == ["writerFinished", "hiddenCompletion"])
        #expect(value.events[0] == finished)
        #expect(value.events[1]["noActiveWriters"] == "true")
        #expect(value.events[1]["oneRetainedCompletion"] == "true")
        #expect(value.events[1]["activeWriterCount"] == nil)
        #expect(value.events[1]["retainedRecordCount"] == nil)
        #expect(value.events[0]["allocation"] == nil)
        #expect(value.events[0]["bytes"] == nil)
        #expect(value.events[0]["sha256"] == nil)
    }

    @Test("Authenticated passive values retain the current completed-file proof")
    func authenticatedPassiveObservationKeepsCompletedFileProof() {
        let context = BrowserDownloadObservationContext(
            processNonce: UUID(),
            runID: UUID().uuidString,
            authorizationGeneration: 4,
            resourceGeneration: 5,
            ingestionGeneration: 6,
            phase: "authenticated",
        )
        let proof: [String: String] = [
            "event": "completedFileProof",
            "runID": context.runID,
            "operation": UUID().uuidString,
            "processNonce": context.processNonce.uuidString,
            "authorizationGeneration": String(context.authorizationGeneration),
            "resourceGeneration": String(context.resourceGeneration),
            "ingestionGeneration": String(context.ingestionGeneration),
            "phase": context.phase,
            "phaseRevision": String(context.phaseRevision),
            "ready": "true",
            "bytes": "608",
            "sha256": "fixture-hash",
        ]

        let value = BrowserDownloadPassiveObservation(context: context, events: [proof])

        #expect(value.events == [proof])
    }

    @Test("Passive event decoding rejects oversized and unscoped histories")
    func passiveDecodingRejectsIncompleteHistory() throws {
        let context = BrowserDownloadObservationContext(
            processNonce: UUID(),
            runID: UUID().uuidString,
            authorizationGeneration: 1,
            resourceGeneration: 1,
            ingestionGeneration: 1,
            phase: "authenticated",
        )
        let event = ["event": "loopbackReady", "runID": context.runID]
        let oversized = BrowserDownloadPassiveObservation(
            context: context,
            events: Array(repeating: event, count: BrowserDownloadPassiveObservation.maximumEventCount + 1),
        )
        let oversizedWire = try String(decoding: JSONEncoder().encode(oversized), as: UTF8.self)
        #expect(throws: BrowserDownloadObservationError.malformed) {
            try BrowserDownloadPassiveObservation.decode(oversizedWire)
        }

        let unscoped = BrowserDownloadPassiveObservation(context: context, events: [[
            "event": "loopbackReady",
            "runID": UUID().uuidString,
        ]])
        let unscopedWire = try String(decoding: JSONEncoder().encode(unscoped), as: UTF8.self)
        #expect(throws: BrowserDownloadObservationError.malformed) {
            try BrowserDownloadPassiveObservation.decode(unscopedWire)
        }
    }
}

@MainActor
extension AppHostedUITests.BrowserDownloadObservationReceiptTests {
    @Test("Host diagnostic history stays bounded and marks discarded records")
    func hostDiagnosticHistoryIsBounded() throws {
        let recorder = BrowserDownloadHostDiagnosticRecorder()
        let sceneLabel = recorder.makeSceneLabel()
        let maximum = BrowserDownloadHostDiagnostics.maximumRecordCount

        for _ in 0 ..< (maximum + 3) {
            recorder.recordScenePhase(.background, sceneLabel: sceneLabel)
        }

        let diagnostics = recorder.snapshot
        let encoded = try JSONEncoder().encode(diagnostics)
        let json = String(decoding: encoded, as: UTF8.self)

        #expect(diagnostics.records.count == maximum)
        #expect(diagnostics.truncated)
        #expect(diagnostics.records.first?.ordinal == 4)
        #expect(diagnostics.records.last?.ordinal == UInt32(maximum + 3))
        #expect(encoded.count <= BrowserDownloadHostDiagnostics.maximumEncodedByteCount)
        #expect(json.contains(sceneLabel))
        #expect(!json.contains("persistentIdentifier"))
    }

    @Test("Host diagnostic byte limits trim history and mark truncation")
    func hostDiagnosticByteLimitTruncatesHistory() throws {
        var diagnostics = BrowserDownloadHostDiagnostics()

        for ordinal in 1 ... BrowserDownloadHostDiagnostics.maximumRecordCount {
            diagnostics.append(.init(
                ordinal: UInt32(ordinal),
                event: .libraryReadEligibilityChanged,
                sceneLabel: "scene-1234567890",
                activeScene: false,
                storageAvailable: false,
                rootPhase: .authenticated,
                rootEligible: true,
                readEligible: true,
                scenePhase: .background,
                outcome: .invalidated,
            ))
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let encoded = try encoder.encode(diagnostics)

        #expect(encoded.count <= BrowserDownloadHostDiagnostics.maximumEncodedByteCount)
        #expect(diagnostics.records.count <= BrowserDownloadHostDiagnostics.maximumRecordCount)
        #expect(diagnostics.truncated)
        #expect(diagnostics.records.count < BrowserDownloadHostDiagnostics.maximumRecordCount)
    }

    @Test("Bounded host diagnostics retain current read correlation after trimming")
    func hostDiagnosticHistoryRetainsCurrentReadCorrelation() throws {
        let payload = Data(
            #"""
            {
              "truncated": true,
              "records": [
                {
                  "ordinal": 70,
                  "event": "libraryReadOutcome",
                  "sceneLabel": "scene-4",
                  "outcome": "invalidated",
                  "readSequence": 12,
                  "contextMatches": false
                }
              ],
              "currentRead": {
                "sequence": 12,
                "sceneLabel": "scene-4",
                "status": "invalidated",
                "contextMatches": false
              }
            }
            """#.utf8,
        )
        let diagnostics = try JSONDecoder().decode(BrowserDownloadHostDiagnostics.self, from: payload)
        let encoded = try JSONEncoder().encode(diagnostics)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let currentRead = try #require(object["currentRead"] as? [String: Any])
        let records = try #require(object["records"] as? [[String: Any]])
        let outcome = try #require(records.first)

        #expect(currentRead["sequence"] as? Int == 12)
        #expect(currentRead["status"] as? String == "invalidated")
        #expect(currentRead["contextMatches"] as? Bool == false)
        #expect(outcome["readSequence"] as? Int == currentRead["sequence"] as? Int)
        #expect(outcome["contextMatches"] as? Bool == false)
        #expect(diagnostics.truncated)
    }

    @Test("Trimmed host history keeps the active read ticket and outcome")
    func hostDiagnosticHistoryKeepsCurrentReadAfterTrimming() throws {
        let recorder = BrowserDownloadHostDiagnosticRecorder()
        let ticket = recorder.scheduleLibraryRead(sceneLabel: "scene-1")
        for index in 0 ..< BrowserDownloadHostDiagnostics.maximumRecordCount + 4 {
            recorder.recordScenePhase(index.isMultiple(of: 2) ? .active : .background, sceneLabel: "scene-1")
        }
        recorder.recordReadOutcome(.complete, for: ticket, contextMatches: true)

        let diagnostics = recorder.snapshot
        let encoded = try JSONEncoder().encode(diagnostics)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let currentRead = try #require(object["currentRead"] as? [String: Any])
        let records = try #require(object["records"] as? [[String: Any]])
        let outcome = try #require(records.last { $0["event"] as? String == "libraryReadOutcome" })

        #expect(diagnostics.truncated)
        #expect(!records.contains { $0["event"] as? String == "libraryReadScheduled" })
        #expect(currentRead["sequence"] as? Int == 1)
        #expect(currentRead["status"] as? String == "complete")
        #expect(currentRead["contextMatches"] as? Bool == true)
        #expect(outcome["readSequence"] as? Int == currentRead["sequence"] as? Int)
        #expect(encoded.count <= BrowserDownloadHostDiagnostics.maximumEncodedByteCount)
    }

    @Test("Host diagnostic recorder retains active, storage, and root eligibility transitions")
    func hostDiagnosticRecorderRecordsEligibilityTransitions() {
        let recorder = BrowserDownloadHostDiagnosticRecorder()
        recorder.recordEligibility(
            sceneLabel: "scene-1",
            activeScene: false,
            storageAvailable: false,
            rootPhase: .locked,
            readEligible: false,
        )
        recorder.recordEligibility(
            sceneLabel: "scene-1",
            activeScene: true,
            storageAvailable: false,
            rootPhase: .locked,
            readEligible: false,
        )
        recorder.recordEligibility(
            sceneLabel: "scene-1",
            activeScene: true,
            storageAvailable: true,
            rootPhase: .locked,
            readEligible: true,
        )
        recorder.recordEligibility(
            sceneLabel: "scene-1",
            activeScene: true,
            storageAvailable: true,
            rootPhase: .authenticated,
            readEligible: true,
        )

        let transitions = recorder.snapshot.records.filter { $0.event == .libraryReadEligibilityChanged }

        #expect(transitions.count == 4)
        #expect(transitions.map { $0.activeScene ?? false } == [false, true, true, true])
        #expect(transitions.map { $0.storageAvailable ?? false } == [false, false, true, true])
        #expect(transitions.map(\.rootPhase) == [.locked, .locked, .locked, .authenticated])
        #expect(transitions.map { $0.readEligible ?? false } == [false, false, true, true])
    }

    @Test("Eligibility deduplication is scoped to each scene and the process")
    func hostDiagnosticEligibilityTransitionsUseIndependentScopes() {
        let recorder = BrowserDownloadHostDiagnosticRecorder()
        func record(_ sceneLabel: String?) {
            recorder.recordEligibility(
                sceneLabel: sceneLabel,
                activeScene: true,
                storageAvailable: true,
                rootPhase: .locked,
                readEligible: true,
            )
        }

        record("scene-1")
        record("scene-2")
        record("scene-1")
        record(nil)
        record(nil)

        let transitions = recorder.snapshot.records.filter { $0.event == .libraryReadEligibilityChanged }
        #expect(transitions.count == 3)
        #expect(transitions.map(\.sceneLabel) == ["scene-1", "scene-2", nil])
    }
}

@MainActor
extension AppHostedUITests.BrowserDownloadObservationReceiptTests {
    @Test("Completed Library reads are not reported as cancelled")
    func hostDiagnosticCompletedReadIsNotReportedAsCancelled() {
        let recorder = BrowserDownloadHostDiagnosticRecorder()
        recorder.recordRead(.libraryReadScheduled, sceneLabel: "scene-1")
        recorder.recordRead(.libraryReadOutcome, sceneLabel: "scene-2", outcome: .complete)
        recorder.recordRead(.libraryReadCancelled, sceneLabel: "scene-2")

        let readRecords = recorder.snapshot.records.filter {
            [.libraryReadScheduled, .libraryReadCancelled, .libraryReadOutcome].contains($0.event)
        }

        #expect(readRecords.map(\.event) == [.libraryReadScheduled, .libraryReadOutcome])
        #expect(readRecords.last?.sceneLabel == "scene-1")
    }

    @Test("Library read invalidation stays attributed to its scheduling scene")
    func hostDiagnosticReadInvalidationUsesSchedulingScene() {
        let recorder = BrowserDownloadHostDiagnosticRecorder()
        recorder.recordRead(.libraryReadScheduled, sceneLabel: "scene-1")
        recorder.recordRead(.contextInvalidated, sceneLabel: "scene-2", outcome: .invalidated)
        recorder.recordRead(.libraryReadOutcome, sceneLabel: "scene-2", outcome: .invalidated)

        let invalidation = recorder.snapshot.records.first { $0.event == .contextInvalidated }
        let outcome = recorder.snapshot.records.first { $0.event == .libraryReadOutcome }

        #expect(invalidation?.sceneLabel == "scene-1")
        #expect(outcome?.sceneLabel == "scene-1")
    }

    @Test("Read completion and invalidation carry context equality")
    func hostDiagnosticReadOutcomesCarryContextEquality() {
        let recorder = BrowserDownloadHostDiagnosticRecorder()
        let ticket = recorder.scheduleLibraryRead(sceneLabel: "scene-1")
        recorder.recordContextInvalidated(for: ticket, contextMatches: false)
        recorder.recordReadOutcome(.invalidated, for: ticket, contextMatches: false)

        let invalidation = recorder.snapshot.records.first { $0.event == .contextInvalidated }
        let outcome = recorder.snapshot.records.first { $0.event == .libraryReadOutcome }

        #expect(invalidation?.readSequence == 1)
        #expect(invalidation?.contextMatches == false)
        #expect(outcome?.readSequence == 1)
        #expect(outcome?.contextMatches == false)
        #expect(recorder.snapshot.currentRead?.contextMatches == false)
    }

    @Test("Late invalidation from a cancelled read cannot clear a newer read")
    func hostDiagnosticLateReadOutcomePreservesNewActiveRead() {
        let recorder = BrowserDownloadHostDiagnosticRecorder()
        let first = recorder.scheduleLibraryRead(sceneLabel: "scene-1")
        recorder.cancelActiveLibraryRead()
        _ = recorder.scheduleLibraryRead(sceneLabel: "scene-2")

        recorder.recordContextInvalidated(for: first)
        recorder.recordReadOutcome(.invalidated, for: first)
        recorder.cancelActiveLibraryRead()

        let records = recorder.snapshot.records.filter {
            [.libraryReadScheduled, .libraryReadCancelled, .contextInvalidated, .libraryReadOutcome]
                .contains($0.event)
        }

        #expect(records.map(\.event) == [
            .libraryReadScheduled,
            .libraryReadCancelled,
            .libraryReadScheduled,
            .contextInvalidated,
            .libraryReadOutcome,
            .libraryReadCancelled,
        ])
        #expect(records[3].sceneLabel == "scene-1")
        #expect(records[4].sceneLabel == "scene-1")
        #expect(records[5].sceneLabel == "scene-2")
    }
}

extension AppHostedUITests.BrowserDownloadObservationReceiptTests {
    @Test("Native lifecycle proofs require primary count fields, with consistent aliases")
    func nativeLifecycleProofsRequirePrimaryCounts() {
        for event in ["hiddenCompletion", "qualificationScenePhaseChanged"] {
            let aliasOnly = BrowserDownloadObservationSnapshot(events: [[
                "event": event,
                "active": "1",
                "retained": "1",
            ]]).addingFixtureProofs()
            #expect(aliasOnly.events[0]["oneActiveWriter"] == nil)
            #expect(aliasOnly.events[0]["oneRetainedCompletion"] == nil)
            let primaryOnly = BrowserDownloadObservationSnapshot(events: [[
                "event": event,
                "activeWriterCount": "1",
                "retainedRecordCount": "1",
            ]]).addingFixtureProofs()
            #expect(primaryOnly.events[0]["oneActiveWriter"] == "true")
            #expect(primaryOnly.events[0]["oneRetainedCompletion"] == "true")
            for primary in [nil, "invalid", "2"] as [String?] {
                var record = ["event": event, "active": "0", "retained": "1"]
                record["activeWriterCount"] = primary
                record["retainedRecordCount"] = primary
                let result = BrowserDownloadObservationSnapshot(events: [record])
                    .addingFixtureProofs()
                #expect(result.events[0]["noActiveWriters"] != "true")
                #expect(result.events[0]["oneRetainedCompletion"] != "true")
                if primary == nil || primary == "invalid" {
                    #expect(result.events[0]["noActiveWriters"] == nil)
                    #expect(result.events[0]["oneRetainedCompletion"] == nil)
                }
            }
            for alias in ["invalid", "2"] {
                let record = [
                    "event": event,
                    "activeWriterCount": "0",
                    "active": alias,
                    "retainedRecordCount": "1",
                    "retained": alias,
                ]
                let result = BrowserDownloadObservationSnapshot(events: [record])
                    .addingFixtureProofs()
                #expect(result.events[0]["noActiveWriters"] == nil)
                #expect(result.events[0]["oneRetainedCompletion"] == nil)
            }
        }
    }
}

extension AppHostedUITests.BrowserDownloadObservationReceiptTests {
    @Test("Finite response and native progress proofs preserve exact correlated byte bounds")
    func finiteFixtureBoundsDeriveFromRawCorrelatedRecords() {
        let raw = finiteProofFixture()
        let prepared = raw.addingFixtureProofs()
        #expect(prepared.events[1]["finiteResponseBoundsValid"] == "true")
        #expect(prepared.events[2]["nativeProgressBoundsValid"] == "true")
        #expect(prepared.events[2]["progressPositive"] == "true")
        #expect(raw.events[1]["finiteResponseBoundsValid"] == nil)
        let locked = prepared.projected(for: ReaderFixture(phase: "locked").context)
        #expect(locked.events[1]["finiteResponseBoundsValid"] == "true")
        #expect(locked.events[2]["nativeProgressBoundsValid"] == "true")
        #expect(locked.events[2]["receivedBytes"] == nil)
        #expect(locked.events[1]["prefixBytes"] == nil)
    }

    @Test(
        "Correlated fixture proofs cannot join different identities",
        arguments: ["runID", "fixtureRequest", "operation", "connectionID"],
    )
    func finiteFixtureProofRejectsWrongCorrelation(key: String) {
        var records = finiteProofFixture().events
        records[0][key] = "another-identity"
        let prepared = BrowserDownloadObservationSnapshot(events: records)
            .addingFixtureProofs()
        #expect(prepared.events[1]["finiteResponseBoundsValid"] != "true")
        #expect(prepared.events[2]["nativeProgressBoundsValid"] != "true")
        records = finiteProofFixture().events
        records[2][key] = "another-identity"
        #expect(BrowserDownloadObservationSnapshot(events: records)
            .addingFixtureProofs()
            .events[2]["nativeProgressBoundsValid"] != "true")
    }

    @Test("Duplicate readiness or response records cannot establish native progress bounds")
    func finiteFixtureProofRejectsDuplicateMatches() {
        let records = finiteProofFixture().events
        let duplicateReadiness = BrowserDownloadObservationSnapshot(events: records + [records[0]])
            .addingFixtureProofs()
        #expect(duplicateReadiness.events[1]["finiteResponseBoundsValid"] != "true")
        #expect(duplicateReadiness.events[2]["nativeProgressBoundsValid"] != "true")
        let duplicateResponse = BrowserDownloadObservationSnapshot(events: records + [records[1]])
            .addingFixtureProofs()
        #expect(duplicateResponse.events[2]["nativeProgressBoundsValid"] != "true")
    }

    @Test("Wrong response math, expected strings and native progress bounds cannot pass")
    func finiteFixtureProofRejectsWrongBytes() {
        for (index, key, value) in [
            (1, "remainderBytes", "11"),
            (1, "prefixBytes", "0"),
            (1, "expectedBytes", "17"),
            (0, "expectedBytes", "016"),
            (2, "receivedBytes", "4"),
            (2, "receivedBytes", "17"),
            (2, "expectedBytes", "016"),
            (2, "expectedBytes", "17"),
        ] {
            var records = finiteProofFixture().events
            records[index][key] = value
            let prepared = BrowserDownloadObservationSnapshot(events: records)
                .addingFixtureProofs()
            #expect(prepared.events[2]["nativeProgressBoundsValid"] != "true")
            if index != 2 {
                #expect(prepared.events[1]["finiteResponseBoundsValid"] != "true")
            }
        }
    }
}

private func finiteProofFixture() -> BrowserDownloadObservationSnapshot {
    let identity = ["runID": "run", "fixtureRequest": "request", "operation": "operation", "connectionID": "connection"]
    let readiness = identity.merging(["event": "slowKnownReadiness", "expectedBytes": "16"]) { _, new in new }
    let response = identity.merging([
        "event": "finiteResponseCompleted",
        "expectedBytes": "16",
        "prefixBytes": "4",
        "remainderBytes": "12",
    ]) { _, new in new }
    let progress = identity.merging([
        "event": "nativePostLockProgress",
        "expectedBytes": "16",
        "receivedBytes": "8",
    ]) { _, new in new }
    return .init(events: [readiness, response, progress])
}

@MainActor
extension AppHostedUITests.BrowserDownloadObservationReceiptTests {
    @Test("Locked PNG timeout reports bounded proof gaps")
    func lockedPNGTimeoutReportsProofGaps() {
        let fixture = ReaderFixture()
        let baseline = BrowserDownloadPassiveObservation(
            context: fixture.context,
            events: [["runID": fixture.context.runID, "event": "baseline", "monotonicSeconds": "1"]],
        )
        let lockedContext = BrowserDownloadObservationContext(
            processNonce: UUID(),
            runID: UUID().uuidString,
            authorizationGeneration: fixture.context.authorizationGeneration,
            resourceGeneration: fixture.context.resourceGeneration,
            ingestionGeneration: fixture.context.ingestionGeneration,
            phase: "locked",
            phaseRevision: fixture.context.phaseRevision,
        )
        let sample = BrowserDownloadPassiveObservation(context: lockedContext, events: [])
        let diagnostic = BrowserDownloadWaitFailureDiagnostics.summarize(
            wait: .lockedPNG,
            sample: sample,
            baseline: baseline,
            sampleReadMissing: false,
            matcherMatched: false,
            expectedPhase: "locked",
        )

        #expect(diagnostic.reasons.contains(.missingMilestone))
        #expect(diagnostic.reasons.contains(.contextMismatch))
        #expect(diagnostic.reasons.contains(.generationMismatch))
        #expect(diagnostic.reasons.contains(.librarySampleMissing))
        #expect(diagnostic.matcherMatched == false)
    }

    @Test("Locked PNG timeout classifies non-complete Library outcomes")
    func lockedPNGTimeoutReportsNonCompleteLibraryOutcome() {
        let fixture = ReaderFixture()
        let baseline = BrowserDownloadPassiveObservation(
            context: fixture.context,
            events: [["runID": fixture.context.runID, "event": "baseline", "monotonicSeconds": "1"]],
        )
        let lockedContext = BrowserDownloadObservationContext(
            processNonce: fixture.context.processNonce,
            runID: fixture.context.runID,
            authorizationGeneration: fixture.context.authorizationGeneration + 1,
            resourceGeneration: fixture.context.resourceGeneration,
            ingestionGeneration: fixture.context.ingestionGeneration,
            phase: "locked",
            phaseRevision: fixture.context.phaseRevision + 1,
        )

        for (outcome, invalidated) in [
            (BrowserDownloadLibraryObservation.Outcome.unavailable, false),
            (.failed, false),
            (.invalidated, true),
        ] {
            let sample = BrowserDownloadPassiveObservation(
                context: lockedContext,
                events: [],
                library: .init(context: lockedContext, outcome: outcome, fields: [:]),
            )
            let diagnostic = BrowserDownloadWaitFailureDiagnostics.summarize(
                wait: .lockedPNG,
                sample: sample,
                baseline: baseline,
                sampleReadMissing: false,
                matcherMatched: false,
                expectedPhase: "locked",
            )

            #expect(diagnostic.reasons.contains(.libraryNonComplete))
            #expect(diagnostic.reasons.contains(.libraryInvalidated) == invalidated)
        }
    }

    @Test("Locked PNG timeout distinguishes conflicting order and Library proof")
    func lockedPNGTimeoutReportsConflictingOrderAndLibraryProof() {
        let fixture = ReaderFixture()
        let baseline = BrowserDownloadPassiveObservation(
            context: fixture.context,
            events: [["runID": fixture.context.runID, "event": "baseline", "monotonicSeconds": "1"]],
        )
        let operation = UUID().uuidString
        let capability = UUID().uuidString
        let request = UUID().uuidString
        let currentContext = BrowserDownloadObservationContext(
            processNonce: fixture.context.processNonce,
            runID: fixture.context.runID,
            authorizationGeneration: fixture.context.authorizationGeneration + 1,
            resourceGeneration: fixture.context.resourceGeneration,
            ingestionGeneration: fixture.context.ingestionGeneration,
            phase: "locked",
            phaseRevision: fixture.context.phaseRevision + 1,
        )
        func event(_ name: String, _ time: String, _ extra: [String: String] = [:]) -> [String: String] {
            var result = [
                "runID": currentContext.runID,
                "event": name,
                "monotonicSeconds": time,
                "fixtureRequest": request,
                "operation": operation,
                "capability": capability,
            ]
            result.merge(extra) { _, value in value }
            return result
        }
        let events = [
            event("fixtureNavigationRequested", "2", ["fixtureRoute": "image"]),
            event("policyDownloadAdmitted", "3"),
            event("automaticMediaPolicyLocked", "5"),
            event(
                "nativeDownloadHandoff",
                "4",
                ["fixtureRoute": "image", "sameOrigin": "true", "fixtureOrigin": "true"],
            ),
            event("transferAdmitted", "6"),
            event("writerFinished", "7"),
        ]
        let library = BrowserDownloadLibraryObservation(
            context: currentContext,
            outcome: .complete,
            fields: [
                "event": "libraryStartup",
                "singleStagedFixture": "false",
                "stagingEmpty": "true",
            ],
        )
        let sample = BrowserDownloadPassiveObservation(context: currentContext, events: events, library: library)
        let diagnostic = BrowserDownloadWaitFailureDiagnostics.summarize(
            wait: .lockedPNG,
            sample: sample,
            baseline: baseline,
            sampleReadMissing: false,
            matcherMatched: false,
            expectedPhase: "locked",
        )
        let duplicateSample = BrowserDownloadPassiveObservation(
            context: currentContext,
            events: events + [event("fixtureNavigationRequested", "2.5", ["fixtureRoute": "image"])],
            library: library,
        )
        let duplicateDiagnostic = BrowserDownloadWaitFailureDiagnostics.summarize(
            wait: .lockedPNG,
            sample: duplicateSample,
            baseline: baseline,
            sampleReadMissing: false,
            matcherMatched: false,
            expectedPhase: "locked",
        )

        #expect(diagnostic.reasons.contains(.milestoneOrderMismatch))
        #expect(diagnostic.reasons.contains(.acceptedStorageEventMismatch))
        #expect(diagnostic.reasons.contains(.stagingProofMismatch))
        #expect(duplicateDiagnostic.reasons.contains(.conflictingMilestones))
    }

    @Test("Missing milestone correlation is reported separately from matching Library proof")
    func lockedPNGTimeoutReportsMissingLibraryWitnessSeparately() throws {
        let fixture = ReaderFixture()
        let baselineEvent = ["runID": fixture.context.runID, "event": "baseline", "monotonicSeconds": "1"]
        let baseline = BrowserDownloadPassiveObservation(context: fixture.context, events: [baselineEvent])
        let operation = UUID().uuidString
        let capability = UUID().uuidString
        let request = UUID().uuidString
        let lockedContext = BrowserDownloadObservationContext(
            processNonce: fixture.context.processNonce,
            runID: fixture.context.runID,
            authorizationGeneration: fixture.context.authorizationGeneration + 1,
            resourceGeneration: fixture.context.resourceGeneration,
            ingestionGeneration: fixture.context.ingestionGeneration,
            phase: "locked",
            phaseRevision: fixture.context.phaseRevision + 1,
        )
        func event(_ name: String, _ time: String, _ extra: [String: String] = [:]) -> [String: String] {
            var result = [
                "runID": lockedContext.runID,
                "event": name,
                "monotonicSeconds": time,
                "fixtureRequest": request,
                "operation": operation,
                "capability": capability,
            ]
            result.merge(extra) { _, value in value }
            return result
        }
        let events = [
            baselineEvent,
            event("fixtureNavigationRequested", "2", ["fixtureRoute": "image"]),
            event("policyDownloadAdmitted", "3"),
            event("automaticMediaPolicyLocked", "4"),
            event("nativeDownloadHandoff", "5", [
                "fixtureRoute": "image",
                "sameOrigin": "true",
                "fixtureOrigin": "true",
            ]),
            event("transferAdmitted", "6"),
        ]
        let library = BrowserDownloadLibraryObservation(
            context: lockedContext,
            outcome: .complete,
            fields: [
                "event": "acceptedLibraryStorage",
                "runID": lockedContext.runID,
                "processID": "1",
                "databaseID": String(repeating: "a", count: 64),
                "libraryID": UUID().uuidString,
                "authenticated": "false",
                "singleStagedFixture": "true",
                "stagingEmpty": "false",
                "contentEmpty": "true",
                "operation": operation,
            ],
        )
        let sample = BrowserDownloadPassiveObservation(context: lockedContext, events: events, library: library)
        let diagnostic = BrowserDownloadWaitFailureDiagnostics.summarize(
            wait: .lockedPNG,
            sample: sample,
            baseline: baseline,
            sampleReadMissing: false,
            matcherMatched: false,
            expectedPhase: "locked",
        )
        let payload = try #require(JSONSerialization
            .jsonObject(with: JSONEncoder().encode(diagnostic)) as? [String: Any])
        let reasons = try #require(payload["reasons"] as? [String])

        #expect(reasons.contains("correlationWitnessMissing"))
        #expect(!reasons.contains("stagingProofMismatch"))
    }

    @Test("Failure attachment reports bounded comparison status without identifiers")
    func waitFailureAttachmentContainsSanitizedStatus() throws {
        let fixture = ReaderFixture(phase: "locked")
        let baseline = BrowserDownloadPassiveObservation(
            context: fixture.context,
            events: [["runID": fixture.context.runID, "event": "baseline", "monotonicSeconds": "1"]],
        )
        let lockedContext = BrowserDownloadObservationContext(
            processNonce: fixture.context.processNonce,
            runID: fixture.context.runID,
            authorizationGeneration: fixture.context.authorizationGeneration + 1,
            resourceGeneration: fixture.context.resourceGeneration,
            ingestionGeneration: fixture.context.ingestionGeneration,
            phase: "locked",
            phaseRevision: fixture.context.phaseRevision + 1,
        )
        let library = BrowserDownloadLibraryObservation(
            context: lockedContext,
            outcome: .complete,
            fields: [
                "event": "acceptedLibraryStorage",
                "runID": lockedContext.runID,
                "processID": "1",
                "databaseID": String(repeating: "a", count: 64),
                "libraryID": UUID().uuidString,
                "authenticated": "false",
                "singleStagedFixture": "true",
                "stagingEmpty": "false",
                "contentEmpty": "true",
                "operation": UUID().uuidString,
            ],
        )
        let sample = BrowserDownloadPassiveObservation(
            context: lockedContext,
            events: [[
                "runID": lockedContext.runID,
                "event": "fixtureNavigationRequested",
                "fixtureRoute": "image",
                "fixtureRequest": UUID().uuidString,
                "monotonicSeconds": "2",
            ]],
            library: library,
        )
        let diagnostic = BrowserDownloadWaitFailureDiagnostics.summarize(
            wait: .lockedPNG,
            sample: sample,
            baseline: baseline,
            sampleReadMissing: false,
            matcherMatched: false,
            expectedPhase: "locked",
        )
        let data = try #require(BrowserDownloadWaitFailureDiagnostics.attachmentData(
            for: .deadlineExceeded,
            diagnostic: diagnostic,
        ))
        let json = String(decoding: data, as: UTF8.self)
        let payload = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let context = try #require(payload["contextStatus"] as? [String: Any])
        let libraryStatus = try #require(payload["libraryStatus"] as? [String: Any])
        let milestones = try #require(payload["milestones"] as? [[String: Any]])

        #expect(payload["errorClass"] as? String == "deadlineExceeded")
        #expect(payload["readOutcome"] as? String == "sampleAvailable")
        #expect(context["launchMatchesExpected"] as? Bool == true)
        #expect(context["runMatchesBaseline"] as? Bool == true)
        #expect(context["authorizationGenerationMatchesBaseline"] as? Bool == false)
        #expect(context["authorizationGenerationAdvanced"] as? Bool == true)
        #expect(context["phaseRevisionAdvanced"] as? Bool == true)
        #expect(context["baselineEventPrefixStable"] as? Bool == false)
        #expect(milestones.contains { $0["milestone"] as? String == "navigation" && $0["present"] as? Bool == true })
        #expect(milestones.contains { $0["milestone"] as? String == "writerFinish" && $0["present"] as? Bool == false })
        #expect(libraryStatus["present"] as? Bool == true)
        #expect(libraryStatus["outcome"] as? String == "complete")
        #expect(libraryStatus["sampleValid"] as? Bool == true)
        #expect(libraryStatus["contextMatches"] as? Bool == true)
        #expect(libraryStatus["expectedEventMatches"] as? Bool == true)
        #expect(!json.contains(lockedContext.processNonce.uuidString))
        #expect(!json.contains(lockedContext.runID))
        #expect(!json.contains("fixtureRequest"))
        #expect(data.count <= BrowserDownloadWaitFailureDiagnostics.maximumAttachmentByteCount)
    }

    @Test("Missing sample read has its own failure outcome")
    func waitFailureAttachmentDistinguishesMissingSampleRead() throws {
        let diagnostic = BrowserDownloadWaitFailureDiagnostics.summarize(
            wait: .coldStartup,
            sample: nil,
            baseline: nil,
            sampleReadMissing: true,
            matcherMatched: nil,
            expectedPhase: "locked",
        )
        let data = try #require(BrowserDownloadWaitFailureDiagnostics.attachmentData(
            for: .missing,
            diagnostic: diagnostic,
        ))
        let payload = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(payload["errorClass"] as? String == "missing")
        #expect(payload["readOutcome"] as? String == "sampleReadMissing")
    }

    @Test("Failure diagnostics mark host history unavailable when no sample was read")
    func waitFailureAttachmentReportsUnavailableHostDiagnostics() throws {
        let diagnostic = BrowserDownloadWaitFailureDiagnostics.summarize(
            wait: .coldStartup,
            sample: nil,
            baseline: nil,
            sampleReadMissing: true,
            matcherMatched: nil,
            expectedPhase: "locked",
        )
        let data = try JSONEncoder().encode(diagnostic)
        let payload = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let reasons = try #require(payload["reasons"] as? [String])

        #expect(reasons.contains("hostDiagnosticsUnavailable"))
    }

    @Test("Stale and malformed wait failures receive safe attachments")
    func waitFailureAttachmentSupportsStaleAndMalformedErrors() throws {
        let fixture = ReaderFixture()
        let diagnostic = BrowserDownloadWaitFailureDiagnostics.summarize(
            wait: .coldStartup,
            sample: nil,
            baseline: nil,
            sampleReadMissing: false,
            matcherMatched: nil,
            expectedPhase: "locked",
            observedContext: fixture.context,
        )

        for (failure, expectedClass) in [
            (BrowserDownloadObservationError.stale, "stale"),
            (.malformed, "malformed"),
        ] {
            let data = try #require(BrowserDownloadWaitFailureDiagnostics.attachmentData(
                for: failure,
                diagnostic: diagnostic,
            ))
            let payload = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect(payload["errorClass"] as? String == expectedClass)
            #expect(payload["readOutcome"] as? String == "sampleUnavailable")
            #expect(data.count <= BrowserDownloadWaitFailureDiagnostics.maximumAttachmentByteCount)
        }
    }

    @Test("Delayed handoff timeout reports missing progress and terminal events")
    func delayedHandoffTimeoutReportsMissingProgressAndTerminalEvents() {
        let fixture = ReaderFixture(phase: "locked")
        let request = UUID().uuidString
        let sample = BrowserDownloadPassiveObservation(
            context: fixture.context,
            events: [
                [
                    "runID": fixture.context.runID,
                    "event": "fixtureNavigationRequested",
                    "fixtureRoute": "delayed-handoff",
                    "fixtureRequest": request,
                    "monotonicSeconds": "1",
                ],
                [
                    "runID": fixture.context.runID,
                    "event": "pendingPolicyLockApplied",
                    "fixtureRequest": request,
                    "monotonicSeconds": "2",
                ],
                [
                    "runID": fixture.context.runID,
                    "event": "nativeCancellationRequested",
                    "fixtureRequest": request,
                ],
                [
                    "runID": fixture.context.runID,
                    "event": "writerFailed",
                    "fixtureRequest": request,
                ],
            ],
        )
        let diagnostic = BrowserDownloadWaitFailureDiagnostics.summarize(
            wait: .delayedHandoff,
            sample: sample,
            baseline: nil,
            sampleReadMissing: false,
            matcherMatched: false,
            expectedPhase: "locked",
        )

        #expect(diagnostic.reasons.contains(.nativeHandoffMissing))
        #expect(diagnostic.reasons.contains(.postLockProgressMissing))
        #expect(diagnostic.reasons.contains(.hiddenCompletionMissing))
        #expect(diagnostic.reasons.contains(.transferIncomplete))
        #expect(diagnostic.reasons.contains(.cancellationObserved))
        #expect(diagnostic.reasons.contains(.failureObserved))
    }

    @Test("Delayed handoff timeout reports correlation and milestone order")
    func delayedHandoffTimeoutReportsCorrelationAndMilestoneOrder() {
        let fixture = ReaderFixture(phase: "locked")
        let request = UUID().uuidString
        let operation = UUID().uuidString
        let capability = UUID().uuidString
        let connection = UUID().uuidString
        func event(_ name: String, _ time: String, _ extra: [String: String] = [:]) -> [String: String] {
            var result = [
                "runID": fixture.context.runID,
                "event": name,
                "fixtureRequest": request,
                "monotonicSeconds": time,
                "operation": operation,
                "capability": capability,
                "connectionID": connection,
            ]
            result.merge(extra) { _, value in value }
            return result
        }
        let events = [
            event("fixtureNavigationRequested", "1", ["fixtureRoute": "delayed-handoff"]),
            event("policyDownloadAdmitted", "2"),
            event("pendingPolicyLockApplied", "4"),
            event("nativeDownloadHandoff", "3", ["sameOrigin": "true", "fixtureOrigin": "true"]),
            event("transferAdmitted", "5", ["connectionID": UUID().uuidString]),
            event("writerFinished", "6"),
            event("hiddenCompletion", "7"),
            event("nativePostLockProgress", "5.5", ["callbackMonotonicSeconds": "5.5"]),
        ]
        let sample = BrowserDownloadPassiveObservation(context: fixture.context, events: events)
        let diagnostic = BrowserDownloadWaitFailureDiagnostics.summarize(
            wait: .delayedHandoff,
            sample: sample,
            baseline: nil,
            sampleReadMissing: false,
            matcherMatched: false,
            expectedPhase: "locked",
        )

        #expect(diagnostic.reasons.contains(.correlationMismatch))
        #expect(diagnostic.reasons.contains(.milestoneOrderMismatch))
    }

    @Test("Delayed handoff reports each missing required milestone")
    func delayedHandoffTimeoutIdentifiesMissingMilestones() throws {
        let fixture = ReaderFixture(phase: "locked")
        let request = UUID().uuidString
        let operation = UUID().uuidString
        let capability = UUID().uuidString
        let connection = UUID().uuidString
        func event(_ name: String, _ time: String, _ extra: [String: String] = [:]) -> [String: String] {
            var result = [
                "runID": fixture.context.runID,
                "event": name,
                "fixtureRequest": request,
                "monotonicSeconds": time,
                "operation": operation,
                "capability": capability,
                "connectionID": connection,
            ]
            result.merge(extra) { _, value in value }
            return result
        }
        let events = [
            event("fixtureNavigationRequested", "1", ["fixtureRoute": "delayed-handoff"]),
            event("policyDownloadAdmitted", "2"),
            event("pendingPolicyLockApplied", "3", [
                "authenticated": "false",
                "available": "false",
                "contentEmpty": "true",
                "generationBefore": "4",
                "generation": "5",
            ]),
            event("nativeDownloadHandoff", "4", [
                "fixtureRoute": "delayed-handoff",
                "sameOrigin": "true",
                "fixtureOrigin": "true",
            ]),
            event("transferAdmitted", "5"),
            event("writerFinished", "6"),
            event("nativePostLockProgress", "5.5", [
                "callbackMonotonicSeconds": "5.4",
                "receivedBytes": "16777216",
                "expectedBytes": "16777216",
                "authenticated": "false",
                "available": "false",
            ]),
            event("hiddenCompletion", "8", [
                "contentEmpty": "true",
                "available": "false",
                "authenticated": "false",
                "activeWriterCount": "0",
                "retainedRecordCount": "1",
            ]),
        ]
        let missingMilestones = [
            ("fixtureNavigationRequested", "navigationMissing"),
            ("policyDownloadAdmitted", "policyAdmissionMissing"),
            ("pendingPolicyLockApplied", "lockMissing"),
            ("nativeDownloadHandoff", "nativeHandoffMissing"),
            ("transferAdmitted", "transferAdmissionMissing"),
            ("writerFinished", "writerFinishMissing"),
            ("nativePostLockProgress", "postLockProgressMissing"),
            ("hiddenCompletion", "hiddenCompletionMissing"),
        ]
        let completeSample = BrowserDownloadPassiveObservation(context: fixture.context, events: events)
        let completeDiagnostic = BrowserDownloadWaitFailureDiagnostics.summarize(
            wait: .delayedHandoff,
            sample: completeSample,
            baseline: nil,
            sampleReadMissing: false,
            matcherMatched: false,
            expectedPhase: "locked",
        )
        let completePayload = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(completeDiagnostic)) as? [String: Any],
        )
        let completeMilestones = try #require(completePayload["milestones"] as? [[String: Any]])

        for milestone in [
            "navigation",
            "policyAdmission",
            "lock",
            "nativeHandoff",
            "transferAdmission",
            "postLockProgress",
            "writerFinish",
            "hiddenCompletion",
            "transferCompletion",
        ] {
            let status = try #require(completeMilestones.first { $0["milestone"] as? String == milestone })
            #expect(status["present"] as? Bool == true, "(milestone) should be present")
            #expect(status["correlationValid"] as? Bool == true, "(milestone) should be correlated")
            #expect(status["predicateValid"] as? Bool == true, "(milestone) should satisfy its predicate")
        }
        #expect(completeMilestones.first { $0["milestone"] as? String == "writerFinish" }?[
            "orderedAfterPrevious",
        ] as? Bool == true)
        #expect(try !String(decoding: JSONEncoder().encode(completeDiagnostic), as: UTF8.self).contains(request))

        for (eventName, expectedReason) in missingMilestones {
            let sample = BrowserDownloadPassiveObservation(
                context: fixture.context,
                events: events.filter { $0["event"] != eventName },
            )
            let diagnostic = BrowserDownloadWaitFailureDiagnostics.summarize(
                wait: .delayedHandoff,
                sample: sample,
                baseline: nil,
                sampleReadMissing: false,
                matcherMatched: false,
                expectedPhase: "locked",
            )
            let payload = try #require(JSONSerialization
                .jsonObject(with: JSONEncoder().encode(diagnostic)) as? [String: Any])
            let reasons = try #require(payload["reasons"] as? [String])

            #expect(reasons.contains(expectedReason), "Missing \(eventName) should report \(expectedReason)")
        }
    }

    @Test("Delayed handoff reports invalid progress, transfer completion, and unrelated failures separately")
    func delayedHandoffTimeoutClassifiesProgressAndScopesTerminalEvents() throws {
        let fixture = ReaderFixture(phase: "locked")
        let request = UUID().uuidString
        let operation = UUID().uuidString
        let capability = UUID().uuidString
        let connection = UUID().uuidString
        func event(_ name: String, _ time: String, _ extra: [String: String] = [:]) -> [String: String] {
            var result = [
                "runID": fixture.context.runID,
                "event": name,
                "fixtureRequest": request,
                "monotonicSeconds": time,
                "operation": operation,
                "capability": capability,
                "connectionID": connection,
            ]
            result.merge(extra) { _, value in value }
            return result
        }
        let events = [
            event("fixtureNavigationRequested", "1", ["fixtureRoute": "delayed-handoff"]),
            event("policyDownloadAdmitted", "2"),
            event("pendingPolicyLockApplied", "3", [
                "authenticated": "false",
                "available": "false",
                "contentEmpty": "true",
                "generationBefore": "4",
                "generation": "5",
            ]),
            event("nativeDownloadHandoff", "4", [
                "fixtureRoute": "delayed-handoff",
                "sameOrigin": "true",
                "fixtureOrigin": "true",
            ]),
            event("transferAdmitted", "5"),
            event("writerFinished", "6"),
            event("nativePostLockProgress", "5.5", [
                "callbackMonotonicSeconds": "5.4",
                "receivedBytes": "16777216",
                "expectedBytes": "16777216",
                "authenticated": "false",
                "available": "false",
            ]),
            event("hiddenCompletion", "8", [
                "contentEmpty": "true",
                "available": "false",
                "authenticated": "false",
                "activeWriterCount": "0",
                "retainedRecordCount": "1",
            ]),
        ]

        func reasons(for values: [[String: String]]) throws -> [String] {
            let sample = BrowserDownloadPassiveObservation(context: fixture.context, events: values)
            let diagnostic = BrowserDownloadWaitFailureDiagnostics.summarize(
                wait: .delayedHandoff,
                sample: sample,
                baseline: nil,
                sampleReadMissing: false,
                matcherMatched: false,
                expectedPhase: "locked",
            )
            let payload = try #require(JSONSerialization
                .jsonObject(with: JSONEncoder().encode(diagnostic)) as? [String: Any])
            return try #require(payload["reasons"] as? [String])
        }

        var invalidTimestamp = events
        invalidTimestamp[0]["monotonicSeconds"] = "nan"
        #expect(try reasons(for: invalidTimestamp).contains("invalidTimestamp"))

        var invalidProgress = events
        let progressIndex = try #require(invalidProgress.firstIndex { $0["event"] == "nativePostLockProgress" })
        invalidProgress[progressIndex]["callbackMonotonicSeconds"] = "nan"
        invalidProgress[progressIndex]["receivedBytes"] = "not-a-count"
        let progressReasons = try reasons(for: invalidProgress)
        #expect(progressReasons.contains("invalidTimestamp"))
        #expect(progressReasons.contains("progressPredicateMismatch"))

        var invalidProgressOrder = events
        let progressOrderIndex = try #require(invalidProgressOrder
            .firstIndex { $0["event"] == "nativePostLockProgress" })
        invalidProgressOrder[progressOrderIndex]["callbackMonotonicSeconds"] = "2.5"
        #expect(try reasons(for: invalidProgressOrder).contains("progressOrderMismatch"))

        var conflictingProgress = events
        var secondProgress = try #require(conflictingProgress.first { $0["event"] == "nativePostLockProgress" })
        secondProgress["monotonicSeconds"] = "5.6"
        secondProgress["callbackMonotonicSeconds"] = "5.5"
        conflictingProgress.append(secondProgress)
        let conflictReasons = try reasons(for: conflictingProgress)
        #expect(conflictReasons.contains("conflictingProgress"))
        #expect(conflictReasons.contains("conflictingTimestamps"))

        var missingTransferCompletion = events
        let hiddenIndex = try #require(missingTransferCompletion.firstIndex { $0["event"] == "hiddenCompletion" })
        missingTransferCompletion[hiddenIndex]["activeWriterCount"] = "1"
        let completionReasons = try reasons(for: missingTransferCompletion)
        #expect(completionReasons.contains("transferCompletionMissing"))

        let otherRequest = UUID().uuidString
        let unrelatedEvents = events + [
            [
                "runID": fixture.context.runID,
                "event": "nativeCancellationRequested",
                "fixtureRequest": otherRequest,
                "operation": UUID().uuidString,
            ],
            [
                "runID": fixture.context.runID,
                "event": "writerFailed",
                "fixtureRequest": otherRequest,
                "operation": UUID().uuidString,
            ],
        ]
        let unrelatedReasons = try reasons(for: unrelatedEvents)
        #expect(!unrelatedReasons.contains("cancellationObserved"))
        #expect(!unrelatedReasons.contains("failureObserved"))
    }

    @Test("Unscoped terminal events are counted without satisfying handoff proof")
    func delayedHandoffReportsExcludedTerminalEventCounts() {
        let fixture = ReaderFixture(phase: "locked")
        let request = UUID().uuidString
        let operation = UUID().uuidString
        let events: [[String: String]] = [
            [
                "runID": fixture.context.runID,
                "event": "fixtureNavigationRequested",
                "fixtureRoute": "delayed-handoff",
                "fixtureRequest": request,
            ],
            [
                "runID": fixture.context.runID,
                "event": "policyDownloadAdmitted",
                "fixtureRequest": request,
                "operation": operation,
            ],
            [
                "runID": fixture.context.runID,
                "event": "nativeCancellationRequested",
                "fixtureRequest": request,
                "operation": UUID().uuidString,
            ],
            ["runID": fixture.context.runID, "event": "writerFailed"],
        ]
        let sample = BrowserDownloadPassiveObservation(context: fixture.context, events: events)
        let diagnostic = BrowserDownloadWaitFailureDiagnostics.summarize(
            wait: .delayedHandoff,
            sample: sample,
            baseline: nil,
            sampleReadMissing: false,
            matcherMatched: false,
            expectedPhase: "locked",
        )

        #expect(diagnostic.excludedTerminalEvents?.cancellations == 1)
        #expect(diagnostic.excludedTerminalEvents?.failures == 1)
        #expect(!diagnostic.reasons.contains(.cancellationObserved))
        #expect(!diagnostic.reasons.contains(.failureObserved))
    }

    @Test("Delayed handoff marks missing and invalid progress timestamps as unverifiable")
    func delayedHandoffReportsUnverifiableProgressOrder() throws {
        let fixture = ReaderFixture(phase: "locked")
        let request = UUID().uuidString
        let operation = UUID().uuidString
        let capability = UUID().uuidString
        let connection = UUID().uuidString

        func event(_ name: String, _ time: String, _ extra: [String: String] = [:]) -> [String: String] {
            var result = [
                "runID": fixture.context.runID,
                "event": name,
                "fixtureRequest": request,
                "monotonicSeconds": time,
                "operation": operation,
                "capability": capability,
                "connectionID": connection,
            ]
            result.merge(extra) { _, value in value }
            return result
        }

        let baselineEvents = [
            event("fixtureNavigationRequested", "1", ["fixtureRoute": "delayed-handoff"]),
            event("policyDownloadAdmitted", "2"),
            event("pendingPolicyLockApplied", "3", [
                "authenticated": "false",
                "available": "false",
                "contentEmpty": "true",
                "generationBefore": "4",
                "generation": "5",
            ]),
        ]
        let timestampCases: [(String?, String?)] = [
            ("4", nil),
            ("4", "nan"),
            (nil, "4.5"),
            ("nan", "4.5"),
        ]
        for (progressTimestamp, callbackTimestamp) in timestampCases {
            var progress = event("nativePostLockProgress", progressTimestamp ?? "4", [
                "receivedBytes": "16777216",
                "expectedBytes": "16777216",
                "authenticated": "false",
                "available": "false",
            ])
            if progressTimestamp == nil {
                progress.removeValue(forKey: "monotonicSeconds")
            }
            progress["callbackMonotonicSeconds"] = callbackTimestamp
            let sample = BrowserDownloadPassiveObservation(
                context: fixture.context,
                events: baselineEvents + [progress],
            )
            let diagnostic = BrowserDownloadWaitFailureDiagnostics.summarize(
                wait: .delayedHandoff,
                sample: sample,
                baseline: nil,
                sampleReadMissing: false,
                matcherMatched: false,
                expectedPhase: "locked",
            )

            let payload = try #require(
                JSONSerialization.jsonObject(with: JSONEncoder().encode(diagnostic)) as? [String: Any],
            )
            let reasons = try #require(payload["reasons"] as? [String])
            #expect(reasons.contains("progressOrderUnverifiable"))
        }
    }

    @Test("Cold startup timeout reports Library context invalidation")
    func coldStartupTimeoutReportsLibraryContextMismatch() {
        let fixture = ReaderFixture()
        let lockedContext = BrowserDownloadObservationContext(
            processNonce: fixture.context.processNonce,
            runID: fixture.context.runID,
            authorizationGeneration: fixture.context.authorizationGeneration,
            resourceGeneration: fixture.context.resourceGeneration,
            ingestionGeneration: fixture.context.ingestionGeneration,
            phase: "locked",
            phaseRevision: fixture.context.phaseRevision,
        )
        let staleLibrary = BrowserDownloadLibraryObservation(
            context: fixture.context,
            outcome: .invalidated,
            fields: [:],
        )
        let sample = BrowserDownloadPassiveObservation(
            context: lockedContext,
            events: [],
            library: staleLibrary,
        )
        let diagnostic = BrowserDownloadWaitFailureDiagnostics.summarize(
            wait: .coldStartup,
            sample: sample,
            baseline: nil,
            sampleReadMissing: false,
            matcherMatched: false,
            expectedPhase: "locked",
        )

        #expect(diagnostic.reasons.contains(.contextMismatch))
        #expect(diagnostic.reasons.contains(.contextInvalidated))
        #expect(diagnostic.reasons.contains(.libraryInvalidated))
    }

    @Test("Cold startup timeout distinguishes unavailable and invalid Library samples")
    func coldStartupTimeoutReportsSampleRootAndLibraryOutcomes() {
        let missing = BrowserDownloadWaitFailureDiagnostics.summarize(
            wait: .coldStartup,
            sample: nil,
            baseline: nil,
            sampleReadMissing: true,
            matcherMatched: nil,
            expectedPhase: "locked",
        )
        #expect(missing.reasons.contains(.sampleUnavailable))

        let fixture = ReaderFixture()
        let wrongRoot = BrowserDownloadPassiveObservation(
            context: fixture.context,
            events: [],
            library: .init(context: fixture.context, outcome: .complete, fields: ["event": "acceptedLibraryStorage"]),
        )
        let wrongRootDiagnostic = BrowserDownloadWaitFailureDiagnostics.summarize(
            wait: .coldStartup,
            sample: wrongRoot,
            baseline: nil,
            sampleReadMissing: false,
            matcherMatched: false,
            expectedPhase: "locked",
        )
        #expect(wrongRootDiagnostic.reasons.contains(.rootPhaseMismatch))
        #expect(wrongRootDiagnostic.reasons.contains(.libraryStartupMismatch))

        let lockedContext = BrowserDownloadObservationContext(
            processNonce: fixture.context.processNonce,
            runID: fixture.context.runID,
            authorizationGeneration: fixture.context.authorizationGeneration,
            resourceGeneration: fixture.context.resourceGeneration,
            ingestionGeneration: fixture.context.ingestionGeneration,
            phase: "locked",
            phaseRevision: fixture.context.phaseRevision,
        )
        let hostDiagnostics = BrowserDownloadHostDiagnostics(records: [
            .init(
                ordinal: 1,
                event: .contextInvalidated,
                sceneLabel: "scene-1",
                activeScene: true,
                storageAvailable: true,
                rootPhase: .locked,
                rootEligible: true,
                readEligible: false,
                scenePhase: .active,
                outcome: .invalidated,
            ),
        ])
        let invalidated = BrowserDownloadPassiveObservation(
            context: lockedContext,
            events: [],
            library: .init(context: lockedContext, outcome: .invalidated, fields: [:]),
            hostDiagnostics: hostDiagnostics,
        )
        let invalidatedDiagnostic = BrowserDownloadWaitFailureDiagnostics.summarize(
            wait: .coldStartup,
            sample: invalidated,
            baseline: nil,
            sampleReadMissing: false,
            matcherMatched: false,
            expectedPhase: "locked",
        )
        #expect(invalidatedDiagnostic.reasons.contains(.libraryNonComplete))
        #expect(invalidatedDiagnostic.reasons.contains(.libraryInvalidated))
        #expect(invalidatedDiagnostic.reasons.contains(.contextInvalidated))
        #expect(invalidatedDiagnostic.hostDiagnostics == hostDiagnostics)

        let noLibrary = BrowserDownloadPassiveObservation(context: lockedContext, events: [])
        let noLibraryDiagnostic = BrowserDownloadWaitFailureDiagnostics.summarize(
            wait: .coldStartup,
            sample: noLibrary,
            baseline: nil,
            sampleReadMissing: false,
            matcherMatched: false,
            expectedPhase: "locked",
        )
        #expect(noLibraryDiagnostic.reasons.contains(.librarySampleMissing))
    }

    @Test("Timeout attachment uses allowlisted fields without serializing observation")
    func waitFailureAttachmentIsBoundedAndRedacted() throws {
        let fixture = ReaderFixture(phase: "locked")
        let hostDiagnostics = BrowserDownloadHostDiagnostics(records: [
            .init(
                ordinal: 1,
                event: .libraryReadOutcome,
                sceneLabel: "scene-1",
                activeScene: true,
                storageAvailable: false,
                rootPhase: .locked,
                rootEligible: true,
                readEligible: false,
                scenePhase: .active,
                outcome: .invalidated,
            ),
        ])
        let sample = BrowserDownloadPassiveObservation(
            context: fixture.context,
            events: [["runID": fixture.context.runID, "event": "safeEvent"]],
            hostDiagnostics: hostDiagnostics,
        )
        let diagnostic = BrowserDownloadWaitFailureDiagnostics.summarize(
            wait: .coldStartup,
            sample: sample,
            baseline: nil,
            sampleReadMissing: false,
            matcherMatched: false,
            expectedPhase: "locked",
        )
        let data = try #require(BrowserDownloadWaitFailureDiagnostics.attachmentData(
            for: .deadlineExceeded,
            diagnostic: diagnostic,
        ), "A timeout should produce bounded diagnostic data")

        let json = String(decoding: data, as: UTF8.self)

        #expect(data.count <= BrowserDownloadWaitFailureDiagnostics.maximumAttachmentByteCount)
        #expect(json.contains("\"hostDiagnostics\""))
        #expect(!json.contains("\"events\""))
        #expect(!json.contains("safeEvent"))
        #expect(!json.contains(fixture.context.runID))
        #expect(!json.contains("privatePath"))
        #expect(!json.contains("persistentIdentifier"))
    }

    @Test("Timeout attachment preserves the last matcher and host diagnostic details")
    func waitFailureAttachmentPreservesTimeoutPollDiagnostics() throws {
        let fixture = ReaderFixture(phase: "locked")
        let hostDiagnostics = BrowserDownloadHostDiagnostics(records: [
            .init(
                ordinal: 1,
                event: .libraryReadOutcome,
                sceneLabel: "scene-1",
                rootPhase: .locked,
                outcome: .failed,
                readSequence: 1,
                contextMatches: true,
            ),
        ])
        let sample = BrowserDownloadPassiveObservation(
            context: fixture.context,
            events: [["runID": fixture.context.runID, "event": "loopbackReady"]],
            hostDiagnostics: hostDiagnostics,
        )
        let diagnostic = BrowserDownloadWaitFailureDiagnostics.summarize(
            wait: .coldStartup,
            sample: sample,
            baseline: nil,
            sampleReadMissing: false,
            matcherMatched: false,
            expectedPhase: "locked",
            pollSequence: 7,
            validationStatus: .validated,
            pollFinalErrorClass: .deadlineExceeded,
        )
        let data = try #require(BrowserDownloadWaitFailureDiagnostics.attachmentData(
            for: .deadlineExceeded,
            diagnostic: diagnostic,
        ))
        let payload = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(payload["matcherMatched"] as? Bool == false)
        #expect(payload["pollSequence"] as? Int == 7)
        #expect(payload["validationStatus"] as? String == "validated")
        #expect(payload["hostDiagnostics"] != nil)
        #expect(payload["diagnosticStatus"] == nil)
        #expect((payload["reasons"] as? [String])?.isEmpty == false)
        #expect(data.count <= BrowserDownloadWaitFailureDiagnostics.maximumAttachmentByteCount)
    }

    @Test("Every waiter error receives a bounded failure attachment")
    func waitFailureAttachmentIncludesEveryErrorOutcome() throws {
        let diagnostic = BrowserDownloadWaitFailureDiagnostics.summarize(
            wait: .coldStartup,
            sample: nil,
            baseline: nil,
            sampleReadMissing: true,
            matcherMatched: nil,
            expectedPhase: "locked",
        )

        #expect(BrowserDownloadWaitFailureDiagnostics.attachmentData(for: nil, diagnostic: diagnostic) == nil)
        let failures: [(BrowserDownloadObservationError, String)] = [
            (.missing, "missing"),
            (.malformed, "malformed"),
            (.stale, "stale"),
            (.unavailable, "unavailable"),
            (.failed, "failed"),
            (.invalidated, "invalidated"),
            (.interrupted, "interrupted"),
            (.deadlineExceeded, "deadlineExceeded"),
        ]
        for (failure, expectedClass) in failures {
            let data = try #require(BrowserDownloadWaitFailureDiagnostics.attachmentData(
                for: failure,
                diagnostic: diagnostic,
            ))
            let payload = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

            #expect(payload["errorClass"] as? String == expectedClass)
            #expect(data.count <= BrowserDownloadWaitFailureDiagnostics.maximumAttachmentByteCount)
            #expect(payload["events"] == nil)
            #expect(payload["sample"] == nil)
        }
    }

    @Test("Error correlation mismatch falls back to a minimal attachment")
    func waitFailureAttachmentFallsBackOnCorrelationMismatch() throws {
        let diagnostic = BrowserDownloadWaitFailureDiagnostics.summarize(
            wait: .coldStartup,
            sample: nil,
            baseline: nil,
            sampleReadMissing: true,
            matcherMatched: nil,
            expectedPhase: "locked",
            pollFinalErrorClass: .deadlineExceeded,
        )
        let data = try #require(BrowserDownloadWaitFailureDiagnostics.attachmentData(
            for: .unavailable,
            diagnostic: diagnostic,
        ))
        let payload = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(payload["errorClass"] as? String == "unavailable")
        #expect(payload["diagnosticStatus"] as? String == "correlationMismatch")
        #expect(Set(payload.keys) == Set(["errorClass", "diagnosticStatus"]))
        #expect(data.count <= BrowserDownloadWaitFailureDiagnostics.maximumAttachmentByteCount)
    }

    @Test("Oversized diagnostics fall back to a minimal attachment")
    func waitFailureAttachmentFallsBackWhenPayloadExceedsLimit() throws {
        let diagnostic = BrowserDownloadWaitFailureDiagnostics(
            wait: .coldStartup,
            errorClass: nil,
            readOutcome: .sampleUnavailable,
            matcherMatched: nil,
            reasons: Array(repeating: .waitConditionUnmet, count: 700),
            contextStatus: nil,
            milestones: [],
            libraryStatus: .absent,
            hostDiagnostics: nil,
            pollSequence: nil,
            validationStatus: nil,
            validationErrorClass: nil,
            pollFinalErrorClass: nil,
            hostDiagnosticsStatus: .unavailable,
        )
        let detailedData = try JSONEncoder().encode(diagnostic)
        #expect(detailedData.count > BrowserDownloadWaitFailureDiagnostics.maximumAttachmentByteCount)

        let data = try #require(BrowserDownloadWaitFailureDiagnostics.attachmentData(
            for: .deadlineExceeded,
            diagnostic: diagnostic,
        ))
        let payload = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(payload["errorClass"] as? String == "deadlineExceeded")
        #expect(payload["diagnosticStatus"] as? String == "payloadOverLimit")
        #expect(Set(payload.keys) == Set(["errorClass", "diagnosticStatus"]))
        #expect(data.count <= BrowserDownloadWaitFailureDiagnostics.maximumAttachmentByteCount)
    }

    @Test("Reader does not expose a sample that expires before validation")
    func passiveReaderDoesNotRetainUnvalidatedSample() {
        let fixture = ReaderFixture()
        let hostDiagnostics = BrowserDownloadHostDiagnostics(records: [
            .init(
                ordinal: 1,
                event: .libraryReadOutcome,
                sceneLabel: "scene-1",
                activeScene: true,
                storageAvailable: true,
                rootPhase: .locked,
                rootEligible: true,
                readEligible: false,
                scenePhase: .active,
                outcome: .complete,
            ),
        ])
        let sample = BrowserDownloadPassiveObservation(
            context: fixture.context,
            events: [["runID": fixture.context.runID, "event": "already-read"]],
            hostDiagnostics: hostDiagnostics,
        )

        #expect(throws: BrowserDownloadObservationError.deadlineExceeded) {
            try fixture.read(
                sample: {
                    fixture.time += 10
                    return sample
                },
                matching: { _ in false },
            )
        }

        #expect(fixture.reader.lastSample == nil)
    }

    @Test("Reader failure does not retain a prior sample across polls")
    func passiveReaderFailureDoesNotRetainPriorSample() throws {
        let fixture = ReaderFixture()
        let previousDiagnostics = BrowserDownloadHostDiagnostics(records: [
            .init(ordinal: 1, event: .libraryReadEligibilityChanged, sceneLabel: "scene-1"),
        ])
        let previousSample = BrowserDownloadPassiveObservation(
            context: fixture.context,
            events: [["runID": fixture.context.runID, "event": "previous-poll"]],
            hostDiagnostics: previousDiagnostics,
        )
        let staleContext = ReaderFixture().context
        let staleSample = BrowserDownloadPassiveObservation(context: staleContext, events: [])
        var sampleReadCount = 0

        #expect(throws: BrowserDownloadObservationError.stale) {
            try fixture.read(
                sample: {
                    sampleReadCount += 1
                    return sampleReadCount == 1 ? previousSample : staleSample
                },
                matching: { _ in false },
                wait: { _, poll in
                    #expect(poll())
                    return .timedOut
                },
            )
        }

        #expect(sampleReadCount == 2)
        #expect(fixture.reader.lastSample == nil)
        #expect(fixture.reader.lastReadContext == staleContext)
        #expect(fixture.reader.lastSampleReadSucceeded)
        #expect(fixture.reader.lastMatcherOutcome == nil)

        let poll = try #require(fixture.reader.lastPollDiagnosticSnapshot)
        #expect(poll.sequence == 2)
        #expect(poll.readOutcome == .sampleUnvalidated)
        #expect(poll.validationStatus == .failed)
        #expect(poll.validationErrorClass == .stale)
        #expect(poll.finalErrorClass == .stale)
        #expect(poll.observedContext == staleContext)
        #expect(poll.hostDiagnostics == previousDiagnostics)
        #expect(poll.hostDiagnosticsSourceSequence == 1)

        let diagnostic = BrowserDownloadWaitFailureDiagnostics.summarize(
            wait: .coldStartup,
            poll: poll,
            baseline: nil,
            expectedPhase: "authenticated",
            expectedProcessNonce: fixture.context.processNonce,
        )
        let data = try #require(BrowserDownloadWaitFailureDiagnostics.attachmentData(
            for: .stale,
            diagnostic: diagnostic,
        ))
        let payload = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let hostStatus = try #require(payload["hostDiagnosticsStatus"] as? [String: Any])

        #expect(payload["errorClass"] as? String == "stale")
        #expect(payload["pollFinalErrorClass"] as? String == "stale")
        #expect(payload["validationStatus"] as? String == "failed")
        #expect(payload["validationErrorClass"] as? String == "stale")
        #expect(hostStatus["available"] as? Bool == true)
        #expect(hostStatus["sourcePollSequence"] as? Int == 1)
        #expect(hostStatus["ageInPolls"] as? Int == 1)
        #expect(hostStatus["stale"] as? Bool == true)
        let serialized = String(decoding: data, as: UTF8.self)
        #expect(!serialized.contains(staleContext.processNonce.uuidString))
        #expect(!serialized.contains(staleContext.runID))
        #expect(!serialized.contains("previous-poll"))
    }

    @Test("The final poll owns the missing-sample state")
    func passiveReaderMissingStateBelongsToFinalPoll() {
        let fixture = ReaderFixture()
        var sampleReadCount = 0
        var matcherCount = 0

        #expect(throws: BrowserDownloadObservationError.deadlineExceeded) {
            try fixture.read(
                sample: {
                    sampleReadCount += 1
                    if sampleReadCount == 1 {
                        throw BrowserDownloadObservationError.missing
                    }
                    return fixture.sample("notReady")
                },
                matching: { _ in
                    matcherCount += 1
                    return false
                },
                wait: { _, poll in
                    #expect(!poll())
                    return .timedOut
                },
            )
        }

        #expect(sampleReadCount == 2)
        #expect(matcherCount == 1)
        #expect(!fixture.reader.lastSampleReadMissing)
        #expect(fixture.reader.lastPollDiagnosticSnapshot?.sequence == 2)
        #expect(fixture.reader.lastPollDiagnosticSnapshot?.readOutcome == .sampleAvailable)
        #expect(fixture.reader.lastPollDiagnosticSnapshot?.finalErrorClass == .deadlineExceeded)
    }

    @Test("Malformed read failures keep their final poll attribution")
    func passiveReaderMalformedFailureSnapshotMatchesAttachment() throws {
        let fixture = ReaderFixture()
        #expect(throws: BrowserDownloadObservationError.malformed) {
            try fixture.read(
                sample: { throw BrowserDownloadObservationError.malformed },
                matching: { _ in false },
            )
        }

        let poll = try #require(fixture.reader.lastPollDiagnosticSnapshot)
        #expect(poll.sequence == 1)
        #expect(poll.readOutcome == .sampleUnavailable)
        #expect(poll.validationStatus == .notAttempted)
        #expect(poll.finalErrorClass == .malformed)
        let diagnostic = BrowserDownloadWaitFailureDiagnostics.summarize(
            wait: .coldStartup,
            poll: poll,
            baseline: nil,
            expectedPhase: "authenticated",
            expectedProcessNonce: fixture.context.processNonce,
        )
        let data = try #require(BrowserDownloadWaitFailureDiagnostics.attachmentData(
            for: .malformed,
            diagnostic: diagnostic,
        ))
        let payload = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(payload["errorClass"] as? String == "malformed")
        #expect(payload["pollFinalErrorClass"] as? String == "malformed")
        #expect(payload["readOutcome"] as? String == "sampleUnavailable")
        #expect(payload["validationStatus"] as? String == "notAttempted")
    }

    @Test("Successful reader preserves its result without a second sample or match")
    func passiveReaderKeepsSingleSuccessfulSampleAndMatcherOutcome() throws {
        let fixture = ReaderFixture()
        let ready = fixture.sample()
        var sampleCount = 0
        var matcherCount = 0

        let result = try fixture.read(
            sample: {
                sampleCount += 1
                return ready
            },
            matching: { _ in
                matcherCount += 1
                return true
            },
        )

        #expect(result == ready)
        #expect(sampleCount == 1)
        #expect(matcherCount == 1)
        #expect(fixture.reader.lastSample == ready)
        #expect(fixture.reader.lastMatcherOutcome == true)
    }

    @Test("Reader timeout retains one sampled matcher result and the original deadline")
    func passiveReaderTimeoutRetainsSampleAndMatcherOutcome() {
        let fixture = ReaderFixture()
        let sample = fixture.sample("notReady")
        var sampleCount = 0
        var matcherCount = 0
        var waitInterval: TimeInterval = 0

        #expect(throws: BrowserDownloadObservationError.deadlineExceeded) {
            try fixture.read(
                sample: {
                    sampleCount += 1
                    return sample
                },
                matching: { _ in
                    matcherCount += 1
                    return false
                },
                wait: { interval, _ in
                    waitInterval = interval
                    fixture.time += interval
                    return .timedOut
                },
            )
        }

        #expect(waitInterval == 10)
        #expect(fixture.time == 110)
        #expect(sampleCount == 1)
        #expect(matcherCount == 1)
        #expect(fixture.reader.lastSample == sample)
        #expect(fixture.reader.lastMatcherOutcome == false)
    }
}

@MainActor
private final class ReaderFixture {
    let context: BrowserDownloadObservationContext
    let reader: BrowserDownloadPassiveReader
    var time: TimeInterval = 100
    var interrupted = false

    init(phase: String = "authenticated") {
        context = .init(
            processNonce: UUID(),
            runID: UUID().uuidString,
            authorizationGeneration: 2,
            resourceGeneration: 3,
            ingestionGeneration: 4,
            phase: phase,
            phaseRevision: 1,
        )
        reader = .init(processNonce: context.processNonce)
    }

    func sample(_ event: String = "loopbackReady") -> BrowserDownloadPassiveObservation {
        .init(context: context, events: [["runID": context.runID, "event": event]])
    }

    func read(
        sample: @escaping () throws -> BrowserDownloadPassiveObservation,
        matching: @escaping (BrowserDownloadPassiveObservation) throws
            -> Bool = { $0.events.last?["event"] == "loopbackReady" },
        wait: (TimeInterval, @escaping @MainActor () -> Bool) -> BrowserDownloadPassiveReader.WaitResult = { _, _ in
            Issue.record("An immediately resolved observation entered the waiter")
            return .interrupted
        },
    ) throws -> BrowserDownloadPassiveObservation {
        try reader.read(
            now: { self.time },
            interrupted: { self.interrupted },
            sample: sample,
            matching: matching,
            wait: wait,
        )
    }
}

@MainActor
extension AppHostedUITests.BrowserDownloadObservationReceiptTests {
    @Test("Passive observations keep host diagnostics outside the observation payload")
    func passiveObservationCarriesRedactedHostDiagnosticChannel() throws {
        let fixture = ReaderFixture(phase: "locked")
        let encoded = try JSONEncoder().encode(fixture.sample())
        let observation = try JSONSerialization.jsonObject(with: encoded)
        let payload: [String: Any] = [
            "observation": observation,
            "hostDiagnostics": [
                "truncated": true,
                "records": [[
                    "ordinal": 1,
                    "event": "libraryReadOutcome",
                    "sceneLabel": "scene-1",
                    "activeScene": false,
                    "storageAvailable": true,
                    "rootPhase": "locked",
                    "rootEligible": false,
                    "outcome": "invalidated",
                    "privatePath": "/private/media.png",
                    "persistentSceneID": "session-secret",
                ]],
            ],
        ]
        let wireData = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        let wire = String(decoding: wireData, as: UTF8.self)
        let decoded = try? BrowserDownloadPassiveObservation.decode(wire)

        #expect(decoded != nil)
        guard let decoded else {
            return
        }

        #expect(decoded.hostDiagnostics?.truncated == true)
        #expect(decoded.hostDiagnostics?.records.count == 1)
        #expect(decoded.hostDiagnostics?.records.first?.sceneLabel == "scene-1")
        let fullSample = try JSONEncoder().encode(decoded)
        let fullSampleJSON = String(decoding: fullSample, as: UTF8.self)
        #expect(!fullSampleJSON.contains("hostDiagnostics"))
        #expect(!fullSampleJSON.contains("session-secret"))
        #expect(!fullSampleJSON.contains("/private/media.png"))
    }

    @Test("Malformed diagnostic envelopes do not fall back to legacy observations")
    func passiveObservationRejectsMalformedDiagnosticEnvelopes() throws {
        let fixture = ReaderFixture(phase: "locked")
        let legacyData = try JSONEncoder().encode(fixture.sample())
        let legacyObject = try #require(JSONSerialization.jsonObject(with: legacyData) as? [String: Any])
        let legacyWire = String(decoding: legacyData, as: UTF8.self)

        #expect(try BrowserDownloadPassiveObservation.decode(legacyWire).hostDiagnostics == nil)

        var missingObservation = legacyObject
        missingObservation["hostDiagnostics"] = ["truncated": false, "records": []]
        let missingObservationData = try JSONSerialization.data(withJSONObject: missingObservation)
        let missingObservationWire = String(decoding: missingObservationData, as: UTF8.self)
        #expect(throws: BrowserDownloadObservationError.malformed) {
            try BrowserDownloadPassiveObservation.decode(missingObservationWire)
        }

        var malformedObservation = missingObservation
        malformedObservation["observation"] = ["context": "invalid"]
        let malformedObservationData = try JSONSerialization.data(withJSONObject: malformedObservation)
        let malformedObservationWire = String(decoding: malformedObservationData, as: UTF8.self)
        #expect(throws: BrowserDownloadObservationError.malformed) {
            try BrowserDownloadPassiveObservation.decode(malformedObservationWire)
        }
    }
}

extension AppHostedUITests.BrowserDownloadObservationReceiptTests {
    @Test
    func passiveReaderAcceptsAvailableMilestoneBeforeWaiting() throws {
        let fixture = ReaderFixture()
        let ready = fixture.sample()
        let result = try fixture.read(sample: { ready })
        #expect(result == ready)
    }

    @Test
    func passiveReaderPollsUntilMilestoneAppears() throws {
        let fixture = ReaderFixture()
        var calls = 0
        let result = try fixture.read(sample: {
            calls += 1
            if calls == 1 {
                throw BrowserDownloadObservationError.missing
            }
            return calls == 2 ? fixture.sample("ownerSnapshot") : fixture.sample()
        }, wait: { interval, poll in
            #expect(interval == 10)
            #expect(!poll())
            fixture.time = 109
            #expect(poll())
            return .completed
        })
        #expect(calls == 3)
        #expect(result == fixture.sample())
    }

    @Test
    func passiveReaderRejectsUnchangedMilestone() {
        let fixture = ReaderFixture()
        let previous = fixture.sample()
        #expect(throws: BrowserDownloadObservationError.deadlineExceeded) {
            try fixture.read(
                sample: { previous },
                matching: { $0.completedAttachment(after: previous) != nil },
                wait: { _, poll in
                    #expect(!poll())
                    return .timedOut
                },
            )
        }
    }

    @Test
    func passiveReaderRejectsWrongProcessRunAndContext() throws {
        let fixture = ReaderFixture()
        let current = fixture.context
        _ = try fixture.read(sample: { fixture.sample() })
        func reject(_ context: BrowserDownloadObservationContext) {
            #expect(throws: BrowserDownloadObservationError.stale) {
                try fixture.read(sample: { .init(context: context, events: []) })
            }
        }
        reject(ReaderFixture().context)
        reject(.init(
            processNonce: current.processNonce,
            runID: UUID().uuidString,
            authorizationGeneration: 2,
            resourceGeneration: 3,
            ingestionGeneration: 4,
            phase: "authenticated",
            phaseRevision: 1,
        ))
        for generations in [(1, 3, 4), (2, 2, 4), (2, 3, 3)] {
            reject(.init(
                processNonce: current.processNonce,
                runID: current.runID,
                authorizationGeneration: UInt64(generations.0),
                resourceGeneration: UInt64(generations.1),
                ingestionGeneration: UInt64(generations.2),
                phase: "authenticated",
                phaseRevision: 1,
            ))
        }
        var newer = current
        newer.phaseRevision += 2
        try fixture.reader.validate(.init(context: newer, events: []))
        reject(current)
    }

    @Test
    func passiveReaderPreservesInvalidatedMalformedAndMissing() {
        let fixture = ReaderFixture()
        for (outcome, error) in [
            (BrowserDownloadLibraryObservation.Outcome.invalidated, BrowserDownloadObservationError.invalidated),
            (.failed, .failed),
            (.unavailable, .unavailable),
        ] {
            let library = BrowserDownloadLibraryObservation(context: fixture.context, outcome: outcome, fields: [:])
            #expect(throws: error) {
                try fixture.read(
                    sample: { .init(context: fixture.context, events: [], library: library) },
                    matching: { try $0.library?.completedFields() != nil },
                )
            }
        }
        #expect(throws: BrowserDownloadObservationError.malformed) {
            try fixture.read(sample: { try .decode("malformed") })
        }
        #expect(throws: BrowserDownloadObservationError.missing) {
            try fixture.read(sample: { try .decode(nil) }, wait: { _, poll in
                #expect(!poll())
                return .timedOut
            })
        }
    }

    @Test
    func passiveReaderRejectsMilestoneAtAndAfterDeadline() {
        for time in [110.0, 111.0] {
            let fixture = ReaderFixture()
            #expect(throws: BrowserDownloadObservationError.deadlineExceeded) {
                try fixture.read(sample: { fixture.time = time
                    return fixture.sample()
                })
            }
        }
    }

    @Test
    func passiveReaderChecksDeadlineAfterWaiterCompletes() {
        let fixture = ReaderFixture()
        var ready = false
        #expect(throws: BrowserDownloadObservationError.deadlineExceeded) {
            try fixture.read(sample: { fixture.sample(ready ? "loopbackReady" : "ownerSnapshot") }, wait: { _, poll in
                ready = true
                #expect(poll())
                fixture.time = 110
                return .completed
            })
        }
    }

    @Test
    func passiveReaderPreservesInterruption() {
        let fixture = ReaderFixture()
        #expect(throws: BrowserDownloadObservationError.interrupted) {
            try fixture.read(sample: { fixture.sample("ownerSnapshot") }, wait: { _, _ in .interrupted })
        }
        #expect(throws: BrowserDownloadObservationError.interrupted) {
            try fixture.read(sample: { fixture.interrupted = true
                return fixture.sample()
            })
        }
    }

    @Test
    func passiveReaderMapsPendingTimeoutToOriginalDeadline() {
        let fixture = ReaderFixture()
        #expect(throws: BrowserDownloadObservationError.deadlineExceeded) {
            try fixture.read(sample: {
                fixture.time = 104
                return fixture.sample("ownerSnapshot")
            }, wait: { budget, _ in
                #expect(budget == 6)
                return .timedOut
            })
        }
    }

    @Test
    func lockedStorageRejectsCanonicalQuantitiesAndForeignContexts() throws {
        let locked = ReaderFixture(phase: "locked")
        let fields = [
            "event": "libraryStartup",
            "libraryID": UUID().uuidString,
            "databaseID": String(repeating: "a", count: 64),
            "processID": "1",
            "runID": locked.context.runID,
            "authenticated": "false",
            "contentEmpty": "true",
            "singleStagedFixture": "false",
            "stagingEmpty": "true",
        ]
        func sample(_ extra: [String: String]) -> BrowserDownloadLibraryObservation {
            .init(context: locked.context, outcome: .complete, fields: fields.merging(extra) { _, new in new })
        }
        try sample([:]).validate(for: locked.context)
        for extra in [
            ["assetCount": "0"],
            ["temporaryBytes": "151"],
            ["operation": UUID().uuidString],
            ["event": "canonicalLibrarySnapshot"],
            ["singleStagedFixture": "true"],
            ["contentEmpty": "missing"],
        ] {
            #expect(throws: BrowserDownloadObservationError.malformed) {
                try sample(extra).validate(for: locked.context)
            }
        }
        #expect(throws: BrowserDownloadObservationError.stale) {
            try sample([:]).validate(for: ReaderFixture().context)
        }
    }

    @Test
    func stagingAndCanonicalMilestonesRequireOneNewFinishedOperation() {
        let context = ReaderFixture().context
        let request = UUID().uuidString
        let operation = UUID().uuidString
        let capability = UUID().uuidString
        let initial = ["event": "loopbackReady", "runID": context.runID, "monotonicSeconds": "1"]
        let baseline = BrowserDownloadPassiveObservation(context: context, events: [initial])
        let locked = BrowserDownloadObservationContext(
            processNonce: context.processNonce,
            runID: context.runID,
            authorizationGeneration: context.authorizationGeneration + 1,
            resourceGeneration: context.resourceGeneration + 1,
            ingestionGeneration: context.ingestionGeneration + 1,
            phase: "locked",
            phaseRevision: context.phaseRevision + 1,
        )
        func observed(
            underLock: Bool,
            wrongRequest: Bool = false,
            wrongWriter: Bool = false,
            missingLock: Bool = false,
        ) -> BrowserDownloadPassiveObservation {
            var events: [[String: String]] = [initial]
            func append(_ event: String, _ fields: [String: String] = [:]) {
                events.append(fields.merging([
                    "event": event,
                    "runID": context.runID,
                    "monotonicSeconds": String(events.count + 1),
                ]) { _, new in new })
            }
            append("fixtureNavigationRequested", ["fixtureRoute": "image", "fixtureRequest": request])
            append("policyDownloadAdmitted", ["operation": operation, "capability": capability])
            if underLock, !missingLock {
                append("automaticMediaPolicyLocked")
            }
            var handoff = [
                "fixtureRoute": "image",
                "fixtureRequest": wrongRequest ? UUID().uuidString : request,
                "sameOrigin": "true",
                "fixtureOrigin": "true",
            ]
            if !underLock {
                handoff["operation"] = operation
            }
            append("nativeDownloadHandoff", handoff)
            append("transferAdmitted", ["operation": operation, "capability": capability])
            append("writerFinished", ["operation": wrongWriter ? UUID().uuidString : operation])
            return .init(context: underLock ? locked : context, events: events)
        }
        for underLock in [false, true] {
            let sample = observed(underLock: underLock)
            #expect(sample.finishedOperation(after: baseline, route: "image", locked: underLock) == operation)
            #expect(sample.finishedOperation(after: sample, route: "image", locked: underLock) == nil)
            #expect(observed(underLock: underLock, wrongRequest: true).finishedOperation(
                after: baseline,
                route: "image",
                locked: underLock,
            ) == nil)
            #expect(observed(underLock: underLock, wrongWriter: true).finishedOperation(
                after: baseline,
                route: "image",
                locked: underLock,
            ) == nil)
        }
        #expect(observed(underLock: true, missingLock: true).finishedOperation(
            after: baseline,
            route: "image",
            locked: true,
        ) == nil)
    }

    @Test
    func lockedStagingRequiresExactBytesCountAndOperation() {
        let expected = UUID()
        func matches(_ operation: UUID?, _ verified: Bool, _ same: Bool?, _ count: Int, _ bytes: Int64) -> Bool {
            BrowserDownloadLibraryObservation.matchesStagedFixture(
                operation: operation,
                verified: verified,
                matchesOperation: same,
                count: count,
                bytes: bytes,
                expectedBytes: 151,
            )
        }
        #expect(matches(expected, true, true, 1, 151))
        #expect(!matches(nil, true, true, 1, 151))
        #expect(!matches(expected, false, true, 1, 151))
        #expect(!matches(expected, true, false, 1, 151))
        #expect(!matches(expected, true, nil, 1, 151))
        #expect(!matches(expected, true, true, 2, 151))
        #expect(!matches(expected, true, true, 1, 150))
        #expect(!matches(expected, true, true, 0, 0))
    }
}

extension AppHostedUITests.BrowserDownloadObservationReceiptTests {
    @Test
    func physicalLibraryExportMatchesAXAndIsCompleteBeforeReturn() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let recorder = BrowserDownloadProductionEvidence(preservesTransferMilestones: false, url: url)
        let run = recorder.runID
        let process = UUID()
        let locked = BrowserDownloadObservationContext(
            processNonce: process,
            runID: run,
            authorizationGeneration: 2,
            resourceGeneration: 3,
            ingestionGeneration: 4,
            phase: "locked",
            phaseRevision: 1,
        )
        let authenticated = BrowserDownloadObservationContext(
            processNonce: process,
            runID: run,
            authorizationGeneration: 3,
            resourceGeneration: 4,
            ingestionGeneration: 5,
            phase: "authenticated",
            phaseRevision: 2,
        )
        let identity = [
            "libraryID": UUID().uuidString,
            "databaseID": String(repeating: "a", count: 64),
            "processID": String(ProcessInfo.processInfo.processIdentifier),
            "runID": run,
        ]
        let operation = UUID().uuidString
        let startup = identity.merging([
            "event": "libraryStartup",
            "authenticated": "false",
            "singleStagedFixture": "false",
            "stagingEmpty": "true",
            "contentEmpty": "true",
        ]) { _, next in next }
        let accepted = startup.merging([
            "event": "acceptedLibraryStorage",
            "singleStagedFixture": "true",
            "stagingEmpty": "false",
            "operation": operation,
        ]) { _, next in next }
        let canonical = identity.merging([
            "event": "canonicalLibrarySnapshot",
            "authenticated": "true",
            "canonicalIDs": UUID().uuidString,
            "assetCount": "1",
            "resourceCount": "1",
            "rowCount": "1",
            "rowIDs": operation,
            "importedRows": "1",
            "duplicateRows": "0",
            "temporaryCount": "0",
            "temporaryBytes": "0",
            "originalBytesMatch": "true",
            "originalHashMatches": "true",
            "settled": "true",
        ]) { _, next in next }
        func ax(authenticated: Bool) throws -> [[String: String]] {
            try JSONDecoder().decode(
                [[String: String]].self,
                from: Data(recorder.observationsJSON(authenticated: authenticated).utf8),
            )
        }
        let records = [startup, accepted, canonical]
        for (index, fields) in records.enumerated() {
            let context = index < 2 ? locked : authenticated
            let sample = BrowserDownloadLibraryObservation(context: context, outcome: .complete, fields: fields)
            recorder.recordLibrary(sample, current: context, physicalCompatibility: true)
            recorder.recordLibrary(sample, current: context, physicalCompatibility: true)

            // Reopen the export before recording the next milestone, just as an operator can after termination.
            let bytes = try Data(contentsOf: url)
            #expect(bytes.last == 0x0a)
            let disk = try bytes.split(separator: 0x0a).map { try JSONDecoder().decode(
                [String: String].self,
                from: Data($0),
            ) }
            let visible = try ax(authenticated: index == 2)
            #expect(disk == visible)
            #expect(disk.count == index + 1)
            for (row, expected) in zip(disk, records) {
                #expect(row.filter { $0.key != "wallTime" && $0.key != "monotonicSeconds" } == expected)
                #expect(row["monotonicSeconds"].flatMap(Double.init)?.isFinite == true)
                #expect(row["wallTime"]?.isEmpty == false)
            }
        }

        let exported = try Data(contentsOf: url)
        #expect(try ax(authenticated: false).compactMap { $0["event"] } == ["libraryStartup", "acceptedLibraryStorage"])
        #expect(try ax(authenticated: true).compactMap { $0["event"] } == records.compactMap { $0["event"] })
        #expect(recorder.observationEvents.isEmpty)
        #expect(try Data(contentsOf: url) == exported)
        Attachment.record(String(decoding: exported, as: UTF8.self), named: "operator-library-milestones.jsonl")
    }

    @Test
    func libraryExportRejectsPassiveStaleFailedAndUnredactedSamples() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let recorder = BrowserDownloadProductionEvidence(preservesTransferMilestones: false, url: url)
        let context = BrowserDownloadObservationContext(
            processNonce: UUID(),
            runID: recorder.runID,
            authorizationGeneration: 2,
            resourceGeneration: 3,
            ingestionGeneration: 4,
            phase: "locked",
            phaseRevision: 1,
        )
        let fields = [
            "event": "libraryStartup",
            "libraryID": UUID().uuidString,
            "databaseID": String(repeating: "a", count: 64),
            "processID": String(ProcessInfo.processInfo.processIdentifier),
            "runID": recorder.runID,
            "authenticated": "false",
            "singleStagedFixture": "false",
            "stagingEmpty": "true",
            "contentEmpty": "true",
        ]
        let valid = BrowserDownloadLibraryObservation(context: context, outcome: .complete, fields: fields)
        recorder.recordLibrary(valid, current: context, physicalCompatibility: false)
        var newer = context
        newer.phaseRevision += 1
        recorder.recordLibrary(valid, current: newer, physicalCompatibility: true)
        for state in [BrowserDownloadLibraryObservation.Outcome.unavailable, .invalidated, .failed] {
            recorder.recordLibrary(
                .init(context: context, outcome: state, fields: [:]),
                current: context,
                physicalCompatibility: true,
            )
        }
        for extra in [["temporaryBytes": "151"], ["canonicalIDs": UUID().uuidString], ["processID": "-1"]] {
            recorder.recordLibrary(
                .init(context: context, outcome: .complete, fields: fields.merging(extra) { _, next in next }),
                current: context,
                physicalCompatibility: true,
            )
        }
        #expect(recorder.observationsJSON(authenticated: true) == "[]")
        #expect(!FileManager.default.fileExists(atPath: url.path))

        let unavailable = BrowserDownloadProductionEvidence(
            preservesTransferMilestones: false,
            url: url.appendingPathComponent("unavailable.jsonl"),
        )
        let otherContext = BrowserDownloadObservationContext(
            processNonce: context.processNonce,
            runID: unavailable.runID,
            authorizationGeneration: 2,
            resourceGeneration: 3,
            ingestionGeneration: 4,
            phase: "locked",
            phaseRevision: 1,
        )
        let undeliverable = BrowserDownloadLibraryObservation(
            context: otherContext,
            outcome: .complete,
            fields: fields
                .merging(["runID": unavailable.runID]) { _, next in
                    next
                },
        )
        unavailable.recordLibrary(undeliverable, current: otherContext, physicalCompatibility: true)
        #expect(unavailable.observationsJSON(authenticated: false) == "[]")
    }
}
