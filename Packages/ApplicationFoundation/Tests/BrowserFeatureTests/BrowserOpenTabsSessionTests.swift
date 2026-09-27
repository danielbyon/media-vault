//
//  BrowserOpenTabsSessionTests.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import ComposableArchitecture
import ConcurrencyExtras
@preconcurrency import Foundation
import Testing
@testable import BrowserFeature

@Suite("Browser open-tabs session projection and persistence")
struct BrowserOpenTabsSessionTests {
    @Test("Projection prefers committed provenance and omits non-web content")
    func projectionUsesCommittedURLBeforeRecoveryURL() throws {
        let committed = try #require(URL(string: "https://committed.example/path"))
        let requested = try #require(URL(string: "https://requested.example"))
        let terminated = try #require(URL(string: "https://terminated.example"))
        let failed = try #require(URL(string: "https://failed.example"))
        let invalid = try #require(URL(string: "file:///private/page"))
        let startID = BrowserTabID()
        let committedID = BrowserTabID()
        let terminatedID = BrowserTabID()
        let failedID = BrowserTabID()
        let invalidID = BrowserTabID()
        let tabs = [
            .startPage(id: startID),
            BrowserTab(
                id: committedID,
                content: .error(.pageCouldNotLoad(failed)),
                metadata: .init(committedURL: committed),
            ),
            BrowserTab(
                id: terminatedID,
                content: .terminated(lastCommittedURL: terminated),
            ),
            BrowserTab(id: failedID, content: .error(.connectionFailed(failed))),
            BrowserTab(id: invalidID, content: .web(requestedURL: invalid)),
        ]

        let session = try #require(BrowserOpenTabsSession.project(from: tabs, selectedTabID: committedID))

        #expect(session.entries.map(\.position) == [0, 1, 2, 3])
        #expect(session.entries[0].kind == .startPage)
        #expect(session.entries[1].kind == .web(committed))
        #expect(session.entries[2].kind == .web(terminated))
        #expect(session.entries[3].kind == .web(failed))
        #expect(session.selectedEntryPosition == 1)
        #expect(!session.entries.contains(where: { $0.kind == .web(requested) }))
    }

