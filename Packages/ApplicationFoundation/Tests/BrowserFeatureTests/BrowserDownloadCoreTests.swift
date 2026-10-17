//
//  BrowserDownloadCoreTests.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import ComposableArchitecture
import Foundation
import ObjectiveC
import Testing
@testable import BrowserFeature

@Suite("Browser transient download core")
@MainActor
struct BrowserDownloadCoreTests {
    @Test
    func admissionRetainsRejectedWritersUntilAck() throws {
        let fixture = try DownloadCoreFixture(authorized: false)
        defer { fixture.removeTestFiles() }
        weak var retained: DownloadCoreTransfer?
        do {
            let transfer = DownloadCoreTransfer()
            retained = transfer
            let id = fixture.owner.admit(transfer, tabID: .init())
            #expect(id == nil)
            #expect(transfer.cancelCalls == 1)
        }
        #expect(retained != nil)
        #expect(fixture.owner.activeCount == 0)
        #expect(fixture.owner.snapshot.notice == .unauthorized)
        #expect(try fixture.children().isEmpty)
        retained?.acknowledgeCancellation()
        #expect(retained == nil)
    }

    @Test("Reauthentication clears the stale unauthorized notice")
    func reauthenticationClearsUnauthorizedNotice() throws {
        let fixture = try DownloadCoreFixture(authorized: false)
        defer { fixture.removeTestFiles() }

        #expect(fixture.owner.captureAdmissionToken(for: .init()) == nil)
        #expect(fixture.owner.snapshot.notice == .unauthorized)

        fixture.control.authorized = true
        fixture.owner.recheckAuthorization()

        #expect(fixture.owner.snapshot.notice == nil)
    }

    @Test("A delayed revoked handoff cannot restore a stale authorization notice")
    func revokedHandoffAfterReauthenticationKeepsNoticeCleared() throws {
        let fixture = try DownloadCoreFixture()
        defer { fixture.removeTestFiles() }

        let tabID = BrowserTabID()
        let token = fixture.owner.captureAdmissionToken(for: tabID)
        #expect(token != nil)

        fixture.control.authorized = false
        fixture.owner.invalidateAuthorization()
        #expect(fixture.owner.snapshot.notice == .unauthorized)

        fixture.control.authorized = true
        fixture.owner.recheckAuthorization()
        #expect(fixture.owner.snapshot.notice == nil)

        let transfer = DownloadCoreTransfer()
        let id = fixture.owner.admit(transfer, tabID: tabID, using: token)
        #expect(id == nil)
        #expect(transfer.cancelCalls == 1)
        #expect(fixture.owner.activeCount == 0)
        #expect(fixture.owner.snapshot.notice == nil)

        transfer.acknowledgeCancellation()
    }

