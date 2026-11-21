//
//  BrowserDownloadSceneEvidence.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import CoreFoundation
import CoreGraphics
import Foundation

/// Reads scene census and coordinator samples captured by the qualification host.
enum BrowserDownloadSceneEvidence {
    typealias Observation = [String: String]

    struct SceneCensus: Codable, Equatable {
        let capturedMonotonicSeconds: String
        let distinctSessionIDs: Int
        let rootLayoutObservations: [Observation]
        let connectedWindowScenes: [WindowScene]
        let latestCoordinatorObservations: [Observation]
        var ownerSnapshot: Observation? = nil
        var liveRegisteredRoots: [Observation]? = nil
    }

    struct ActiveRootTarget {
        let runID: String
        let originalSceneID: String
        let sceneID: String
        let requestedAt: Double
        let initial: SceneCensus

        func registrations(in census: SceneCensus) -> Set<String> {
            Set(census.latestCoordinatorObservations.compactMap { observation in
                guard observation["runID"] == runID, observation["sceneSession"] == sceneID,
                      let registration = observation["registration"], !registration.isEmpty
                else {
                    return nil
                }

                return registration
            })
        }
    }

    struct LiveRoot {
        let registration: String
        let sceneID: String
        let generation: String
        let revision: UInt64
        let isMounted: Bool
        let safe: Bool

        init?(_ row: Observation, runID: String, scenes: [WindowScene]) {
            guard row["runID"] == runID,
                  let id = row["registration"], UUID(uuidString: id) != nil,
                  let session = row["sceneSession"], !session.isEmpty,
                  let scene = scenes.first(where: { $0.sessionID == session }),
                  row["activation"] == scene.activationRawValue,
                  let ownerGeneration = row["generation"], UInt64(ownerGeneration).map(String.init) == ownerGeneration,
                  let revisionText = row["renderRevision"], let renderRevision = UInt64(revisionText),
                  String(renderRevision) == revisionText,
                  let mounted = row["mounted"].flatMap(Bool.init),
                  let active = row["registrationActive"].flatMap(Bool.init),
                  let confirmed = row["renderConfirmed"].flatMap(Bool.init),
                  let proof = row["rootProof"].flatMap(Bool.init),
                  let barrier = row["nativeBarrier"].flatMap(Bool.init),
                  let cover = row["coverPresent"].flatMap(Bool.init),
                  let visible = row["coverVisible"].flatMap(Bool.init),
                  !visible || cover
            else {
                return nil
            }

            registration = id
            sceneID = session
            generation = ownerGeneration
            revision = renderRevision
            isMounted = mounted
            safe = mounted && active && scene.activation == "foregroundActive" && scene.activationRawValue == "0"
                && confirmed && proof && !barrier && !cover
        }
    }

    /// One connected UIKit window scene as recorded by the qualification host census.
    struct WindowScene: Codable, Equatable {
        let sessionID: String
        let activation: String
        let activationRawValue: String
        let bounds: String
        let screenBounds: String
        let windows: [SceneWindow]
    }

    /// Geometry of one UIWindow attached to a connected scene, exactly as the host recorded it.
    /// `hidden` and `alpha` describe on-screen visibility, and `rootViewBounds` is the loaded
    /// root view's bounds, or the host's `"unloaded"` placeholder before the view is loaded.
    struct SceneWindow: Codable, Equatable {
        let frame: String
        let bounds: String
        let hidden: String
        let alpha: String
        let key: String
        let isCover: String
        let rootViewBounds: String
    }

    /// Resolves SpringBoard's physical resize-handle frame into the supplied window
    /// container's coordinate space. Some physical devices expose an otherwise hittable handle
    /// in rotated axes. Directly visible frames remain untouched; rotated frames are
    /// accepted only when their transformed center lands on the container's
    /// bottom-right corner. The rotation uses the physical screen origin because
    /// SpringBoard reports both frames in screen coordinates. Invalid or unrelated
    /// offscreen frames remain rejected.
    static func normalizedResizeHandleFrame(
        reported: CGRect,
        container: CGRect,
        screenBounds: CGRect,
    ) -> CGRect? {
        guard isFiniteResizeFrame(reported), isFiniteResizeFrame(container) else {
            return nil
        }

        let direct = reported.intersection(container)
        if !direct.isNull, !direct.isEmpty {
            return reported
        }
        guard isFiniteResizeFrame(screenBounds), screenBounds.width > screenBounds.height else {
            return nil
        }

        let transformed = CGRect(
            x: screenBounds.minX + reported.minY,
            y: screenBounds.maxY - reported.maxX,
            width: reported.height,
            height: reported.width,
        )
        let cornerDistance = hypot(
            transformed.midX - container.maxX,
            transformed.midY - container.maxY,
        )
        let transformedVisible = transformed.intersection(container)
        guard cornerDistance <= 1,
              !transformedVisible.isNull,
              !transformedVisible.isEmpty
        else {
            return nil
        }

        return transformed
    }

