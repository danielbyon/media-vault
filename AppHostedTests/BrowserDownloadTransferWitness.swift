//
//  BrowserDownloadTransferWitness.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

/// Keeps only opaque identities and elapsed time from a live partial-transfer checkpoint.
struct BrowserDownloadTransferWitness {
    typealias Observation = [String: String]

    let runID: String
    let route: String
    let requestID: String
    let operationID: String
    let connectionID: String
    let generation: String
    let elapsedMilliseconds: Int

    var diagnosticFields: Observation {
        [
            "runID": runID,
            "fixtureRequest": requestID,
            "operation": operationID,
            "connectionID": connectionID,
            "generation": generation,
            "elapsedMilliseconds": String(elapsedMilliseconds),
        ]
    }
}

enum SlowKnownWitnessContract {
    typealias Observation = [String: String]

    static func witness(from events: [Observation]) -> BrowserDownloadTransferWitness? {
        guard events.count <= 256 else {
            return nil
        }

        let navigations = events.filter {
            $0["event"] == "fixtureNavigationRequested"
                && ["slow-known", "finite-continuation"].contains($0["fixtureRoute"] ?? "")
        }
        guard navigations.count == 1, let navigation = navigations.first,
              let runID = navigation["runID"], let requestID = navigation["fixtureRequest"],
              let route = navigation["fixtureRoute"]
        else {
            return nil
        }

        let runEvents = events.filter { $0["runID"] == runID }

        let serverEvents = runEvents.filter {
            $0["event"] == "slowKnownServerPrefixProcessed" && $0["fixtureRequest"] == requestID
        }
        let handoffs = runEvents.filter {
            $0["event"] == "nativeDownloadHandoff" && $0["fixtureRequest"] == requestID
        }
        let progressEvents = runEvents.filter {
            $0["event"] == "slowKnownProgress" && $0["fixtureRequest"] == requestID
        }
        let readinessEvents = runEvents.filter {
            $0["event"] == "slowKnownReadiness" && $0["fixtureRequest"] == requestID
        }
        guard serverEvents.count == 1, handoffs.count == 1,
              progressEvents.count == 1, readinessEvents.count == 1,
              let server = serverEvents.first, let handoff = handoffs.first,
              let progress = progressEvents.first, let readiness = readinessEvents.first,
              let operationID = progress["operation"],
              let generation = readiness["generation"],
              let connectionID = server["connectionID"],
              let expected = Int(server["expectedBytes"] ?? ""),
              let prefix = Int(server["prefixBytes"] ?? ""),
              let received = Int(progress["receivedBytes"] ?? ""),
              let elapsed = Int(readiness["elapsedMilliseconds"] ?? "")
        else {
            return nil
        }

        let admissions = runEvents.filter {
            $0["event"] == "transferAdmitted" && $0["fixtureRequest"] == requestID
        }
        let policies = runEvents.filter {
            $0["event"] == "policyDownloadAdmitted" && $0["fixtureRequest"] == requestID
        }
        guard admissions.count == 1, let admission = admissions.first,
              policies.count == 1, let policy = policies.first,
              let capability = policy["capability"], UUID(uuidString: capability) != nil,
              policy["operation"] == operationID, admission["operation"] == operationID,
              admission["capability"] == capability, admission["connectionID"] == connectionID,
              let policyTime = policy["monotonicSeconds"].flatMap(Double.init),
              let admissionTime = admission["monotonicSeconds"].flatMap(Double.init),
              policyTime.isFinite, admissionTime.isFinite
        else {
            return nil
        }

        let times = [navigation, server, handoff, progress, readiness]
            .compactMap { $0["monotonicSeconds"].flatMap(Double.init) }
        let failed = runEvents.contains {
            $0["event"] == "slowKnownReadinessFailure"
                && $0["fixtureRequest"] == requestID
        }
        let earlyTerminalOrCleanup = runEvents.contains { event in
            guard event["runID"] == runID,
                  let eventTime = event["monotonicSeconds"].flatMap(Double.init),
                  let readyTime = readiness["monotonicSeconds"].flatMap(Double.init)
            else {
                return false
            }

            if ["writerFinished", "writerFailed", "nativeCancellationRequested", "pendingTransferCancelled"]
                .contains(event["event"] ?? "") {
                return event["operation"] == operationID && eventTime <= readyTime
            }
            return event["event"] == "cleanupRemoval"
                && event["operation"] == operationID && eventTime <= readyTime
        }
        let cleanupFailed = runEvents.contains {
            ($0["event"] == "scratchFailure" || $0["event"] == "cleanupInjectedFailure")
                && $0["operation"] == operationID
        }

        guard server["runID"] == runID, handoff["runID"] == runID,
              progress["runID"] == runID, readiness["runID"] == runID,
              UUID(uuidString: requestID) != nil,
              UUID(uuidString: operationID) != nil,
              UUID(uuidString: connectionID) != nil,
              server["route"] == route, server["requestParsed"] == "true",
              server["requestCount"] == "1", server["connectionCount"] == "1",
              server["sendStackState"] == "stackPrefixProcessed",
              server["responseComplete"] == "false", server["connectionClosed"] == "false",
              prefix > 0, prefix < expected,
              handoff["fixtureRoute"] == route, handoff["fixtureOrigin"] == "true",
              handoff["sameOrigin"] == "true",
              readiness["connectionID"] == connectionID,
              progress["expectedBytes"] == String(expected),
              readiness["serverExpectedBytes"] == String(expected),
              readiness["expectedBytes"] == String(expected),
              received > 0, received < expected,
              progress["receivedBytes"] == readiness["receivedBytes"],
              progress["operationGeneration"] == generation,
              progress["generation"] == generation,
              readiness["operationGeneration"] == generation,
              readiness["initialGeneration"] == generation,
              progress["activeWriterCount"] == "1", progress["recordCount"] == "1",
              readiness["activeWriterCount"] == "1", readiness["recordCount"] == "1",
              progress["authorizationValid"] == "true", readiness["authorizationValid"] == "true",
              progress["available"] == "true", readiness["available"] == "true",
              progress["isReady"] == "false", readiness["isReady"] == "false",
              progress["presentation"] == "none", readiness["presentation"] == "none",
              progress["privacyCleanupPending"] == "false",
              readiness["privacyCleanupPending"] == "false",
              readiness["responseComplete"] == "false", readiness["connectionClosed"] == "false",
              readiness["operation"] == operationID,
              times.count == 5, times.allSatisfy(\.isFinite),
              times[0] < policyTime, policyTime < times[2], times[2] < admissionTime, admissionTime < times[3],
              times[0] < times[1], times[0] < times[2], times[1] < times[4],
              times[2] < times[3], times[3] < times[4],
              elapsed > 0, elapsed <= 10_000,
              !failed, !earlyTerminalOrCleanup, !cleanupFailed
        else {
            return nil
        }

        return BrowserDownloadTransferWitness(
            runID: runID,
            route: route,
            requestID: requestID,
            operationID: operationID,
            connectionID: connectionID,
            generation: generation,
            elapsedMilliseconds: elapsed,
        )
    }