    @Test
    func destinationsRejectAliasesAndPartialData() throws {
        let fixture = try DownloadCoreFixture()
        defer { fixture.removeTestFiles() }
        let first = try fixture.start(name: "../../private/" + String(repeating: "x", count: 200))
        let second = try fixture.start(name: "../../private/" + String(repeating: "x", count: 200))
        #expect(first.url != second.url)
        #expect(first.url.lastPathComponent.utf8.count <= 96)
        #expect(!first.url.lastPathComponent.contains("/"))
        #expect(!FileManager.default.fileExists(atPath: first.url.path))
        #expect(try first.url
            .deletingLastPathComponent()
            .resourceValues(forKeys: [.isExcludedFromBackupKey])
            .isExcludedFromBackup == true)
        try Data([1, 2, 3]).write(to: first.url)
        fixture.owner.execute(.init(snapshot: fixture.owner.snapshot, action: .present(first.id, .preview)))
        #expect(fixture.owner.snapshot.presentation == nil)
        #expect(fixture.owner.snapshot.records.allSatisfy { !$0.isReady && $0.filename == nil })
        fixture.owner.revokeAll()
        first.transfer.acknowledgeCancellation()
        second.transfer.acknowledgeCancellation()
    }

    @Test
    func completedDownloadsVerifyOwnedBytes() throws {
        let fixture = try DownloadCoreFixture()
        defer { fixture.removeTestFiles() }
        let transfer = try fixture.start(name: "fixture.pdf")
        let bytes = Data([1, 2, 3, 4])
        try bytes.write(to: transfer.url)
        fixture.owner.progress(id: transfer.id, completed: 3, total: 4)
        fixture.owner.progress(id: transfer.id, completed: 1, total: nil)
        #expect(fixture.owner.snapshot.records.first?.receivedBytes == 3)
        fixture.owner.finished(transfer.id)
        let record = try #require(fixture.owner.snapshot.records.first)
        #expect(record.isReady)
        #expect(record.receivedBytes == 4)
        #expect(record.filename == "fixture.pdf")
        #expect(fixture.owner.activeCount == 0)
        #expect(fixture.owner.retainedCount == 1)
        #expect(try transfer.url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
        fixture.owner.execute(.init(snapshot: fixture.owner.snapshot, action: .present(transfer.id, .share)))
        let request = try #require(fixture.owner.snapshot.presentation)
        #expect(fixture.owner.presentationURL(for: request) == transfer.url)
        #expect(try Data(contentsOf: transfer.url) == bytes)
        fixture.owner.execute(.init(snapshot: fixture.owner.snapshot, action: .dismissPresentation(request.requestID)))
        #expect(fixture.owner.snapshot.presentation == nil)
        #expect(fixture.owner.presentationURL(for: request) == nil)
        #expect(fixture.owner.retainedCount == 1)
        #expect(FileManager.default.fileExists(atPath: transfer.url.path))
    }

    @Test
    func unsupportedPreviewKeepsCompletedFile() throws {
        let fixture = try DownloadCoreFixture()
        defer { fixture.removeTestFiles() }
        let transfer = try fixture.start(name: "fixture.pdf")
        let bytes = Data([1, 2, 3, 4])
        try bytes.write(to: transfer.url)
        fixture.owner.finished(transfer.id)

        fixture.owner.execute(.init(snapshot: fixture.owner.snapshot, action: .present(transfer.id, .preview)))
        let unavailable = try #require(fixture.owner.snapshot.presentation)
        #expect(fixture.owner.presentationURL(for: unavailable) == transfer.url)
        fixture.owner.presentationUnavailable(unavailable, discard: false)

        #expect(fixture.owner.snapshot.presentation == nil)
        #expect(fixture.owner.snapshot.notice == .previewUnavailable)
        #expect(fixture.owner.snapshot.records.map(\.id) == [transfer.id])
        #expect(fixture.owner.snapshot.records.first?.isReady == true)
        #expect(FileManager.default.fileExists(atPath: transfer.url.path))
        #expect(try Data(contentsOf: transfer.url) == bytes)
        #expect(fixture.owner.presentationURL(for: unavailable) == nil)

        fixture.owner.execute(.init(snapshot: fixture.owner.snapshot, action: .present(transfer.id, .share)))
        let recovered = try #require(fixture.owner.snapshot.presentation)
        #expect(fixture.owner.presentationURL(for: recovered) == transfer.url)
        #expect(try Data(contentsOf: transfer.url) == bytes)
        let recoveredSnapshot = fixture.owner.snapshot
        fixture.owner.presentationUnavailable(unavailable, discard: false)
        #expect(fixture.owner.snapshot == recoveredSnapshot)
    }

    @Test(
        arguments: [false, true],
    )
    func shareFailureRejectsMissingOrChangedFile(
        replacedBySymlink: Bool,
    ) throws {
        let fixture = try DownloadCoreFixture()
        defer { fixture.removeTestFiles() }
        let transfer = try fixture.start(name: "fixture.pdf")
        try Data([1, 2, 3, 4]).write(to: transfer.url)
        fixture.owner.finished(transfer.id)
        fixture.owner.execute(.init(snapshot: fixture.owner.snapshot, action: .present(transfer.id, .share)))
        let unavailable = try #require(fixture.owner.snapshot.presentation)
        #expect(fixture.owner.presentationURL(for: unavailable) == transfer.url)

        let outside = fixture.root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        let outsideBytes = Data([9, 8, 7])
        defer { try? FileManager.default.removeItem(at: outside) }
        if replacedBySymlink {
            try outsideBytes.write(to: outside)
            try FileManager.default.removeItem(at: transfer.url)
            try FileManager.default.createSymbolicLink(at: transfer.url, withDestinationURL: outside)
        } else {
            try FileManager.default.removeItem(at: transfer.url)
        }

        fixture.owner.presentationUnavailable(unavailable, discard: true)
        #expect(fixture.owner.snapshot.presentation == nil)
        #expect(fixture.owner.snapshot.records.isEmpty)
        #expect(fixture.owner.snapshot.notice == .transferFailed)
        #expect(!FileManager.default.fileExists(atPath: transfer.url.path))
        if replacedBySymlink {
            #expect(try Data(contentsOf: outside) == outsideBytes)
        }

        let replacement = try fixture.start(name: "recovered.bin")
        let replacementBytes = Data([5, 6, 7, 8])
        try replacementBytes.write(to: replacement.url)
        fixture.owner.finished(replacement.id)
        fixture.owner.execute(.init(snapshot: fixture.owner.snapshot, action: .present(replacement.id, .share)))
        let recovered = try #require(fixture.owner.snapshot.presentation)
        #expect(recovered.downloadID == replacement.id)
        #expect(fixture.owner.presentationURL(for: recovered) == replacement.url)
        #expect(try Data(contentsOf: replacement.url) == replacementBytes)

        let recoveredSnapshot = fixture.owner.snapshot
        fixture.owner.presentationUnavailable(unavailable, discard: true)
        #expect(fixture.owner.snapshot == recoveredSnapshot)
        #expect(fixture.owner.snapshot.presentation == recovered)
        #expect(fixture.owner.snapshot.records.map(\.id) == [replacement.id])
        #expect(fixture.owner.presentationURL(for: recovered) == replacement.url)
    }

    @Test
    func duplicateCallbacksPreserveCompletedFile() throws {
        let fixture = try DownloadCoreFixture()
        defer { fixture.removeTestFiles() }
        let transfer = try fixture.start()
        #expect(fixture.owner.admit(transfer.transfer, tabID: .init()) == transfer.id)
        #expect(fixture.owner.destination(for: transfer.id, suggestedName: "replacement") == nil)
        try Data([1]).write(to: transfer.url)
        fixture.owner.finished(transfer.id)
        let completed = fixture.owner.snapshot
        fixture.owner.finished(transfer.id)
        fixture.owner.failed(transfer.id)
        fixture.owner.progress(id: transfer.id, completed: 99, total: 99)
        #expect(fixture.owner.snapshot == completed)
    }

    @Test(
        arguments: [false, true],
    )
    func cancellationCleansAfterAcknowledgement(
        acknowledgeFirst: Bool,
    ) throws {
        let fixture = try DownloadCoreFixture()
        defer { fixture.removeTestFiles() }
        let transfer = try fixture.start()
        try Data([1]).write(to: transfer.url)
        let command = BrowserDownloadCommand(snapshot: fixture.owner.snapshot, action: .cancel(transfer.id))
        fixture.owner.execute(command)
        fixture.owner.execute(command)
        #expect(fixture.owner.snapshot.records.isEmpty)
        #expect(fixture.owner.activeCount == 1)
        #expect(transfer.transfer.cancelCalls == 1)
        #expect(FileManager.default.fileExists(atPath: transfer.url.path))
        #expect(fixture.owner.destination(for: transfer.id, suggestedName: "late") == nil)
        fixture.owner.progress(id: transfer.id, completed: 100, total: 100)
        if acknowledgeFirst {
            transfer.transfer.acknowledgeCancellation()
            fixture.owner.finished(transfer.id)
        } else {
            fixture.owner.finished(transfer.id)
            transfer.transfer.acknowledgeCancellation()
        }
        fixture.owner.failed(transfer.id)
        #expect(fixture.owner.activeCount == 0)
        #expect(fixture.owner.retainedCount == 0)
        #expect(!FileManager.default.fileExists(atPath: transfer.url.deletingLastPathComponent().path))
        #expect(fixture.owner.snapshot.records.isEmpty)
    }

    @Test
    func activeLimitIncludesCancellingWriters() throws {
        let fixture = try DownloadCoreFixture()
        defer { fixture.removeTestFiles() }
        var active: [DownloadCoreFixture.Started] = []
        for _ in 0 ..< 4 {
            try active.append(fixture.start(tabID: .init()))
        }
        #expect(fixture.owner.captureAdmissionToken(for: .init()) == nil)
        #expect(fixture.owner.snapshot.notice == .activeTransferLimitReached)
        #expect(try fixture.children().count == 4)
        fixture.owner.execute(.init(snapshot: fixture.owner.snapshot, action: .cancel(active[0].id)))
        #expect(fixture.owner.activeCount == 4)
        #expect(fixture.owner.captureAdmissionToken(for: .init()) == nil)
        active[0].transfer.acknowledgeCancellation()
        #expect(fixture.owner.activeCount == 3)
        let replacementTab = BrowserTabID()
        let replacementToken = try #require(fixture.owner.captureAdmissionToken(for: replacementTab))
        let replacementTransfer = DownloadCoreTransfer()
        #expect(fixture.owner.admit(replacementTransfer, tabID: replacementTab, using: replacementToken) != nil)
        #expect(fixture.owner.activeCount == 4)
        #expect(fixture.owner.snapshot.notice == nil)
        fixture.owner.revokeAll()
        for transfer in active {
            transfer.transfer.acknowledgeCancellation()
        }
        replacementTransfer.acknowledgeCancellation()
    }

    @Test
    func rejectedWriterBlocksReservationUntilAck() throws {
        let fixture = try DownloadCoreFixture()
        defer { fixture.removeTestFiles() }
        var active: [DownloadCoreFixture.Started] = []
        for _ in 0 ..< 3 {
            try active.append(fixture.start())
        }

        let rejected = DownloadCoreTransfer()
        fixture.owner.reject(rejected, notice: .unauthorized)
        #expect(rejected.cancelCalls == 1)
        #expect(fixture.owner.captureAdmissionToken(for: .init()) == nil)
        #expect(fixture.owner.snapshot.notice == .activeTransferLimitReached)

        rejected.acknowledgeCancellation()
        let tabID = BrowserTabID()
        let token = try #require(fixture.owner.captureAdmissionToken(for: tabID))
        let replacement = DownloadCoreTransfer()
        #expect(fixture.owner.admit(replacement, tabID: tabID, using: token) != nil)
        #expect(fixture.owner.activeCount == 4)

        fixture.owner.revokeAll()
        for item in active {
            item.transfer.acknowledgeCancellation()
        }
        replacement.acknowledgeCancellation()
    }

    @Test
    func retentionLimitRejectsNinthCompletion() throws {
        let fixture = try DownloadCoreFixture()
        defer { fixture.removeTestFiles() }
        var completed: [DownloadCoreFixture.Started] = []
        for _ in 0 ..< 8 {
            let transfer = try fixture.start()
            try Data([1]).write(to: transfer.url)
            fixture.owner.finished(transfer.id)
            completed.append(transfer)
        }
        let excess = DownloadCoreTransfer()
        #expect(fixture.owner.admit(excess, tabID: .init()) == nil)
        #expect(fixture.owner.snapshot.notice == .retainedRecordLimitReached)
        #expect(fixture.owner.retainedCount == 8)
        #expect(fixture.owner.activeCount == 0)
        #expect(completed.allSatisfy { FileManager.default.fileExists(atPath: $0.url.path) })
        fixture.owner.execute(.init(snapshot: fixture.owner.snapshot, action: .discard(completed[0].id)))
        excess.acknowledgeCancellation()
        let replacement = DownloadCoreTransfer()
        let admitted = fixture.owner.admit(replacement, tabID: .init())
        #expect(admitted != nil)
        #expect(fixture.owner.snapshot.notice == nil)
        #expect(fixture.owner.retainedCount == 8)
        fixture.owner.revokeAll()
        replacement.acknowledgeCancellation()
    }

    @Test
    func capacityNoticeExplainsLimitsAndRecovery() {
        let active = BrowserDownloadSnapshot.Notice.activeTransferLimitReached.message
        let retained = BrowserDownloadSnapshot.Notice.retainedRecordLimitReached.message
        #expect(active ==
            "Download limit reached. Four downloads can transfer at once. Cancel an active download and try again.")
        #expect(retained ==
            "Download limit reached. Eight downloads are kept in the list. Discard a download and try again.")
        #expect(active != retained)
    }

    @Test
    func cleanupFailureDeniesAdmissionUntilRetry() throws {
        let fixture = try DownloadCoreFixture()
        defer { fixture.removeTestFiles() }
        let transfer = try fixture.start()
        try Data([1]).write(to: transfer.url)
        fixture.owner.finished(transfer.id)
        fixture.control.failRemoval = true
        fixture.owner.execute(.init(snapshot: fixture.owner.snapshot, action: .discard(transfer.id)))
        #expect(fixture.owner.snapshot.cleanupNeedsRetry)
        #expect(!fixture.owner.snapshot.isAvailable)
        #expect(fixture.owner.snapshot.records.isEmpty)
        #expect(fixture.owner.snapshot.notice == .cleanupRequired)
        #expect(FileManager.default.fileExists(atPath: transfer.url.path))
        let rejected = DownloadCoreTransfer()
        #expect(fixture.owner.admit(rejected, tabID: .init()) == nil)
        fixture.control.failRemoval = false
        let replacement = try fixture.start()
        #expect(!fixture.owner.snapshot.cleanupNeedsRetry)
        #expect(!FileManager.default.fileExists(atPath: transfer.url.path))
        #expect(fixture.owner.snapshot.records.map(\.id) == [replacement.id])
        fixture.owner.revokeAll()
        replacement.transfer.acknowledgeCancellation()
        rejected.acknowledgeCancellation()
    }

    @Test
    func startupPurgeRequiresVerifiedRetry() throws {
        let fixture = try DownloadCoreFixture()
        defer { fixture.removeTestFiles() }
        try FileManager.default.createDirectory(at: fixture.root, withIntermediateDirectories: true)
        let leftover = fixture.root.appendingPathComponent("previous-process")
        try Data([1]).write(to: leftover)
        fixture.control.failRemoval = true
        let owner = BrowserDownloadOwner(store: fixture.store)
        owner.installAuthorization { true }
        #expect(owner.snapshot.cleanupNeedsRetry)
        let rejected = DownloadCoreTransfer()
        #expect(owner.admit(rejected, tabID: .init()) == nil)
        fixture.control.failRemoval = false
        owner.execute(.init(snapshot: owner.snapshot, action: .retryCleanup))
        #expect(owner.snapshot.isAvailable)
        #expect(!FileManager.default.fileExists(atPath: leftover.path))
        #expect(owner.snapshot.records.isEmpty)
        rejected.acknowledgeCancellation()
    }

    @Test
    func authLossRevokesPresentationGeneration(
    ) throws {
        let fixture = try DownloadCoreFixture()
        defer { fixture.removeTestFiles() }
        let transfer = try fixture.start()
        try Data([1]).write(to: transfer.url)
        fixture.owner.finished(transfer.id)
        let old = fixture.owner.snapshot
        fixture.owner.execute(.init(snapshot: old, action: .present(transfer.id, .share)))
        let request = try #require(fixture.owner.snapshot.presentation)
        fixture.control.authorized = false
        #expect(fixture.owner.presentationURL(for: request) == nil)
        #expect(fixture.owner.snapshot.generation > old.generation)
        #expect(fixture.owner.snapshot.presentation == nil)
        #expect(fixture.owner.snapshot.records.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: transfer.url.path))
        fixture.control.authorized = true
        fixture.owner.recheckAuthorization()
        fixture.owner.execute(.init(snapshot: old, action: .present(transfer.id, .share)))
        fixture.owner.finished(transfer.id)
        #expect(fixture.owner.snapshot.isAvailable)
        #expect(fixture.owner.snapshot.records.isEmpty)
        #expect(fixture.owner.snapshot.presentation == nil)
    }

    @Test
    func revocationFollowsTabAndGlobalLifetime() throws {
        let fixture = try DownloadCoreFixture()
        defer { fixture.removeTestFiles() }
        let firstTab = BrowserTabID()
        let first = try fixture.start(tabID: firstTab)
        let second = try fixture.start(tabID: .init())
        fixture.owner.revokeTab(firstTab)
        #expect(first.transfer.cancelCalls == 1)
        #expect(second.transfer.cancelCalls == 0)
        #expect(fixture.owner.snapshot.records.map(\.id) == [second.id])
        first.transfer.acknowledgeCancellation()
        fixture.owner.invalidateAuthorization()
        #expect(second.transfer.cancelCalls == 1)
        #expect(fixture.owner.snapshot.records.isEmpty)
        fixture.owner.recheckAuthorization()
        fixture.owner.progress(id: second.id, completed: 10, total: 10)
        #expect(fixture.owner.snapshot.records.isEmpty)
        second.transfer.acknowledgeCancellation()
        #expect(fixture.owner.retainedCount == 0)
    }

    @Test(arguments: [false, true])
    func invalidProtectionNeverPublishesFile(symbolicLink: Bool) throws {
        let fixture = try DownloadCoreFixture()
        defer { fixture.removeTestFiles() }
        let transfer = try fixture.start()
        let outside = fixture.root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: outside) }
        if symbolicLink {
            try Data([99]).write(to: outside)
            try FileManager.default.createSymbolicLink(at: transfer.url, withDestinationURL: outside)
        } else {
            try Data([1]).write(to: transfer.url)
            fixture.control.failProtection = true
        }
        fixture.owner.finished(transfer.id)
        #expect(fixture.owner.snapshot.records.isEmpty)
        #expect(fixture.owner.snapshot.notice == .transferFailed)
        #expect(!FileManager.default.fileExists(atPath: transfer.url.path))
        if symbolicLink {
            #expect(try Data(contentsOf: outside) == Data([99]))
        }
    }

    @Test
    func nativeVerifierRequiresCompleteProtection() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try Data([1]).write(to: url)
        let protection = try FileManager.default
            .attributesOfItem(atPath: url.path)[.protectionKey] as? FileProtectionType
        if protection == .complete {
            try BrowserDownloadScratchStore.verifyNativeProtection(url)
        } else {
            #expect(throws: BrowserDownloadScratchStore.Failure.protectionUnavailable) {
                try BrowserDownloadScratchStore.verifyNativeProtection(url)
            }
        }
    }

    @Test
    func remountReconcilesPrivacyGeneration() async throws {
        let fixture = try DownloadCoreFixture()
        defer { fixture.removeTestFiles() }
        let stream = fixture.owner.subscribe()
        var events = stream.makeAsyncIterator()
        #expect(await events.next() == fixture.owner.snapshot)
        let transfer = try fixture.start()
        fixture.owner.progress(id: transfer.id, completed: 5, total: 10)
        let progress = try #require(await events.next())
        #expect(progress.records.first?.receivedBytes == 5)
        fixture.owner.invalidateAuthorization()
        let remounted = fixture.owner.subscribe()
        var remountEvents = remounted.makeAsyncIterator()
        let reconciled = try #require(await remountEvents.next())
        #expect(reconciled == fixture.owner.snapshot)
        #expect(reconciled.generation > progress.generation)
        #expect(reconciled.records.isEmpty)
        #expect(reconciled.revision > progress.revision)
        transfer.transfer.acknowledgeCancellation()
    }

    @Test
    func delayedDownloadPreservesNewerNavigation() throws {
        let fixture = try DownloadCoreFixture()
        defer { fixture.removeTestFiles() }
        var correlation = BrowserWebKitNavigationCorrelation()
        let first = NSObject()
        let second = NSObject()
        let beganFirst = correlation.acceptExternalNavigation(first)
        #expect(beganFirst)
        let tabID = BrowserTabID()
        var association = BrowserWebKitDownloadAssociation(
            conversion: correlation.captureDownloadConversion(),
            admissionToken: fixture.owner.captureAdmissionToken(for: tabID),
        )
        let beganSecond = correlation.acceptExternalNavigation(second)
        #expect(beganSecond)
        let result = association.consume(correlation: &correlation)
        let handoff = try #require(result)
        #expect(handoff.completion == nil)
        #expect(correlation.isCurrent(second))
        let transfer = DownloadCoreTransfer()
        let admitted = fixture.owner.admit(transfer, tabID: tabID, using: handoff.admissionToken)
        #expect(admitted != nil)
        #expect(fixture.owner.owns(transfer.identity))
        let duplicate = association.consume(correlation: &correlation)
        #expect(duplicate == nil)
        #expect(fixture.owner.activeCount == 1)
        #expect(correlation.isCurrent(second))
        fixture.owner.invalidateAuthorization()
        transfer.acknowledgeCancellation()
    }

    @Test
    func subframeDownloadPreservesMainNavigation() throws {
        let fixture = try DownloadCoreFixture()
        defer { fixture.removeTestFiles() }
        var correlation = BrowserWebKitNavigationCorrelation()
        let mainNavigation = NSObject()
        let beganMain = correlation.acceptExternalNavigation(mainNavigation)
        #expect(beganMain)
        let tabID = BrowserTabID()
        var association = BrowserWebKitDownloadAssociation(
            conversion: nil,
            admissionToken: fixture.owner.captureAdmissionToken(for: tabID),
        )
        let result = association.consume(correlation: &correlation)
        let handoff = try #require(result)
        #expect(handoff.completion == nil)
        let transfer = DownloadCoreTransfer()
        let admitted = fixture.owner.admit(transfer, tabID: tabID, using: handoff.admissionToken)
        #expect(admitted != nil)
        #expect(correlation.isCurrent(mainNavigation))
        let duplicate = association.consume(correlation: &correlation)
        #expect(duplicate == nil)
        let committed = correlation.commit(mainNavigation)
        #expect(committed)
        #expect(correlation.finish(mainNavigation) != nil)
        fixture.owner.invalidateAuthorization()
        transfer.acknowledgeCancellation()
    }

    @Test
    func abandonedSubframePolicyReleasesExactlyItsAssociationReservation() throws {
        let fixture = try DownloadCoreFixture()
        defer { fixture.removeTestFiles() }
        let tabID = BrowserTabID()
        var correlation = BrowserWebKitNavigationCorrelation()
        let mainNavigation = NSObject()
        let beganMainNavigation = correlation.acceptExternalNavigation(mainNavigation)
        #expect(beganMainNavigation)
        let mainFrameToken = try #require(fixture.owner.captureAdmissionToken(for: tabID))
        let mainFrameAssociation = BrowserWebKitDownloadAssociation(
            conversion: correlation.captureDownloadConversion(),
            admissionToken: mainFrameToken,
        )
        let mainFramePolicy = NSObject()
        var associations = BrowserWebKitDownloadAssociationRegistry()
        associations.insert(mainFrameAssociation, forPolicyObject: mainFramePolicy)

        var subframePolicy: NSObject? = NSObject()
        weak let releasedPolicy = subframePolicy
        let subframeToken = try #require(fixture.owner.captureAdmissionToken(for: tabID))
        let subframeAssociation = BrowserWebKitDownloadAssociation(
            conversion: nil,
            admissionToken: subframeToken,
        )
        try associations.insert(subframeAssociation, forPolicyObject: #require(subframePolicy))

        for _ in 0 ..< 2 {
            #expect(fixture.owner.captureAdmissionToken(for: tabID) != nil)
        }
        #expect(fixture.owner.captureAdmissionToken(for: tabID) == nil)
        #expect(fixture.owner.snapshot.notice == .activeTransferLimitReached)

        subframePolicy = nil
        #expect(releasedPolicy == nil)
        let releasedReservationIDs = associations.releaseAbandonedAssociations(owner: fixture.owner)
        #expect(Set(releasedReservationIDs) == Set([subframeAssociation.reservationID]))
        let duplicateReleaseIDs = associations.releaseAbandonedAssociations(owner: fixture.owner)
        #expect(duplicateReleaseIDs.isEmpty)
        #expect(fixture.owner.captureAdmissionToken(for: tabID) != nil)
        #expect(fixture.owner.captureAdmissionToken(for: tabID) == nil)
        #expect(associations.contains(reservationID: mainFrameAssociation.reservationID))
    }

    @Test
    func unrelatedMainFrameFinishPreservesPendingSubframeHandoff() throws {
        let fixture = try DownloadCoreFixture()
        defer { fixture.removeTestFiles() }
        let tabID = BrowserTabID()
        var correlation = BrowserWebKitNavigationCorrelation()
        let mainNavigation = NSObject()
        let acceptedMainNavigation = correlation.acceptExternalNavigation(mainNavigation)
        #expect(acceptedMainNavigation)

        let policyObject = NSObject()
        let token = try #require(fixture.owner.captureAdmissionToken(for: tabID))
        let subframeAssociation = BrowserWebKitDownloadAssociation(conversion: nil, admissionToken: token)
        var associations = BrowserWebKitDownloadAssociationRegistry()
        associations.insert(subframeAssociation, forPolicyObject: policyObject)

        let finishedNavigation = correlation.finish(mainNavigation)
        let completion = try #require(finishedNavigation)
        associations.releaseReservations(forFinishedNavigation: completion, owner: fixture.owner)
        let pendingAssociation = associations.take(forPolicyObject: policyObject)
        let pending = try #require(pendingAssociation)
        #expect(pending.reservationID == subframeAssociation.reservationID)

        var consumedAssociation = pending
        let handoffResult = consumedAssociation.consume(correlation: &correlation)
        let handoff = try #require(handoffResult)
        #expect(handoff.completion == nil)
        let transfer = DownloadCoreTransfer()
        #expect(fixture.owner.admit(transfer, tabID: tabID, using: handoff.admissionToken) != nil)
        #expect(fixture.owner.activeCount == 1)
        fixture.owner.revokeAll()
        transfer.acknowledgeCancellation()
    }

    @Test
    func staleMainFrameFinishCannotClearCurrentNavigationOrItsAssociations() throws {
        let fixture = try DownloadCoreFixture()
        defer { fixture.removeTestFiles() }
        var correlation = BrowserWebKitNavigationCorrelation()
        let staleNavigation = NSObject()
        let currentNavigation = NSObject()
        let acceptedStaleNavigation = correlation.acceptExternalNavigation(staleNavigation)
        #expect(acceptedStaleNavigation)

        let policyObject = NSObject()
        let tabID = BrowserTabID()
        let token = try #require(fixture.owner.captureAdmissionToken(for: tabID))
        let association = BrowserWebKitDownloadAssociation(conversion: nil, admissionToken: token)
        var associations = BrowserWebKitDownloadAssociationRegistry()
        associations.insert(association, forPolicyObject: policyObject)

        let acceptedCurrentNavigation = correlation.acceptExternalNavigation(currentNavigation)
        #expect(acceptedCurrentNavigation)
        if let completion = correlation.finish(staleNavigation) {
            associations.releaseReservations(forFinishedNavigation: completion, owner: fixture.owner)
        }
        #expect(correlation.isCurrent(currentNavigation))
        #expect(associations.contains(reservationID: association.reservationID))
        let remainingAssociation = associations.take(forPolicyObject: policyObject)
        #expect(remainingAssociation?.reservationID == association.reservationID)
    }

    @Test
    func cancellationPendingNativeWriterCountsUntilTerminalAcknowledgement() throws {
        let fixture = try DownloadCoreFixture()
        defer { fixture.removeTestFiles() }
        let writerTabID = BrowserTabID()
        let tabID = BrowserTabID()
        let token = try #require(fixture.owner.captureAdmissionToken(for: writerTabID))
        let transfer = DownloadCoreTransfer()
        #expect(fixture.owner.admit(transfer, tabID: writerTabID, using: token) != nil)

        for _ in 0 ..< 3 {
            #expect(fixture.owner.captureAdmissionToken(for: tabID) != nil)
        }
        fixture.owner.revokeTab(writerTabID)
        #expect(transfer.cancelCalls == 1)
        #expect(fixture.owner.activeCount == 1)
        #expect(fixture.owner.captureAdmissionToken(for: tabID) == nil)

        transfer.acknowledgeCancellation()
        #expect(fixture.owner.activeCount == 0)
        #expect(fixture.owner.captureAdmissionToken(for: tabID) != nil)
        #expect(fixture.owner.captureAdmissionToken(for: tabID) == nil)
    }

    /// Both WebKit policy callback paths use this association/token contract. These deterministic
    /// tests exercise lifetime ownership without constructing unsupported native policy objects.
    @Test(
        arguments: ["action-main", "response-main", "action-subframe", "response-subframe"],
        ["scene", "authentication", "profile", "tabClosure", "tabReplacement"],
    )
    func policyHandoffRejectsRevokedLifetime(
        policy: String,
        boundary: String,
    ) throws {
        let fixture = try DownloadCoreFixture()
        defer { fixture.removeTestFiles() }
        let tabID = BrowserTabID()
        var correlation = BrowserWebKitNavigationCorrelation()
        let original = NSObject()
        let newer = NSObject()
        let beganOriginal = correlation.acceptExternalNavigation(original)
        #expect(beganOriginal)
        var association = BrowserWebKitDownloadAssociation(
            conversion: policy.hasSuffix("main") ? correlation.captureDownloadConversion() : nil,
            admissionToken: fixture.owner.captureAdmissionToken(for: tabID),
        )
        let beganNewer = correlation.acceptExternalNavigation(newer)
        #expect(beganNewer)
        switch boundary {
        case "scene",
             "authentication":
            fixture.control.authorized = false
            fixture.owner.invalidateAuthorization()
            fixture.control.authorized = true
            fixture.owner.recheckAuthorization()
        case "profile":
            fixture.owner.revokeAll()
        default:
            fixture.owner.revokeTab(tabID)
        }
        // New work may be authorized, but it must never rehabilitate the old policy capability.
        let fresh = try #require(fixture.owner.captureAdmissionToken(for: tabID))
        let consumed = association.consume(correlation: &correlation)
        let handoff = try #require(consumed)
        #expect(handoff.completion == nil)
        #expect(correlation.isCurrent(newer))
        let rejected = DownloadCoreTransfer()
        let oldAdmission = fixture.owner.admit(rejected, tabID: tabID, using: handoff.admissionToken)
        #expect(oldAdmission == nil)
        #expect(rejected.cancelCalls == 1)
        #expect(fixture.owner.owns(rejected.identity))
        #expect(fixture.owner.snapshot.records.isEmpty)
        #expect(try fixture.children().isEmpty)
        let duplicate = association.consume(correlation: &correlation)
        #expect(duplicate == nil)
        rejected.acknowledgeCancellation()
        #expect(!fixture.owner.owns(rejected.identity))
        let freshWriter = DownloadCoreTransfer()
        let recovered = fixture.owner.admit(freshWriter, tabID: tabID, using: fresh)
        #expect(recovered != nil)
        #expect(correlation.isCurrent(newer))
        fixture.owner.invalidateAuthorization()
        freshWriter.acknowledgeCancellation()
    }

    @Test(
        arguments: ["action-main", "response-main", "action-subframe", "response-subframe"],
    )
    func unauthorizedPolicyCannotActivateLater(policy: String) throws {
        let fixture = try DownloadCoreFixture(authorized: false)
        defer { fixture.removeTestFiles() }
        let tabID = BrowserTabID()
        var correlation = BrowserWebKitNavigationCorrelation()
        var association = BrowserWebKitDownloadAssociation(
            conversion: policy.hasSuffix("main") ? correlation.captureDownloadConversion() : nil,
            admissionToken: fixture.owner.captureAdmissionToken(for: tabID),
        )
        fixture.control.authorized = true
        fixture.owner.recheckAuthorization()
        let consumed = association.consume(correlation: &correlation)
        let handoff = try #require(consumed)
        #expect(handoff.admissionToken == nil)
        let writer = DownloadCoreTransfer()
        let admission = fixture.owner.admit(writer, tabID: tabID, using: handoff.admissionToken)
        #expect(admission == nil)
        #expect(writer.cancelCalls == 1)
        #expect(fixture.owner.snapshot.records.isEmpty)
        #expect(try fixture.children().isEmpty)
        writer.acknowledgeCancellation()
    }

    @Test
    func admissionTokensUseInjectedOwner() throws {
        let first = try DownloadCoreFixture()
        let second = try DownloadCoreFixture()
        defer { first.removeTestFiles()
            second.removeTestFiles()
        }
        let tabID = BrowserTabID()
        let token = try #require(first.owner.captureAdmissionToken(for: tabID))
        _ = second.owner.captureAdmissionToken(for: tabID)
        let writer = DownloadCoreTransfer()
        let admission = second.owner.admit(writer, tabID: tabID, using: token)
        #expect(admission == nil)
        #expect(writer.cancelCalls == 1)
        #expect(try second.children().isEmpty)
        writer.acknowledgeCancellation()
    }

    @Test
    func cleanupFailureBlocksAndConcealsFiles(
    ) throws {
        let fixture = try DownloadCoreFixture()
        defer { fixture.removeTestFiles() }
        let transfer = try fixture.start()
        try Data([1]).write(to: transfer.url)
        fixture.owner.finished(transfer.id)
        fixture.control.failRemoval = true
        fixture.control.authorized = false
        fixture.owner.invalidateAuthorization()
        #expect(fixture.owner.snapshot.cleanupNeedsRetry)
        #expect(!fixture.owner.snapshot.isAvailable)
        #expect(fixture.owner.snapshot.records.isEmpty)
        #expect(FileManager.default.fileExists(atPath: transfer.url.path))
        var render = BrowserDownloadRootRenderState()
        render.update(token: testRootRenderToken(false), liveToken: testRootRenderToken(false))
        #expect(!render.canReleaseCover(sceneActive: true, nativeAdmissionHeld: false))
        render.confirm(
            revision: render.revision,
            token: render.token ?? testRootRenderToken(false),
            liveToken: testRootRenderToken(false),
            rootAttached: true,
            modalsAbsent: true,
            layoutCommitted: true,
        )
        #expect(render.canReleaseCover(sceneActive: true, nativeAdmissionHeld: false))
        #expect(!fixture.owner.snapshot.isAvailable)
        fixture.control.failRemoval = false
        fixture.owner.execute(.init(snapshot: fixture.owner.snapshot, action: .retryCleanup))
        #expect(!fixture.owner.snapshot.cleanupNeedsRetry)
        #expect(!FileManager.default.fileExists(atPath: transfer.url.path))
    }

    @Test
    func rejectedPresenterPreservesCompletedFile() throws {
        let fixture = try DownloadCoreFixture()
        defer { fixture.removeTestFiles() }
        let transfer = try fixture.start()
        try Data([1, 2, 3]).write(to: transfer.url)
        fixture.owner.finished(transfer.id)
        fixture.owner.execute(.init(snapshot: fixture.owner.snapshot, action: .present(transfer.id, .preview)))
        let rejected = try #require(fixture.owner.snapshot.presentation)
        fixture.owner.execute(.init(snapshot: fixture.owner.snapshot, action: .dismissPresentation(rejected.requestID)))
        #expect(fixture.owner.snapshot.presentation == nil)
        #expect(fixture.owner.snapshot.records.first?.isReady == true)
        #expect(FileManager.default.fileExists(atPath: transfer.url.path))
        fixture.owner.execute(.init(snapshot: fixture.owner.snapshot, action: .present(transfer.id, .share)))
        let latest = try #require(fixture.owner.snapshot.presentation)
        fixture.owner.execute(.init(snapshot: fixture.owner.snapshot, action: .dismissPresentation(rejected.requestID)))
        #expect(fixture.owner.snapshot.presentation == latest)
    }

    @Test
    func nativeAbsenceKeepsLatestRequestEligible() throws {
        let fixture = try DownloadCoreFixture()
        defer { fixture.removeTestFiles() }
        let transfer = try fixture.start()
        try Data([1]).write(to: transfer.url)
        fixture.owner.finished(transfer.id)
        fixture.owner.execute(.init(snapshot: fixture.owner.snapshot, action: .present(transfer.id, .preview)))
        let old = try #require(fixture.owner.snapshot.presentation)
        var lifetime = BrowserDownloadPresentationLifetime()
        _ = lifetime.begin()
        lifetime.complete()
        fixture.owner.execute(.init(snapshot: fixture.owner.snapshot, action: .dismissPresentation(old.requestID)))
        fixture.owner.execute(.init(snapshot: fixture.owner.snapshot, action: .present(transfer.id, .share)))
        let latest = try #require(fixture.owner.snapshot.presentation)
        lifetime.revoke()
        #expect(lifetime.admissionDecision(presenterAvailable: true) == .waitForAbsence)
        let absent = lifetime.confirmAbsence(isAbsent: true)
        #expect(absent)
        fixture.owner.execute(.init(snapshot: fixture.owner.snapshot, action: .dismissPresentation(old.requestID)))
        let reconciled = try #require(fixture.owner.snapshot.presentation)
        #expect(reconciled == latest)
        #expect(lifetime.admissionDecision(presenterAvailable: true) == .present)
        #expect(fixture.owner.presentationURL(for: reconciled) == transfer.url)
    }

    @Test
    func staleDownloadRevisionsAreRejected() async {
        let store = TestStore(initialState: BrowserFeature.State.readyForTesting()) { BrowserFeature() }
        store.exhaustivity = .off(showSkippedAssertions: false)
        let tabs = store.state.tabs
        var revoked = BrowserDownloadSnapshot()
        revoked.revision = 10
        revoked.generation = 2
        await store.send(.downloadsChanged(revoked))
        var obsolete = BrowserDownloadSnapshot()
        obsolete.revision = 9
        obsolete.generation = 1
        obsolete.isAvailable = true
        await store.send(.downloadsChanged(obsolete))
        #expect(store.state.downloads == revoked)
        #expect(store.state.tabs == tabs)
    }

    #if DEBUG
    /// The startup-purge projection reports the persisted expectation, the enumerated count, and
    /// whether every entry name parses as a UUID without ever carrying a path, filename leaf, or
    /// content value.
    @Test
    func purgeInspectionFieldsCarryExpectationAndParsabilityOnly() {
        let expected = UUID()
        let fields = BrowserDownloadScratchStore.purgeInspectionFields(
            entryNames: [expected.uuidString],
            expectedOperation: expected,
        )
        #expect(fields["recordKind"] == "scratchStartupPurgeInspection")
        #expect(fields["expectedOperation"] == expected.uuidString)
        #expect(fields["expectedPresent"] == "true")
        #expect(fields["preExistingCount"] == "1")
        #expect(fields["entryNamesParseUUID"] == "true")
        #expect(
            Set(fields.keys) == [
                "recordKind",
                "phase",
                "stage",
                "resource",
                "preExistingCount",
                "entryNamesParseUUID",
                "expectedOperation",
                "expectedPresent",
            ],
        )
    }

    /// An expectation that is absent from the enumeration still reports a parsable directory whose
    /// names identify no matching operation, and unparsable names surface as a negative parse.
    @Test
    func purgeInspectionFieldsReportAbsentExpectationAndUnparsableEntries() {
        let expected = UUID()
        let fields = BrowserDownloadScratchStore.purgeInspectionFields(
            entryNames: [UUID().uuidString, "not-a-uuid"],
            expectedOperation: expected,
        )
        #expect(fields["expectedPresent"] == "false")
        #expect(fields["preExistingCount"] == "2")
        #expect(fields["entryNamesParseUUID"] == "false")
    }

    /// Without a persisted operation the projection omits the presence key entirely and an empty
    /// enumeration vacuously parses as UUID names.
    @Test
    func purgeInspectionFieldsOmitExpectedPresenceWithoutPersistedOperation() {
        let fields = BrowserDownloadScratchStore.purgeInspectionFields(entryNames: [], expectedOperation: nil)
        #expect(fields["expectedOperation"] == "unavailable")
        #expect(fields["expectedPresent"] == nil)
        #expect(fields["preExistingCount"] == "0")
        #expect(fields["entryNamesParseUUID"] == "true")
    }
    #endif
}