    /// Chooses each resize axis independently so the drag can move outward when the window has
    /// room and inward when it does not. The returned delta is rejected when its destination would
    /// leave the screen, or would leave the card on an axis that shrinks the window.
    static func resizeGestureDelta(
        from start: CGPoint,
        container: CGRect,
        screenBounds: CGRect,
    ) -> CGVector? {
        guard [start.x, start.y].allSatisfy(\.isFinite),
              isFiniteResizeFrame(container),
              isFiniteResizeFrame(screenBounds)
        else {
            return nil
        }

        let quarterWidth = container.width / 4
        let quarterHeight = container.height / 4
        let dx = screenBounds.maxX - container.maxX >= quarterWidth ? quarterWidth : -quarterWidth
        let dy = screenBounds.maxY - container.maxY >= quarterHeight ? quarterHeight : -quarterHeight
        let destination = CGPoint(x: start.x + dx, y: start.y + dy)

        guard destination.x >= screenBounds.minX,
              destination.x <= screenBounds.maxX,
              destination.y >= screenBounds.minY,
              destination.y <= screenBounds.maxY,
              dx >= 0 || (destination.x >= container.minX && destination.x <= container.maxX),
              dy >= 0 || (destination.y >= container.minY && destination.y <= container.maxY)
        else {
            return nil
        }

        return CGVector(dx: dx, dy: dy)
    }

    static func isFiniteResizeFrame(_ frame: CGRect) -> Bool {
        !frame.isNull && !frame.isEmpty
            && [frame.minX, frame.minY, frame.width, frame.height].allSatisfy(\.isFinite)
    }