    @Test("Decoder salvages each valid entry and selects the earlier nearest survivor")
    func decoderSalvagesMalformedEntries() throws {
        let data = Data(
            #"""
            {"version":1,"selectedPosition":2,"entries":[{"position":0,"kind":"startPage"},{"position":1,"kind":"future"},{"position":4,"kind":"web","url":"https://four.example"},{"position":8,"kind":"web","url":"file:///private/page"}]}
            """#.utf8,
        )

        let session = try #require(BrowserOpenTabsSession.decode(data))

        #expect(session.entries.map(\.position) == [0, 4])
        #expect(session.selectedEntryPosition == 0)
        #expect(try session.entries[1].kind == .web(#require(URL(string: "https://four.example"))))
    }

    @Test("Restoration creates fresh ordinary tabs and tracks background web URLs")
    func restorationCreatesFreshIDsAndLazyBackgroundEntries() throws {
        let firstURL = try #require(URL(string: "https://first.example"))
        let lastURL = try #require(URL(string: "https://last.example"))
        let session = BrowserOpenTabsSession(
            selectedPosition: 2,
            entries: [
                .init(position: 0, kind: .web(firstURL)),
                .init(position: 1, kind: .startPage),
                .init(position: 2, kind: .web(lastURL)),
            ],
        )

        let restored = session.restore(uuid: UUID.init)
        let allIDs = restored.tabs.map(\.id)

        #expect(restored.tabs.count == 3)
        #expect(Set(allIDs).count == 3)
        #expect(restored.tabs.allSatisfy { $0.openerID == nil && !$0.isScriptCreated })
        #expect(restored.selectedTabID == restored.tabs[2].id)
        #expect(restored.selectedURL == lastURL)
        #expect(restored.lazyWebTabURLs == [restored.tabs[0].id: firstURL])
        #expect(restored.tabs[1].isStartPage)
    }

    @Test("Revision reservations stay responsive during storage mutations")
    func revisionReservationDoesNotWaitForMutation() async {
        let gate = BrowserPersistenceRevisionGate()
        let operationStarted = DispatchSemaphore(value: 0)
        let releaseOperation = DispatchSemaphore(value: 0)
        let mutation = Task.detached {
            gate.perform(revision: 1) {
                operationStarted.signal()
                _ = releaseOperation.wait(timeout: .now() + 5)
            }
        }

        let didStartOperation = waitForSignal(operationStarted)
        #expect(didStartOperation)
        guard didStartOperation else {
            releaseOperation.signal()
            _ = await mutation.value
            return
        }

        let reservationStarted = DispatchSemaphore(value: 0)
        let reservationFinished = DispatchSemaphore(value: 0)
        let reservation = Task.detached {
            reservationStarted.signal()
            let revision = gate.reserve(after: 1)
            reservationFinished.signal()
            return revision
        }

        let didStartReservation = waitForSignal(reservationStarted)
        #expect(didStartReservation)
        let reservedDuringMutation = waitForSignal(reservationFinished, timeout: 0.5)
        releaseOperation.signal()

        let mutationWasAccepted = await mutation.value
        let revision = await reservation.value
        #expect(mutationWasAccepted)
        #expect(reservedDuringMutation)
        #expect(revision == 2)
    }

    private func waitForSignal(
        _ semaphore: DispatchSemaphore,
        timeout: TimeInterval = 1,
    ) -> Bool {
        semaphore.wait(timeout: .now() + timeout) == .success
    }

    @Test("Newer save and purge revisions reject older asynchronous work")
    func persistenceRejectsStaleRevisions() async throws {
        let directory = FileManager.default
            .temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = BrowserOpenTabsSessionStorage(directoryURL: directory)
        let firstURL = try #require(URL(string: "https://first.example"))
        let committedBeforePurge = BrowserOpenTabsSession(
            selectedPosition: 0,
            entries: [.init(position: 0, kind: .web(firstURL))],
        )
        let stale = BrowserOpenTabsSession(
            selectedPosition: 0,
            entries: [.init(position: 0, kind: .startPage)],
        )

        await storage.save(committedBeforePurge, revision: 4)
        await storage.purge(revision: 5)
        await storage.save(stale, revision: 4)

        #expect(await storage.load() == nil)

        let newer = try BrowserOpenTabsSession(
            selectedPosition: 0,
            entries: [.init(position: 0, kind: .web(#require(URL(string: "https://newer.example"))))],
        )
        await storage.save(newer, revision: 6)
        await storage.save(stale, revision: 5)
        await storage.purge(revision: 5)

        let savedData = try #require(await storage.load())
        #expect(BrowserOpenTabsSession.decode(savedData) == newer)
    }

    @Test("A committed current session wins over stale transaction artifacts")
    func committedCurrentWinsAndCleansStaleTransactionFiles() async throws {
        let directory = try temporarySessionDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let transactionID = "00000000-0000-0000-0000-000000000001"
        let committed = try session("https://committed.example")
        let stale = try session("https://stale.example")
        try write(committed, to: directory.appendingPathComponent("open-tabs.json"))
        try write(stale, to: transactionArtifact("pending", id: transactionID, in: directory))
        try write(stale, to: transactionArtifact("previous", id: transactionID, in: directory))
        try Data().write(to: transactionArtifact("recovery", id: transactionID, in: directory))

        let storage = BrowserOpenTabsSessionStorage(directoryURL: directory)
        let loadedData = try #require(await storage.load())

        #expect(BrowserOpenTabsSession.decode(loadedData) == committed)
        #expect(try Set(fileNames(in: directory)) == ["open-tabs.json"])
    }

    @Test("An interrupted promotion recovers the last committed session")
    func interruptedPromotionRecoversPreviousSession() async throws {
        let directory = try temporarySessionDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let transactionID = "00000000-0000-0000-0000-000000000002"
        let committed = try session("https://committed-before-promotion.example")
        let uncommitted = try session("https://interrupted-candidate.example")
        try write(uncommitted, to: directory.appendingPathComponent("open-tabs.json"))
        try write(uncommitted, to: transactionArtifact("pending", id: transactionID, in: directory))
        try write(committed, to: transactionArtifact("previous", id: transactionID, in: directory))
        try Data("promoting".utf8).write(
            to: transactionArtifact("transaction", id: transactionID, in: directory),
        )

        let storage = BrowserOpenTabsSessionStorage(directoryURL: directory)
        let loadedData = try #require(await storage.load())

        #expect(BrowserOpenTabsSession.decode(loadedData) == committed)
        #expect(try Set(fileNames(in: directory)) == ["open-tabs.json"])
    }

    @Test("An uncommitted first candidate is discarded when no previous session exists")
    func interruptedFirstSaveNeverPromotesPendingCandidate() async throws {
        let directory = try temporarySessionDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let transactionID = "00000000-0000-0000-0000-000000000006"
        let uncommitted = try session("https://never-committed.example")
        try write(uncommitted, to: directory.appendingPathComponent("open-tabs.json"))
        try write(uncommitted, to: transactionArtifact("pending", id: transactionID, in: directory))
        try Data("promoting".utf8).write(
            to: transactionArtifact("transaction", id: transactionID, in: directory),
        )

        let storage = BrowserOpenTabsSessionStorage(directoryURL: directory)

        #expect(await storage.load() == nil)
        #expect(try fileNames(in: directory).isEmpty)
    }

    @Test("Purge removes the committed session and every recognized transaction file")
    func purgeRemovesCommittedAndTransactionFiles() async throws {
        let directory = try temporarySessionDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let transactionID = "00000000-0000-0000-0000-000000000003"
        let saved = try session("https://purged.example")
        try write(saved, to: directory.appendingPathComponent("open-tabs.json"))
        try write(saved, to: transactionArtifact("pending", id: transactionID, in: directory))
        try write(saved, to: transactionArtifact("previous", id: transactionID, in: directory))
        try Data().write(to: transactionArtifact("transaction", id: transactionID, in: directory))
        try Data().write(to: transactionArtifact("recovery", id: transactionID, in: directory))

        let storage = BrowserOpenTabsSessionStorage(directoryURL: directory)
        await storage.purge(revision: 1)

        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    @Test("Purge after an interrupted save leaves no old URL-session files")
    func purgeAfterInterruptedPromotionLeavesNoSessionFiles() async throws {
        let directory = try temporarySessionDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let transactionID = "00000000-0000-0000-0000-000000000004"
        let committed = try session("https://old-committed.example")
        let interrupted = try session("https://old-interrupted.example")
        try write(interrupted, to: directory.appendingPathComponent("open-tabs.json"))
        try write(interrupted, to: transactionArtifact("pending", id: transactionID, in: directory))
        try write(committed, to: transactionArtifact("previous", id: transactionID, in: directory))
        try Data().write(
            to: transactionArtifact("transaction", id: transactionID, in: directory),
        )

        let storage = BrowserOpenTabsSessionStorage(directoryURL: directory)
        await storage.purge(revision: 2)

        let remainingNames = FileManager.default.fileExists(atPath: directory.path)
            ? try fileNames(in: directory)
            : []
        #expect(remainingNames.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    @Test("Live storage uses a dedicated OpenTabsSession directory")
    func liveStorageUsesDedicatedSessionDirectory() throws {
        let storage = try #require(BrowserOpenTabsSessionStorage.live)

        #expect(storage.fileURL.deletingLastPathComponent().lastPathComponent == "OpenTabsSession")
        #expect(storage.fileURL.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent == "Browser")
    }

    @Test("Legacy session bytes remain until a dedicated replacement commits")
    func legacySessionRemainsRecoverableUntilDedicatedSaveCommits() async throws {
        let browserDirectory = try temporarySessionDirectory()
        defer { try? FileManager.default.removeItem(at: browserDirectory) }
        let sessionDirectory = browserDirectory.appendingPathComponent("OpenTabsSession", isDirectory: true)
        let legacySessionURL = browserDirectory.appendingPathComponent("open-tabs.json", isDirectory: false)
        let oldSession = try session("https://legacy-session.example")
        let newSession = try session("https://dedicated-session.example")
        try write(oldSession, to: legacySessionURL)
        let storage = BrowserOpenTabsSessionStorage(
            directoryURL: sessionDirectory,
            legacyDirectoryURL: browserDirectory,
        )

        let loadedData = try #require(await storage.load())
        #expect(BrowserOpenTabsSession.decode(loadedData) == oldSession)
        #expect(FileManager.default.fileExists(atPath: legacySessionURL.path))

        await storage.save(newSession, revision: 1)

        let savedData = try #require(await storage.load())
        #expect(BrowserOpenTabsSession.decode(savedData) == newSession)
        #expect(!FileManager.default.fileExists(atPath: legacySessionURL.path))
    }

    @Test("Purge removes legacy session files without deleting the generic Browser directory")
    func purgeRemovesLegacySessionFilesAndKeepsBrowserDirectory() async throws {
        let browserDirectory = try temporarySessionDirectory()
        defer { try? FileManager.default.removeItem(at: browserDirectory) }
        let transactionID = "00000000-0000-0000-0000-000000000005"
        let sessionDirectory = browserDirectory.appendingPathComponent("OpenTabsSession", isDirectory: true)
        let legacySessionURL = browserDirectory.appendingPathComponent("open-tabs.json", isDirectory: false)
        let unrelatedFileURL = browserDirectory.appendingPathComponent("unrelated-browser-data", isDirectory: false)
        let saved = try session("https://legacy-purge.example")
        try write(saved, to: legacySessionURL)
        try write(saved, to: transactionArtifact("pending", id: transactionID, in: browserDirectory))
        try write(saved, to: transactionArtifact("previous", id: transactionID, in: browserDirectory))
        try Data().write(to: transactionArtifact("transaction", id: transactionID, in: browserDirectory))
        try Data("keep".utf8).write(to: unrelatedFileURL)
        let storage = BrowserOpenTabsSessionStorage(
            directoryURL: sessionDirectory,
            legacyDirectoryURL: browserDirectory,
        )

        await storage.purge(revision: 1)

        #expect(!FileManager.default.fileExists(atPath: sessionDirectory.path))
        #expect(!FileManager.default.fileExists(atPath: legacySessionURL.path))
        #expect(!FileManager.default.fileExists(atPath: transactionArtifact(
            "pending",
            id: transactionID,
            in: browserDirectory,
        ).path))
        #expect(!FileManager.default.fileExists(atPath: transactionArtifact(
            "previous",
            id: transactionID,
            in: browserDirectory,
        ).path))
        #expect(!FileManager.default.fileExists(atPath: transactionArtifact(
            "transaction",
            id: transactionID,
            in: browserDirectory,
        ).path))
        #expect(FileManager.default.fileExists(atPath: browserDirectory.path))
        #expect(try Data(contentsOf: unrelatedFileURL) == Data("keep".utf8))
    }

    @Test("A failed newer write preserves the last committed session")
    func failedNewerPersistencePreservesCommittedSession() async throws {
        let directory = FileManager.default
            .temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let primaryExclusionCount = LockIsolated(0)
        let failPrimaryExclusionOnCall = LockIsolated<Int?>(nil)
        let storage = BrowserOpenTabsSessionStorage(directoryURL: directory) { url in
            if url.lastPathComponent == "open-tabs.json" {
                let call = primaryExclusionCount.withValue { count in
                    count += 1
                    return count
                }
                if failPrimaryExclusionOnCall.value == call {
                    failPrimaryExclusionOnCall.withValue { $0 = nil }
                    return false
                }
            }
            return try BrowserOpenTabsSessionStorage.applyAndVerifyBackupExclusion(url)
        }
        let firstURL = try #require(URL(string: "https://committed.example"))
        let replacementURL = try #require(URL(string: "https://replacement.example"))
        let committed = BrowserOpenTabsSession(
            selectedPosition: 0,
            entries: [.init(position: 0, kind: .web(firstURL))],
        )
        let replacement = BrowserOpenTabsSession(
            selectedPosition: 0,
            entries: [.init(position: 0, kind: .web(replacementURL))],
        )

        await storage.save(committed, revision: 1)
        primaryExclusionCount.withValue { $0 = 0 }
        failPrimaryExclusionOnCall.withValue { $0 = 2 }
        await storage.save(replacement, revision: 2)

        let savedData = try #require(await storage.load())
        #expect(BrowserOpenTabsSession.decode(savedData) == committed)
    }

    @Test("Synchronous revision reservation rejects effects launched with older state")
    func revisionReservationPrecedesPersistenceEffects() {
        let gate = BrowserPersistenceRevisionGate()
        let firstRevision = gate.reserve(after: 0)
        let secondRevision = gate.reserve(after: firstRevision)
        let staleOperation = LockIsolated(false)

        let didRun = gate.perform(revision: firstRevision) {
            staleOperation.withValue { $0 = true }
        }

        #expect(secondRevision > firstRevision)
        #expect(!didRun)
        #expect(!staleOperation.value)
    }

    @Test("Successful atomic writes are excluded from device backups")
    func sessionFileIsExcludedFromBackup() async throws {
        let directory = FileManager.default
            .temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = BrowserOpenTabsSessionStorage(directoryURL: directory)
        let url = try #require(URL(string: "https://private.example"))
        let session = BrowserOpenTabsSession(
            selectedPosition: 0,
            entries: [.init(position: 0, kind: .web(url))],
        )

        await storage.save(session, revision: 1)

        let fileValues = try storage.fileURL.resourceValues(forKeys: [.isExcludedFromBackupKey])
        let directoryValues = try directory.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(fileValues.isExcludedFromBackup == true)
        #expect(directoryValues.isExcludedFromBackup == true)
    }

    private func temporarySessionDirectory() throws -> URL {
        let directory = FileManager.default
            .temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
        )
        return directory
    }

    private func session(_ urlString: String) throws -> BrowserOpenTabsSession {
        let url = try #require(URL(string: urlString))
        return BrowserOpenTabsSession(
            selectedPosition: 0,
            entries: [.init(position: 0, kind: .web(url))],
        )
    }

    private func write(_ session: BrowserOpenTabsSession, to url: URL) throws {
        try session.encoded().write(to: url)
    }

    private func transactionArtifact(_ suffix: String, id: String, in directory: URL) -> URL {
        directory.appendingPathComponent(".open-tabs-\(id).\(suffix)")
    }

    private func fileNames(in directory: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
    }
}