    /// Raw records retain their original numeric checks. Redacted receipts carry the same
    /// predicates as fixture-state proofs, without publishing byte counts while locked.
    static func continuationQuantitiesMatch(
        background: Observation,
        hidden: Observation,
        response: Observation,
        progress: Observation,
        readiness: Observation,
    ) -> Bool {
        let raw = containsQuantities([background, hidden, response, progress, readiness])
        return continuationOwnershipMatches(background: background, hidden: hidden, raw: raw)
            && responseBoundsMatch(response, readiness: readiness, raw: raw)
            && progressBoundsMatch(progress, response: response, raw: raw)
    }

    static func containsQuantities(_ events: [Observation]) -> Bool {
        let fields = [
            "expectedBytes",
            "prefixBytes",
            "remainderBytes",
            "receivedBytes",
            "activeWriterCount",
            "retainedRecordCount",
            "active",
            "retained",
            "requestCount",
            "connectionCount",
            "recordCount",
            "rowCount",
            "bytes",
            "temporaryBytes",
            "temporaryCount",
            "remaining",
            "serverExpectedBytes",
        ]
        return events.contains { event in fields.contains { event[$0] != nil } }
    }

    static func continuationOwnershipMatches(background: Observation, hidden: Observation, raw: Bool) -> Bool {
        if raw {
            return background["activeWriterCount"] == "1" && background["retainedRecordCount"] == "1"
                && hidden["activeWriterCount"] == "0" && hidden["retainedRecordCount"] == "1"
        }
        return background["oneActiveWriter"] == "true" && background["oneRetainedCompletion"] == "true"
            && hidden["noActiveWriters"] == "true" && hidden["oneRetainedCompletion"] == "true"
    }