    /// Parses the host's `String(describing:)` rectangle format, for example
    /// `"(0.0, 0.0, 523.0, 813.0)"`. Returns `nil` for any other input, including the host's
    /// `"unloaded"` placeholder for a window root view that has never been loaded.
    static func parsedRect(_ description: String) -> CGRect? {
        let stripped = description.trimmingCharacters(in: CharacterSet(charactersIn: "() "))
        let parts = stripped.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 4,
              let x = Double(parts[0]), let y = Double(parts[1]),
              let width = Double(parts[2]), let height = Double(parts[3]),
              [x, y, width, height].allSatisfy(\.isFinite)
        else {
            return nil
        }

        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// Compares rectangles parsed from host descriptions. Both sides round-trip through the same
    /// decimal string format, so a difference beyond a sub-point epsilon is a real change.
    static func rectsMatch(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        abs(lhs.origin.x - rhs.origin.x) < 0.001
            && abs(lhs.origin.y - rhs.origin.y) < 0.001
            && abs(lhs.size.width - rhs.size.width) < 0.001
            && abs(lhs.size.height - rhs.size.height) < 0.001
    }

    /// Selects the one visible keyed content window while allowing a visible non-keyed
    /// auxiliary window. A visible coordinator-owned cover invalidates the scene.
    static func selectedVisibleKeyedSceneWindow(in scene: WindowScene) -> SceneWindow? {
        let visibleWindows = scene.windows.filter { window in
            window.hidden == "false" && (Double(window.alpha) ?? 0) > 0
        }
        guard !visibleWindows.contains(where: { $0.isCover == "true" }) else {
            return nil
        }

        let keyedWindows = visibleWindows.filter { $0.key == "true" }
        return keyedWindows.count == 1 ? keyedWindows.first : nil
    }

    /// Returns the unique scene created by the request when it is foreground-active and
    /// has a same-run mounted coordinator registration. Pre-existing scenes may remain
    /// foreground-active on platforms that host multiple active windows.
    static func uniqueNewActiveScene(
        _ census: SceneCensus,
        baselineSessionIDs: Set<String>,
        runID: String,
    ) -> WindowScene? {
        let sessionIDs = census.connectedWindowScenes.map(\.sessionID)
        let distinctSessionIDs = Set(sessionIDs)
        guard distinctSessionIDs.count >= 2,
              sessionIDs.count == distinctSessionIDs.count,
              distinctSessionIDs.count == census.distinctSessionIDs
        else {
            return nil
        }

        let newSessionIDs = distinctSessionIDs.subtracting(baselineSessionIDs)
        guard newSessionIDs.count == 1, let newSessionID = newSessionIDs.first else {
            return nil
        }

        let newScenes = census.connectedWindowScenes.filter { newSessionIDs.contains($0.sessionID) }
        guard newScenes.count == 1,
              newScenes[0].activation == "foregroundActive",
              census.latestCoordinatorObservations.contains(where: {
                  $0["runID"] == runID
                      && $0["registration"]?.isEmpty == false
                      && $0["sceneSession"] == newSessionID
                      && $0["mounted"] == "true"
              })
        else {
            return nil
        }

        return newScenes[0]
    }

    static func diagnosticValue(_ read: () throws -> String) -> String {
        (try? read()) ?? "unavailable"
    }

    /// Returns the most recent gesture-boundary event for the exact run, scene, and
    /// mounted Root registration. Keeping all three identities prevents an older active
    /// window from satisfying the selected new scene's boundary wait.
    static func resizeGestureMarker(
        in observations: [Observation],
        sceneID: String,
        registration: String,
        runID: String,
    ) -> Observation? {
        observations.last {
            $0["event"] == "resizeGestureWillBegin"
                && $0["runID"] == runID
                && $0["sceneSession"] == sceneID
                && $0["registration"] == registration
        }
    }

    /// The foreground-active scene from the census together with its most recent safe Root layout
    /// confirmation in this run, or `nil` while either is missing. A confirmation counts as safe
    /// baseline evidence only when the host recorded `rootProof` as `"true"` with no visible
    /// privacy cover and no native barrier for the same scene and run.
    static func activeSceneSafeRoot( // swiftlint:disable:this unused_declaration
        in census: SceneCensus,
        for sessionID: String,
        runID: String,
    ) -> (scene: WindowScene, confirmation: Observation)? {
        guard let scene = census.connectedWindowScenes.first(where: {
            $0.sessionID == sessionID && $0.activation == "foregroundActive"
        }) else {
            return nil
        }
        guard let confirmation = census.rootLayoutObservations.last(where: {
            $0["event"] == "rootLayoutConfirmed" && $0["runID"] == runID
                && $0["sceneSession"] == scene.sessionID && $0["rootProof"] == "true"
                && $0["coverVisible"] == "false" && $0["nativeBarrier"] == "false"
        }) else {
            return nil
        }

        return (scene, confirmation)
    }

    /// Returns the last foreground activation in the original scene and run after the request.
    /// UIKit records a did-activate notification for every registered scene, so both scene
    /// identity and the foreground-active activation value are required.
    static func finalSceneActivation(
        in observations: [Observation],
        originalSceneID: String,
        runID: String,
        after requestedAt: Double,
    ) -> Observation? {
        observations.last {
            guard $0["runID"] == runID,
                  $0["event"] == "UISceneDidActivateNotification",
                  $0["sceneSession"] == originalSceneID,
                  $0["activation"] == "0",
                  let observedAt = $0["monotonicSeconds"].flatMap({ Double($0) })
            else {
                return false
            }

            return observedAt.isFinite && observedAt > requestedAt
        }
    }

    /// Returns the owner generation represented by the final census's latest original-scene
    /// coordinator observation. The newest relevant observation is selected before its safety
    /// and generation are evaluated, so a newer unsafe observation cannot be hidden by an
    /// older safe one. Only one safe generation at the latest timestamp is accepted.
    static func finalCensusSafeRootGeneration(
        in census: SceneCensus,
        originalSceneID: String,
        runID: String,
        atOrAfter minimumMonotonicSeconds: Double,
    ) -> String? {
        guard let capturedAt = Double(census.capturedMonotonicSeconds), capturedAt.isFinite else {
            return nil
        }

        let observations = census.latestCoordinatorObservations.compactMap { observation -> (
            Double,
            Observation,
        )? in
            guard observation["runID"] == runID,
                  observation["sceneSession"] == originalSceneID,
                  let observedAt = observation["monotonicSeconds"].flatMap({ Double($0) })
            else {
                return nil
            }
            guard observedAt.isFinite,
                  observedAt >= minimumMonotonicSeconds,
                  observedAt <= capturedAt
            else {
                return nil
            }

            return (observedAt, observation)
        }
        guard let latestObservedAt = observations.map(\.0).max() else {
            return nil
        }

        let latestObservations = observations
            .filter { $0.0 == latestObservedAt }
        guard latestObservations.allSatisfy({ coordinatorObservationIsSafeRoot($0.1) }) else {
            return nil
        }

        let latestGenerations = latestObservations.compactMap { $0.1["generation"].flatMap { $0.isEmpty ? nil : $0 } }
        guard latestGenerations.count == latestObservations.count,
              let generation = latestGenerations.first,
              latestGenerations.allSatisfy({ $0 == generation })
        else {
            return nil
        }

        return generation
    }

    /// Availability is true only when every registered scene represented by the final census is
    /// foreground-active. Missing, duplicate or additional registered scenes cannot establish a
    /// complete availability result.
    static func registeredSceneActivationsAreForegroundActive(
        in census: SceneCensus,
        registeredSessions: Set<String>,
    ) -> Bool {
        let registeredScenes = census.connectedWindowScenes.filter { registeredSessions.contains($0.sessionID) }
        return !registeredSessions.isEmpty
            && registeredScenes.count == registeredSessions.count
            && registeredScenes.allSatisfy { $0.activation == "foregroundActive" }
    }

    /// Returns the newest coordinator observation for each registration at or after a census.
    /// Equal timestamps resolve to unsafe Root evidence, so array order cannot hide a barrier.
    static func latestCoordinatorObservationsByRegistration(
        in observations: [Observation],
        runID: String,
        atOrAfter minimumMonotonicSeconds: Double,
    ) -> [Observation] {
        var latestByRegistration: [String: (observedAt: Double, observation: Observation)] = [:]
        for observation in observations {
            guard observation["runID"] == runID,
                  let registration = observation["registration"], !registration.isEmpty,
                  let observedAt = observation["monotonicSeconds"].flatMap({ Double($0) }),
                  observedAt.isFinite,
                  observedAt >= minimumMonotonicSeconds
            else {
                continue
            }
            guard let latest = latestByRegistration[registration] else {
                latestByRegistration[registration] = (observedAt, observation)
                continue
            }

            let equalTimeRejectsSafeEvidence = observedAt == latest.observedAt
                && !coordinatorObservationIsSafeRoot(observation)
                && coordinatorObservationIsSafeRoot(latest.observation)
            if observedAt > latest.observedAt || equalTimeRejectsSafeEvidence {
                latestByRegistration[registration] = (observedAt, observation)
            }
        }

        return latestByRegistration.keys.sorted().compactMap { latestByRegistration[$0]?.observation }
    }

    /// Returns the latest post-census Root for every registration of a scene only when all are safe.
    static func latestFreshSafeRoots(
        in observations: [Observation],
        sceneID: String,
        registrations: Set<String>,
        runID: String,
        atOrAfter minimumMonotonicSeconds: Double,
    ) -> [Observation]? {
        let matching = latestCoordinatorObservationsByRegistration(
            in: observations,
            runID: runID,
            atOrAfter: minimumMonotonicSeconds,
        ).filter {
            $0["sceneSession"] == sceneID && registrations.contains($0["registration"] ?? "")
        }
        let observedRegistrations = Set(matching.compactMap { $0["registration"] })
        guard !registrations.isEmpty,
              observedRegistrations == registrations,
              matching.allSatisfy(coordinatorObservationIsSafeRoot)
        else {
            return nil
        }

        return matching
    }

    static func coordinatorObservationIsSafeRoot(_ observation: Observation) -> Bool {
        observation["rootProof"] == "true"
            && observation["coverVisible"] == "false"
            && observation["nativeBarrier"] == "false"
    }

    /// Every cached registration must still exist in the live coordinator under the same identity.
    static func liveRoots(in census: SceneCensus, runID: String) -> [String: LiveRoot]? {
        guard UUID(uuidString: runID) != nil, let rows = census.liveRegisteredRoots, !rows.isEmpty,
              rows.count == census.latestCoordinatorObservations.count else {
            return nil
        }

        var roots: [String: LiveRoot] = [:]
        for row in rows {
            guard let root = LiveRoot(row, runID: runID, scenes: census.connectedWindowScenes),
                  roots.updateValue(root, forKey: root.registration) == nil else {
                return nil
            }
        }
        var seen: Set<String> = []
        for row in census.latestCoordinatorObservations {
            guard row["runID"] == runID, let registration = row["registration"],
                  let root = roots[registration], row["sceneSession"] == root.sceneID,
                  seen.insert(registration).inserted else {
                return nil
            }
        }
        return roots
    }

    /// Pairs each foreground registration's latest callback with its live revision and the actual windows.
    /// An equal-token update can invalidate a revision while its last callback still reports a safe Root.
    static func liveConfirmedRoots(
        in census: SceneCensus,
        sceneID: String,
        runID: String,
        atOrAfter minimumTime: Double,
    ) -> [Observation]? {
        let sessions = census.connectedWindowScenes.map(\.sessionID)
        guard Set(sessions).count == sessions.count, sessions.count == census.distinctSessionIDs,
              let scene = census.connectedWindowScenes.first(where: { $0.sessionID == sceneID }),
              scene.activation == "foregroundActive", scene.activationRawValue == "0",
              !scene.windows.isEmpty, scene.windows.allSatisfy({ $0.isCover == "false" }),
              let capturedAt = Double(census.capturedMonotonicSeconds), capturedAt.isFinite,
              let generation = census.ownerSnapshot?["generation"],
              let live = liveRoots(in: census, runID: runID) else {
            return nil
        }

        let registrations = Set(live.values.filter { $0.sceneID == sceneID }.map(\.registration))
        guard let callbacks = latestFreshSafeRoots(
            in: census.latestCoordinatorObservations,
            sceneID: sceneID,
            registrations: registrations,
            runID: runID,
            atOrAfter: minimumTime,
        ), callbacks.allSatisfy({ callback in
            guard let id = callback["registration"], let root = live[id],
                  let observedAt = callback["monotonicSeconds"].flatMap(Double.init) else {
                return false
            }

            return root.safe && root.generation == generation && callback["generation"] == generation
                && callback["renderRevision"] == String(root.revision) && callback["mounted"] == "true"
                && callback["activation"] == scene.activationRawValue && observedAt <= capturedAt
        }) else {
            return nil
        }

        return callbacks
    }

    /// Requires the independent event ledger to agree with the live proof for every pinned registration.
    static func confirmedRoots(
        in census: SceneCensus,
        observations: [Observation],
        target: ActiveRootTarget,
    ) -> [Observation]? {
        let registrations = target.registrations(in: target.initial)
        guard let initialAt = Double(target.initial.capturedMonotonicSeconds), initialAt.isFinite,
              initialAt >= target.requestedAt,
              let capturedAt = Double(census.capturedMonotonicSeconds), capturedAt.isFinite, capturedAt > initialAt,
              let scene = uniqueNewActiveScene(
                  census,
                  baselineSessionIDs: [target.originalSceneID],
                  runID: target.runID,
              ),
              scene.sessionID == target.sceneID,
              census.connectedWindowScenes
              .first(where: { $0.sessionID == target.originalSceneID })?
              .activation == "background",
              target.registrations(in: census) == registrations,
              let roots = liveConfirmedRoots(
                  in: census,
                  sceneID: target.sceneID,
                  runID: target.runID,
                  atOrAfter: target.requestedAt,
              ),
              let initialRoots = liveRoots(in: target.initial, runID: target.runID)
        else {
            return nil
        }

        let latestEvents = latestCoordinatorObservationsByRegistration(
            in: observations,
            runID: target.runID,
            atOrAfter: target.requestedAt,
        )
        let ledgerRegistrations = Set(latestEvents.filter {
            $0["sceneSession"] == target.sceneID && $0["mounted"] == "true"
        }
        .compactMap { $0["registration"] })
        guard ledgerRegistrations == registrations,
              latestFreshSafeRoots(
                  in: latestEvents,
                  sceneID: target.sceneID,
                  registrations: registrations,
                  runID: target.runID,
                  atOrAfter: target.requestedAt,
              ) == roots,
              roots.allSatisfy({ root in
                  guard let registration = root["registration"],
                        let revision = root["renderRevision"].flatMap(UInt64.init),
                        let previousLive = initialRoots[registration], revision >= previousLive.revision,
                        let observedAt = root["monotonicSeconds"].flatMap(Double.init), observedAt <= capturedAt,
                        let initial = target.initial.latestCoordinatorObservations.first(where: {
                            $0["runID"] == target.runID && $0["sceneSession"] == target.sceneID
                                && $0["registration"] == root["registration"]
                        }),
                        let previousAt = initial["monotonicSeconds"].flatMap(Double.init),
                        previousAt.isFinite, previousAt <= initialAt, observedAt >= previousAt
                  else {
                      return false
                  }

                  let alreadyConfirmed = previousLive.safe && previousLive.generation == root["generation"]
                      && previousLive.revision == revision && initial["renderRevision"] == root["renderRevision"]
                      && coordinatorObservationIsSafeRoot(initial)
                  return alreadyConfirmed || observedAt > initialAt
              })
        else {
            return nil
        }

        return roots
    }

    /// Read the ledger after the census so it includes cleanup recorded during the window scan.
    /// A later removal of the retained allocation also disqualifies the sample.
    static func postRequestSceneEvidence(
        runID: String,
        requestedAt: Double,
        readCensus: () -> SceneCensus?,
        readLedger: () -> [Observation]?,
    ) -> (census: SceneCensus, events: [Observation])? {
        guard let census = readCensus(), let ledger = readLedger() else {
            return nil
        }

        let events = ledger.filter {
            $0["runID"] == runID && ($0["monotonicSeconds"].flatMap(Double.init) ?? -1) >= requestedAt
        }
        return (census, events)
    }

    static func recordedRemoval(of allocation: String, in events: [Observation], runID: String) -> Bool {
        events.contains { $0["runID"] == runID && $0["event"] == "cleanupRemoval" && $0["operation"] == allocation }
    }

    static func retainedOwnerIsRevoked(
        in census: SceneCensus,
        observations: [Observation],
        atOrAfter requestedAt: Double,
    ) -> Bool {
        guard let current = census.ownerSnapshot, let generation = current["generation"],
              let latest = observations.last(where: { $0["event"] == "ownerSnapshot" }),
              latest["generation"] == generation,
              let observedAt = latest["monotonicSeconds"].flatMap(Double.init),
              let start = current["sampleStartedMonotonicSeconds"].flatMap(Double.init),
              let end = current["sampleCompletedMonotonicSeconds"].flatMap(Double.init),
              let capturedAt = Double(census.capturedMonotonicSeconds),
              start.isFinite, end.isFinite, capturedAt.isFinite, observedAt.isFinite,
              requestedAt <= observedAt, observedAt <= capturedAt,
              requestedAt <= start, start <= end, end <= capturedAt
        else {
            return false
        }

        let expected = [
            "available": "false",
            "retained": "1",
            "active": "0",
            "operations": "",
            "presentation": "none",
            "cleanupRetry": "false",
        ]
        return expected.allSatisfy { key, value in current[key] == value && latest[key] == value }
    }

    /// `nil` when a census captured after the resize gesture shows the active scene session still
    /// foreground-active with new bounds and exactly one visible attached window whose frame,
    /// bounds, and loaded root view bounds match the new scene bounds. The window selector also
    /// rejects every visible window identified as a privacy cover. This is the retry predicate for
    /// `refreshCensus`, so the caller keeps the last returned reason as its timeout diagnosis. A
    /// real system resize does not change the SwiftUI render token that governs
    /// `rootLayoutConfirmed`, so this witness uses current scene-window cover evidence instead of a
    /// new coordinator observation.
    static func resizedSceneWitnessFailure(
        _ census: SceneCensus,
        activeSceneID: String,
        baselineBounds: String,
    ) -> String? {
        guard let baseline = parsedRect(baselineBounds) else {
            return "the pre-gesture baseline bounds are not parseable"
        }
        guard let scene = census.connectedWindowScenes.first(where: { $0.sessionID == activeSceneID }) else {
            return "the active scene session \(activeSceneID) is no longer connected"
        }
        guard scene.activation == "foregroundActive" else {
            return "the active scene session is no longer foreground-active"
        }
        guard let resizedBounds = parsedRect(scene.bounds) else {
            return "the resized scene bounds are not parseable"
        }
        guard !rectsMatch(resizedBounds, baseline) else {
            return "the scene bounds still match the pre-gesture baseline"
        }
        guard let window = selectedVisibleKeyedSceneWindow(in: scene) else {
            return "the scene does not have exactly one visible keyed non-cover window"
        }
        guard let windowFrame = parsedRect(window.frame), rectsMatch(windowFrame, resizedBounds) else {
            return "the attached window frame does not match the resized scene bounds"
        }
        guard let windowBounds = parsedRect(window.bounds), rectsMatch(windowBounds, resizedBounds) else {
            return "the attached window bounds do not match the resized scene bounds"
        }
        guard let rootViewBounds = parsedRect(window.rootViewBounds), rectsMatch(rootViewBounds, resizedBounds) else {
            return "the loaded root view bounds do not match the resized scene bounds"
        }

        return nil
    }

    /// Pins the new scene once its mounted registrations appear in both the live query and callback cache.
    /// Its render revision can still be awaiting layout at this point.
    static func hasCoherentMountedScene(
        _ census: SceneCensus,
        originalSceneID: String,
        runID: String,
        requiringOriginalBackground: Bool,
    ) -> Bool {
        guard let scene = uniqueNewActiveScene(census, baselineSessionIDs: [originalSceneID], runID: runID),
              let original = census.connectedWindowScenes.first(where: { $0.sessionID == originalSceneID }),
              !requiringOriginalBackground || original.activation == "background",
              let capturedAt = Double(census.capturedMonotonicSeconds), capturedAt.isFinite,
              let roots = liveRoots(in: census, runID: runID) else {
            return false
        }

        return census.latestCoordinatorObservations.allSatisfy { callback in
            guard let id = callback["registration"], let live = roots[id],
                  callback["mounted"] == String(live.isMounted),
                  let observedAt = callback["monotonicSeconds"].flatMap(Double.init),
                  observedAt.isFinite, observedAt <= capturedAt else {
                return false
            }

            return live.sceneID != scene.sessionID || live.isMounted
        }
    }

    static func latestPassiveSceneCensus(in snapshots: [SceneCensus]) -> SceneCensus? {
        let timedSnapshots = snapshots.compactMap { census -> (Double, SceneCensus)? in
            guard let timestamp = Double(census.capturedMonotonicSeconds), timestamp.isFinite else {
                return nil
            }

            return (timestamp, census)
        }
        guard let latestTimestamp = timedSnapshots.map(\.0).max() else {
            return nil
        }

        let latestSnapshots = timedSnapshots.filter { $0.0 == latestTimestamp }.map(\.1)
        guard let first = latestSnapshots.first, latestSnapshots.allSatisfy({ $0 == first }) else {
            return nil
        }

        return first
    }

    /// Returns the latest owner snapshot for the run and generation whose finite timestamp lies
    /// within the inclusive activation-to-census interval. Equal timestamps prefer the later
    /// appended observation so selection remains deterministic.
    static func latestOwnerSnapshot(
        in observations: [Observation],
        runID: String,
        atOrAfter minimumMonotonicSeconds: Double,
        atOrBefore maximumMonotonicSeconds: Double,
        generation: String,
    ) -> Observation? {
        guard minimumMonotonicSeconds.isFinite, maximumMonotonicSeconds.isFinite else {
            return nil
        }

        let candidates = observations.enumerated().compactMap { index, observation -> (Double, Int, Observation)? in
            guard observation["runID"] == runID,
                  observation["event"] == "ownerSnapshot",
                  observation["generation"] == generation,
                  let observedAt = observation["monotonicSeconds"].flatMap({ Double($0) }),
                  observedAt.isFinite,
                  observedAt >= minimumMonotonicSeconds,
                  observedAt <= maximumMonotonicSeconds
            else {
                return nil
            }

            return (observedAt, index, observation)
        }
        return candidates.max { lhs, rhs in
            if lhs.0 == rhs.0 {
                return lhs.1 < rhs.1
            }
            return lhs.0 < rhs.0
        }?.2
    }

    static func withinDeadline(
        _ deadline: TimeInterval,
        now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        evaluate: () -> Bool,
    ) -> Bool {
        guard now() < deadline else {
            return false
        }

        return evaluate() && now() < deadline
    }
}