/// Test writer with an explicit terminal barrier; cancellation does not stop it automatically.
@MainActor
private final class DownloadCoreTransfer: BrowserDownloadTransfer {
    var identity: AnyObject {
        self
    }

    private(set) var cancelCalls = 0
    private var cancellation: (@MainActor () -> Void)?

    func cancel(completion: @escaping @MainActor () -> Void) {
        cancelCalls += 1
        cancellation = completion
    }

    func acknowledgeCancellation() {
        let completion = cancellation
        cancellation = nil
        completion?()
    }
}

/// Test-only filesystem fault injection. Native protection is unavailable on some simulators;
/// bypassing its check here never changes the production verifier or backup/file-identity checks.
@MainActor
private final class DownloadCoreFixture {
    struct Started {
        let transfer: DownloadCoreTransfer
        let id: BrowserDownloadID
        let url: URL
    }

    final class Control {
        var failRemoval = false
        var failProtection = false
        var authorized = true
    }

    let root: URL
    let control: Control
    let store: BrowserDownloadScratchStore
    let owner: BrowserDownloadOwner

    init(authorized: Bool = true) throws {
        let faults = Control()
        faults.authorized = authorized
        control = faults
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "browser-download-core-" + UUID().uuidString,
            isDirectory: true,
        )
        store = BrowserDownloadScratchStore(
            root: root,
            verifyProtection: { _ in
                if faults.failProtection {
                    throw BrowserDownloadScratchStore.Failure.protectionUnavailable
                }
            },
            remove: { url in
                if faults.failRemoval {
                    throw CocoaError(.fileWriteNoPermission)
                }
                try FileManager.default.removeItem(at: url)
            },
        )
        owner = BrowserDownloadOwner(store: store)
        owner.installAuthorization { faults.authorized }
    }

    func start(tabID: BrowserTabID = .init(), name: String = "fixture.bin") throws -> Started {
        let transfer = DownloadCoreTransfer()
        let id = try #require(owner.admit(transfer, tabID: tabID))
        let url = try #require(owner.destination(for: id, suggestedName: name))
        return .init(transfer: transfer, id: id, url: url)
    }

    func children() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
    }

    func removeTestFiles() {
        try? FileManager.default.removeItem(at: root)
    }
}

/// Tokens carry only immutable root-selection evidence; no native or filesystem state enters them.
private func testRootRenderToken(
    _ authenticated: Bool,
    generation: UInt64 = 0,
    surface: String = "root",
) -> BrowserDownloadRootRenderToken {
    .init(surfaceID: surface, authenticated: authenticated, privacyGeneration: generation)
}