    static func responseBoundsMatch(_ response: Observation, readiness: Observation, raw: Bool) -> Bool {
        guard raw else {
            return response["finiteResponseBoundsValid"] == "true"
        }
        guard let expected = Int(response["expectedBytes"] ?? ""),
              let prefix = Int(response["prefixBytes"] ?? ""),
              let remainder = Int(response["remainderBytes"] ?? "") else {
            return false
        }

        return expected > prefix && prefix > 0 && remainder == expected - prefix
            && response["expectedBytes"] == readiness["expectedBytes"]
    }

    static func progressBoundsMatch(_ progress: Observation, response: Observation, raw: Bool) -> Bool {
        guard raw else {
            return progress["nativeProgressBoundsValid"] == "true"
        }
        guard let expected = Int(response["expectedBytes"] ?? ""),
              let prefix = Int(response["prefixBytes"] ?? ""),
              let received = Int(progress["receivedBytes"] ?? "") else {
            return false
        }

        return received > prefix && received <= expected && progress["expectedBytes"] == String(expected)
    }

    static func delayedHandoffQuantitiesMatch(progress: Observation, hidden: Observation) -> Bool {
        if containsQuantities([progress, hidden]) {
            guard let received = Int(progress["receivedBytes"] ?? "") else {
                return false
            }

            return received > 0 && hidden["activeWriterCount"] == "0" && hidden["retainedRecordCount"] == "1"
        }
        return progress["progressPositive"] == "true" && hidden["noActiveWriters"] == "true"
            && hidden["oneRetainedCompletion"] == "true"
    }

    /// A released response and a native finish are independent witnesses. Both are required.
    static func continuationEvidence(
        from events: [Observation],
        for witness: BrowserDownloadTransferWitness,
    ) -> Observation? {
        guard events.count <= 256, witness.route == "finite-continuation" else {
            return nil
        }

        let run = events.filter { $0["runID"] == witness.runID }
        func selected(_ name: String) -> Observation? {
            let matches = run.filter {
                $0["event"] == name && $0["fixtureRequest"] == witness.requestID
                    && $0["operation"] == witness.operationID
                    && $0["connectionID"] == witness.connectionID
                    && (name != "qualificationScenePhaseChanged" || $0["phase"] == "background")
            }
            return matches.count == 1 ? matches.first : nil
        }
        guard let admission = selected("transferAdmitted"),
              let capability = admission["capability"], UUID(uuidString: capability) != nil,
              let policy = run.first(where: {
                  $0["event"] == "policyDownloadAdmitted" && $0["capability"] == capability
                      && $0["fixtureRequest"] == witness.requestID
              }),
              let handoff = run.first(where: {
                  $0["event"] == "nativeDownloadHandoff" && $0["fixtureRequest"] == witness.requestID
              }),
              let readiness = selected("slowKnownReadiness"),
              let background = selected("qualificationScenePhaseChanged"),
              let release = selected("finiteResponseReleaseRequested"),
              let response = selected("finiteResponseCompleted"),
              let finish = selected("writerFinished"),
              let progress = selected("nativePostLockProgress"),
              let hidden = selected("hiddenCompletion")
        else {
            return nil
        }

        let milestones = [policy, admission, handoff, readiness, background, release, response, finish, hidden]
        let times = milestones.compactMap { $0["monotonicSeconds"].flatMap(Double.init) }
        guard times.count == milestones.count, times.allSatisfy(\.isFinite),
              times[0] < times[2], times[2] < times[1], times[1] < times[3],
              times[3] < times[4], times[4] < times[5], times[5] < times[6],
              times[5] < times[7], times[7] < times[8],
              background["phase"] == "background", background["authorizationRevokedSynchronously"] == "true",
              background["contentEmpty"] == "true", background["available"] == "false",
              background["authenticated"] == "false",
              let generationBefore = UInt64(background["generationBefore"] ?? ""),
              let generation = UInt64(background["generation"] ?? ""),
              let initial = UInt64(witness.generation), generationBefore >= initial,
              generation > generationBefore,
              response["sendStackState"] == "stackProcessed",
              let releaseTime = response["releaseMonotonicSeconds"].flatMap(Double.init),
              releaseTime.isFinite, times[5] <= releaseTime, releaseTime <= times[6],
              progress["authenticated"] == "false",
              progress["available"] == "false", progress["capability"] == capability,
              let callbackTime = progress["callbackMonotonicSeconds"].flatMap(Double.init),
              callbackTime.isFinite, callbackTime > releaseTime,
              continuationQuantitiesMatch(
                  background: background,
                  hidden: hidden,
                  response: response,
                  progress: progress,
                  readiness: readiness,
              ),
              [release, response, finish, hidden].allSatisfy({ $0["capability"] == capability }),
              hidden["contentEmpty"] == "true", hidden["available"] == "false",
              hidden["authenticated"] == "false",
              !run.contains(where: {
                  [
                      "nativeCancellationRequested",
                      "writerCancellationAcknowledged",
                      "writerFailed",
                      "cleanupRemoval",
                  ]
                  .contains($0["event"] ?? "") && $0["operation"] == witness.operationID
              })
        else {
            return nil
        }

        return hidden
    }

    /// Policy admission alone cannot satisfy this contract: native handoff and finish must follow Lock.
    static func delayedHandoffEvidence(_ events: [Observation]) -> Observation? {
        guard events.count <= 256 else {
            return nil
        }

        let navigations = events.filter {
            $0["event"] == "fixtureNavigationRequested" && $0["fixtureRoute"] == "delayed-handoff"
        }
        guard navigations.count == 1, let navigation = navigations.first,
              let runID = navigation["runID"], let request = navigation["fixtureRequest"] else {
            return nil
        }

        let run = events.filter { $0["runID"] == runID && $0["fixtureRequest"] == request }
        func one(_ event: String) -> Observation? {
            let matches = run.filter { $0["event"] == event }
            return matches.count == 1 ? matches.first : nil
        }
        guard let policy = one("policyDownloadAdmitted"), let locked = one("pendingPolicyLockApplied"),
              let handoff = one("nativeDownloadHandoff"), let admitted = one("transferAdmitted"),
              let finished = one("writerFinished"), let hidden = one("hiddenCompletion"),
              let progress = one("nativePostLockProgress"),
              let operation = admitted["operation"], UUID(uuidString: operation) != nil,
              let capability = policy["capability"], UUID(uuidString: capability) != nil,
              let connection = admitted["connectionID"], UUID(uuidString: connection) != nil
        else {
            return nil
        }

        let milestones = [navigation, policy, locked, handoff, admitted, finished, hidden]
        let times = milestones.compactMap { $0["monotonicSeconds"].flatMap(Double.init) }
        guard times.count == milestones.count, times.allSatisfy(\.isFinite),
              zip(times, times.dropFirst()).allSatisfy({ pair in pair.0 < pair.1 }),
              locked["authenticated"] == "false", locked["available"] == "false", locked["contentEmpty"] == "true",
              let before = UInt64(locked["generationBefore"] ?? ""),
              let after = UInt64(locked["generation"] ?? ""), after > before,
              handoff["sameOrigin"] == "true", handoff["fixtureOrigin"] == "true",
              handoff["fixtureRoute"] == "delayed-handoff",
              [policy, locked, admitted, finished, hidden].allSatisfy({
                  $0["operation"] == operation && $0["capability"] == capability && $0["connectionID"] == connection
              }),
              progress["operation"] == operation, progress["capability"] == capability,
              progress["connectionID"] == connection, progress["authenticated"] == "false",
              progress["available"] == "false",
              SlowKnownWitnessContract.delayedHandoffQuantitiesMatch(progress: progress, hidden: hidden),
              let progressTime = progress["callbackMonotonicSeconds"].flatMap(Double.init),
              progressTime.isFinite, progressTime > times[2],
              hidden["authenticated"] == "false", hidden["available"] == "false", hidden["contentEmpty"] == "true",
              !events.contains(where: {
                  $0["runID"] == runID && $0["operation"] == operation
                      && ["nativeCancellationRequested", "pendingTransferCancelled", "writerFailed", "cleanupRemoval"]
                      .contains($0["event"] ?? "")
              })
        else {
            return nil
        }

        return hidden
    }
}
