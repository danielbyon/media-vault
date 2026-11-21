//
//  BrowserDownloadIngestionTests.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
@_spi(Testing) import MediaLibrary
import PersistenceSupport
import QuickLook
import Testing
import UIKit
@testable import BrowserFeature

@Suite("Browser automatic ingestion")
@MainActor
struct BrowserDownloadIngestionTests {
    @Test(arguments: [false, true])
    func backgroundAllowanceIncludesAcceptanceUntilSuccessOrFailure(fails: Bool) async throws {
        let fixture = try IngestionFixture()
        defer { fixture.removeFiles() }
        fixture.suspendAcceptance = true
        fixture.acceptanceFailure = fails ? .insufficientStorage : nil
        await fixture.owner.refreshIngestionStorage()
        let started = try fixture.start()
        await withCheckedContinuation { continuation in
            fixture.acceptanceStarted = { continuation.resume() }
            fixture.owner.finished(started.id)
        }
        #expect(fixture.owner.activeCount == 0)
        #expect(fixture.backgroundBegins == 1)
        #expect(fixture.backgroundEnds.isEmpty)
        fixture.resumeAcceptance()
        await fixture.owner.reconcileIngestion()
        #expect(fixture.backgroundBegins == 1)
        #expect(fixture.backgroundEnds == [1])
    }

    @Test
    func expiredBackgroundAllowanceDoesNotRenewWhileAcceptanceRemainsPending() async throws {
        let fixture = try IngestionFixture()
        defer { fixture.removeFiles() }
        fixture.suspendAcceptance = true
        await fixture.owner.refreshIngestionStorage()
        let started = try fixture.start()
        await withCheckedContinuation { continuation in
            fixture.acceptanceStarted = { continuation.resume() }
            fixture.owner.finished(started.id)
        }
        fixture.backgroundExpiration?()
        fixture.owner.invalidateAuthorization()
        #expect(fixture.owner.activeCount == 0)
        #expect(fixture.backgroundBegins == 1)
        #expect(fixture.backgroundEnds == [1])
        fixture.resumeAcceptance()
        await fixture.owner.reconcileIngestion()
        #expect(fixture.backgroundBegins == 1)
        #expect(fixture.backgroundEnds == [1])
    }

    @Test
    func lockAfterResolutionBeforeNativeAcquisitionRemovesExportImmediately() async throws {
        let fixture = try IngestionFixture()
        defer { fixture.removeFiles() }
        fixture.unsupportedOnReconcile = true
        await fixture.owner.refreshIngestionStorage()
        let started = try fixture.start(name: "fixture.pdf")
        fixture.owner.finished(started.id)
        await fixture.owner.reconcileIngestion()
        fixture.owner.execute(.init(snapshot: fixture.owner.snapshot, action: .present(started.id, .preview)))
        let request = try #require(fixture.owner.snapshot.presentation)
        let exported = try #require(await fixture.owner.resolvePresentationURL(for: request))
        fixture.authorized = false
        fixture.owner.invalidateAuthorization()
        #expect(!FileManager.default.fileExists(atPath: exported.path))
        #expect(!fixture.owner.presentationWillBegin(request))
        let source = try #require(fixture.accepted[started.id.rawValue])
        #expect(try Data(contentsOf: source) == Data([1, 2]))
    }

    @Test
    func nativeAbsenceBarrierKeepsPendingExportRequestEligible() async throws {
        let fixture = try IngestionFixture()
        defer { fixture.removeFiles() }
        fixture.unsupportedOnReconcile = true
        await fixture.owner.refreshIngestionStorage()
        let started = try fixture.start(name: "fixture.pdf")
        fixture.owner.finished(started.id)
        await fixture.owner.reconcileIngestion()
        fixture.owner.execute(.init(snapshot: fixture.owner.snapshot, action: .present(started.id, .preview)))
        let old = try #require(fixture.owner.snapshot.presentation)
        let oldExport = try #require(await fixture.owner.resolvePresentationURL(for: old))
        #expect(fixture.owner.presentationWillBegin(old))
        var lifetime = BrowserDownloadPresentationLifetime()
        _ = lifetime.begin()
        lifetime.complete()
        fixture.owner.execute(.init(snapshot: fixture.owner.snapshot, action: .dismissPresentation(old.requestID)))
        fixture.owner.execute(.init(snapshot: fixture.owner.snapshot, action: .present(started.id, .share)))
        let pending = try #require(fixture.owner.snapshot.presentation)
        #expect(fixture.owner.presentationIsWaitingForExport(pending))
        lifetime.revoke()
        #expect(lifetime.admissionDecision(presenterAvailable: true) == .waitForAbsence)
        fixture.owner.retryCleanup()
        #expect(fixture.owner.snapshot.presentation == pending)
        #expect(fixture.owner.snapshot.notice != .previewUnavailable)
        #expect(FileManager.default.fileExists(atPath: oldExport.path))
        let absent = lifetime.confirmAbsence(isAbsent: true)
        #expect(absent)
        fixture.owner.presentationDidEnd(old)
        #expect(fixture.owner.snapshot.presentation == pending)
        #expect(!fixture.owner.presentationIsWaitingForExport(pending))
        #expect(!FileManager.default.fileExists(atPath: oldExport.path))
        let nextExport = try #require(await fixture.owner.resolvePresentationURL(for: pending))
        #expect(fixture.owner.presentationWillBegin(pending))
        #expect(FileManager.default.fileExists(atPath: nextExport.path))
        fixture.owner.presentationDidEnd(pending)
    }

    @Test
    func canonicalPresentationExportUsesDetectedTypeInsteadOfDownloadExtension() async throws {
        let fixture = try IngestionFixture()
        defer { fixture.removeFiles() }
        fixture.importOnReconcile = true
        fixture.importedUTI = "public.png"
        await fixture.owner.refreshIngestionStorage()
        let started = try fixture.start(name: "disguised.pdf")
        fixture.owner.finished(started.id)
        await fixture.owner.reconcileIngestion()
        let source = try #require(fixture.canonicalURLs[started.id.rawValue])
        fixture.owner.execute(.init(snapshot: fixture.owner.snapshot, action: .present(started.id, .preview)))
        let request = try #require(fixture.owner.snapshot.presentation)
        let exported = try #require(await fixture.owner.resolvePresentationURL(for: request))
        #expect(exported.pathExtension == "png")
        #expect(try Data(contentsOf: exported) == Data(contentsOf: source))
        fixture.owner.presentationDidEnd(request)
        #expect(FileManager.default.fileExists(atPath: source.path))
    }

    @Test(arguments: [BrowserDownloadPresentation.Kind.preview, .share])
    func presentationExportPreservesSourceUntilNativeAbsence(kind: BrowserDownloadPresentation.Kind) async throws {
        let fixture = try IngestionFixture()
        defer { fixture.removeFiles() }
        fixture.unsupportedOnReconcile = true
        await fixture.owner.refreshIngestionStorage()
        let started = try fixture.start(name: "fixture.pdf")
        fixture.owner.finished(started.id)
        await fixture.owner.reconcileIngestion()
        let source = try #require(fixture.accepted[started.id.rawValue])
        fixture.owner.execute(.init(snapshot: fixture.owner.snapshot, action: .present(started.id, kind)))
        let request = try #require(fixture.owner.snapshot.presentation)
        let exported = try #require(await fixture.owner.resolvePresentationURL(for: request))
        #expect(exported != source)
        #expect(exported.pathExtension == "pdf")
        #expect(try Data(contentsOf: exported) == Data(contentsOf: source))
        let metadata = try FileManager.default.attributesOfItem(atPath: exported.path)
        #expect((metadata[.referenceCount] as? Int) == 1)
        #expect(try exported.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
        #expect(fixture.owner.presentationWillBegin(request))
        fixture.authorized = false
        fixture.owner.invalidateAuthorization()
        #expect(await fixture.owner.resolvePresentationURL(for: request) == nil)
        #expect(FileManager.default.fileExists(atPath: exported.path))
        fixture.owner.presentationDidEnd(request)
        #expect(!FileManager.default.fileExists(atPath: exported.path))
        #expect(try Data(contentsOf: source) == Data([1, 2]))
    }

    @Test
    func privacyRevocationDuringCopyWaitsForWriterThenRemovesUnpublishedExport() async throws {
        let fixture = try IngestionFixture()
        defer { fixture.removeFiles() }
        fixture.unsupportedOnReconcile = true
        fixture.suspendPresentationCopy = true
        await fixture.owner.refreshIngestionStorage()
        let started = try fixture.start(name: "fixture.pdf")
        fixture.owner.finished(started.id)
        await fixture.owner.reconcileIngestion()
        fixture.owner.execute(.init(snapshot: fixture.owner.snapshot, action: .present(started.id, .preview)))
        let request = try #require(fixture.owner.snapshot.presentation)
        let resolution = Task { await fixture.owner.resolvePresentationURL(for: request) }
        await withCheckedContinuation { continuation in fixture.presentationCopyStarted = { continuation.resume() } }
        let partial = try #require(fixture.presentationCopyDestination)
        fixture.authorized = false
        fixture.owner.invalidateAuthorization()
        fixture.owner.presentationDidEnd(request)
        #expect(FileManager.default.fileExists(atPath: partial.path))
        fixture.resumePresentationCopy()
        #expect(await resolution.value == nil)
        #expect(!FileManager.default.fileExists(atPath: partial.path))
        let source = try #require(fixture.accepted[started.id.rawValue])
        #expect(try Data(contentsOf: source) == Data([1, 2]))
    }

    @Test
    func exportCleanupFailureRetainsCapacityAndRetriesWithoutDeletingSource() async throws {
        let fixture = try IngestionFixture()
        defer { fixture.removeFiles() }
        fixture.unsupportedOnReconcile = true
        await fixture.owner.refreshIngestionStorage()
        let started = try fixture.start(name: "fixture.pdf")
        fixture.owner.finished(started.id)
        await fixture.owner.reconcileIngestion()
        fixture.owner.execute(.init(snapshot: fixture.owner.snapshot, action: .present(started.id, .preview)))
        let request = try #require(fixture.owner.snapshot.presentation)
        let exported = try #require(await fixture.owner.resolvePresentationURL(for: request))
        fixture.removalFails = true
        fixture.owner.presentationDidEnd(request)
        #expect(fixture.owner.snapshot.cleanupNeedsRetry)
        #expect(FileManager.default.fileExists(atPath: exported.path))
        #expect(fixture.owner.captureAdmissionToken(for: .init()) == nil)
        fixture.removalFails = false
        fixture.owner.retryCleanup()
        #expect(!fixture.owner.snapshot.cleanupNeedsRetry)
        #expect(!FileManager.default.fileExists(atPath: exported.path))
        let source = try #require(fixture.accepted[started.id.rawValue])
        #expect(try Data(contentsOf: source) == Data([1, 2]))
    }

    @Test
    func presentationExportRespectsFreeSpaceFloorBeforeCopying() async throws {
        let fixture = try IngestionFixture()
        defer { fixture.removeFiles() }
        fixture.unsupportedOnReconcile = true
        await fixture.owner.refreshIngestionStorage()
        let started = try fixture.start(name: "fixture.pdf")
        fixture.owner.finished(started.id)
        await fixture.owner.reconcileIngestion()
        fixture.availableBytes = 536_870_912
        fixture.owner.execute(.init(snapshot: fixture.owner.snapshot, action: .present(started.id, .preview)))
        let request = try #require(fixture.owner.snapshot.presentation)
        #expect(await fixture.owner.resolvePresentationURL(for: request) == nil)
        #expect(fixture.presentationCopyDestination == nil)
        let source = try #require(fixture.accepted[started.id.rawValue])
        #expect(try Data(contentsOf: source) == Data([1, 2]))
    }

    @Test
    func presentationExportHoldsTheEighthTemporarySlotUntilNativeAbsence() async throws {
        let fixture = try IngestionFixture()
        defer { fixture.removeFiles() }
        fixture.unsupportedOnReconcile = true
        fixture.extraPendingCount = 6
        await fixture.owner.refreshIngestionStorage()
        let started = try fixture.start(name: "fixture.pdf")
        fixture.owner.finished(started.id)
        await fixture.owner.reconcileIngestion()
        fixture.owner.execute(.init(snapshot: fixture.owner.snapshot, action: .present(started.id, .share)))
        let request = try #require(fixture.owner.snapshot.presentation)
        #expect(await fixture.owner.resolvePresentationURL(for: request) != nil)
        #expect(fixture.owner.captureAdmissionToken(for: .init()) == nil)
        fixture.owner.presentationDidEnd(request)
        let reservation = try #require(fixture.owner.captureAdmissionToken(for: .init()))
        fixture.owner.releaseAdmissionReservation(reservation)
    }

    @Test
    func failedCopyRetainsItsPartialExportUntilCleanupRetry() async throws {
        let fixture = try IngestionFixture()
        defer { fixture.removeFiles() }
        fixture.unsupportedOnReconcile = true
        await fixture.owner.refreshIngestionStorage()
        let started = try fixture.start(name: "fixture.pdf")
        fixture.owner.finished(started.id)
        await fixture.owner.reconcileIngestion()
        fixture.presentationCopyFails = true
        fixture.removalFails = true
        fixture.owner.execute(.init(snapshot: fixture.owner.snapshot, action: .present(started.id, .preview)))
        let request = try #require(fixture.owner.snapshot.presentation)
        #expect(await fixture.owner.resolvePresentationURL(for: request) == nil)
        let partial = try #require(fixture.presentationCopyDestination)
        #expect(FileManager.default.fileExists(atPath: partial.path))
        #expect(fixture.owner.snapshot.cleanupNeedsRetry)
        #expect(fixture.owner.captureAdmissionToken(for: .init()) == nil)
        fixture.removalFails = false
        fixture.owner.retryCleanup()
        #expect(!FileManager.default.fileExists(atPath: partial.path))
        #expect(!fixture.owner.snapshot.cleanupNeedsRetry)
        let source = try #require(fixture.accepted[started.id.rawValue])
        #expect(try Data(contentsOf: source) == Data([1, 2]))
    }

    @Test
    func pairedLoopbackPDFPreviewEligibilityWithAndWithoutExtension() async throws {
        let fixture = try IngestionFixture()
        defer { fixture.removeFiles() }
        fixture.unsupportedOnReconcile = true
        // Exact PDF payload served by BrowserDownloadLoopbackServer.fixturePDF.
        let payload = try #require(Data(base64Encoded: """
        JVBERi0xLjQKMSAwIG9iago8PCAvVHlwZSAvQ2F0YWxvZyAvUGFnZXMgMiAwIFIgPj4KZW5kb2JqCjIgMCBvYmoKPDwgL1R5
        cGUgL1BhZ2VzIC9LaWRzIFszIDAgUl0gL0NvdW50IDEgPj4KZW5kb2JqCjMgMCBvYmoKPDwgL1R5cGUgL1BhZ2UgL1BhcmVu
        dCAyIDAgUiAvTWVkaWFCb3ggWzAgMCAzMDAgMjAwXSAvUmVzb3VyY2VzIDw8IC9Gb250IDw8IC9GMSA1IDAgUiA+PiA+PiAv
        Q29udGVudHMgNCAwIFIgPj4KZW5kb2JqCjQgMCBvYmoKPDwgL0xlbmd0aCA2NSA+PgpzdHJlYW0KQlQgL0YxIDE0IFRmIDIw
        IDEwMCBUZCAoQnJvd3NlciBkb3dubG9hZCB0cmFuc2ZlciBwcm9iZSkgVGoKJQpFVAplbmRzdHJlYW0KZW5kb2JqCjUgMCBv
        YmoKPDwgL1R5cGUgL0ZvbnQgL1N1YnR5cGUgL1R5cGUxIC9CYXNlRm9udCAvSGVsdmV0aWNhID4+CmVuZG9iagp4cmVmCjAg
        NgowMDAwMDAwMDAwIDY1NTM1IGYgCjAwMDAwMDAwMDkgMDAwMDAgbiAKMDAwMDAwMDA1OCAwMDAwMCBuIAowMDAwMDAwMTE1
        IDAwMDAwIG4gCjAwMDAwMDAyNDEgMDAwMDAgbiAKMDAwMDAwMDM1NSAwMDAwMCBuIAp0cmFpbGVyCjw8IC9TaXplIDYgL1Jv
        b3QgMSAwIFIgPj4Kc3RhcnR4cmVmCjQyNQolJUVPRgo=
        """, options: .ignoreUnknownCharacters))
        await fixture.owner.refreshIngestionStorage()
        let started = try fixture.start(name: "fixture.pdf", bytes: payload)
        fixture.owner.finished(started.id)
        await fixture.owner.reconcileIngestion()
        let opaqueURL = try #require(fixture.accepted[started.id.rawValue])
        var typedURL = opaqueURL.appendingPathExtension("pdf")
        try payload.write(to: typedURL, options: .completeFileProtection)
        var attributes = URLResourceValues()
        attributes.isExcludedFromBackup = true
        try typedURL.setResourceValues(attributes)
        for url in [opaqueURL, typedURL] {
            #expect(try Data(contentsOf: url) == payload)
            let metadata = try FileManager.default.attributesOfItem(atPath: url.path)
            #expect((metadata[.referenceCount] as? Int) == 1)
        }
        // swiftlint:disable:next legacy_objc_type
        let opaqueCanPreview = QLPreviewController.canPreview(opaqueURL as NSURL)
        // swiftlint:disable:next legacy_objc_type
        let typedCanPreview = QLPreviewController.canPreview(typedURL as NSURL)
        print(
            "PDF filename probe: identicalBytes=true uuidCanPreview=\(opaqueCanPreview) pdfCanPreview=\(typedCanPreview)",
        )
        #expect(!opaqueCanPreview)
        #expect(typedCanPreview)
    }

    @Test
    func productionAcceptanceRejectsEmptyFileWithoutStrandingBrowserOwnership() async throws {
        let fixture = try IngestionFixture()
        defer { fixture.removeFiles() }
        let database = try PersistenceStore.makeInMemory()
        let store = SQLiteMediaLibraryStore(database: database)
        let resources = try FileMediaResourceRepository(
            rootURL: fixture.root.appendingPathComponent("library", isDirectory: true),
            protectionOperation: { _ in },
            completedDownloadRootURL: fixture.root.appendingPathComponent("scratch", isDirectory: true),
        )
        let importer = MediaLibraryImporter(store: store, resources: resources)
        fixture.acceptOverride = { url, id, filename in
            try await importer.acceptCompletedDownload(url, operationID: id, originalFilename: filename)
        }
        await fixture.owner.refreshIngestionStorage()
        let started = try fixture.start(bytes: Data())
        fixture.owner.finished(started.id)
        await fixture.owner.reconcileIngestion()
        #expect(FileManager.default.fileExists(atPath: started.url.path))
        #expect(fixture.owner.snapshot.records.first?.status == .failed)
        let reservation = try #require(fixture.owner.captureAdmissionToken(for: .init()))
        fixture.owner.releaseAdmissionReservation(reservation)
        fixture.owner.execute(.init(snapshot: fixture.owner.snapshot, action: .discard(started.id)))
        #expect(!FileManager.default.fileExists(atPath: started.url.path))
        #expect(fixture.owner.snapshot.records.isEmpty)
        #expect(fixture.ingestionRevocations.isEmpty)
        #expect(try await importer.acceptedDownloadStorage().operationCount == 0)
    }

    @Test(arguments: [false, true])
    func ambiguousAcceptanceFailureRetainsSourceAndBlocksAdmissionAfterDiscard(untyped: Bool) async throws {
        let fixture = try IngestionFixture()
        defer { fixture.removeFiles() }
        fixture.acceptOverride = { _, _, _ in
            if untyped {
                throw CocoaError(.fileWriteUnknown)
            }
            throw CompletedDownloadAcceptanceError.ownershipUncertain
        }
        await fixture.owner.refreshIngestionStorage()
        let started = try fixture.start()
        fixture.owner.finished(started.id)
        await fixture.owner.reconcileIngestion()
        fixture.owner.execute(.init(snapshot: fixture.owner.snapshot, action: .discard(started.id)))
        fixture.owner.retryCleanup()
        #expect(FileManager.default.fileExists(atPath: started.url.path))
        #expect(fixture.owner.captureAdmissionToken(for: .init()) == nil)
        #expect(fixture.discarded.isEmpty)
    }

    @Test(arguments: [
        CompletedDownloadAcceptanceError.emptyFile,
        .unsafeSource,
        .itemTooLarge,
        .stagingCapacityExceeded,
        .insufficientStorage,
    ])
    func definiteAcceptanceRejectionRetainsDiscardableSourceAndAllowsOtherAdmission(
        rejection: CompletedDownloadAcceptanceError,
    ) async throws {
        let fixture = try IngestionFixture()
        defer { fixture.removeFiles() }
        fixture.acceptOverride = { _, _, _ in throw rejection }
        await fixture.owner.refreshIngestionStorage()
        let started = try fixture.start()
        fixture.owner.finished(started.id)
        await fixture.owner.reconcileIngestion()
        #expect(fixture.owner.snapshot.records.first?.status == .failed)
        #expect(FileManager.default.fileExists(atPath: started.url.path))
        let reservation = try #require(fixture.owner.captureAdmissionToken(for: .init()))
        fixture.owner.releaseAdmissionReservation(reservation)
        fixture.owner.execute(.init(snapshot: fixture.owner.snapshot, action: .discard(started.id)))
        #expect(!FileManager.default.fileExists(atPath: started.url.path))
        #expect(fixture.owner.snapshot.records.isEmpty)
        #expect(fixture.ingestionRevocations.isEmpty)
    }

    @Test
    func explicitAcceptedDiscardRevokesBeforeAsynchronousCleanup() async throws {
        let fixture = try IngestionFixture()
        defer { fixture.removeFiles() }
        await fixture.owner.refreshIngestionStorage()
        let started = try fixture.start()
        fixture.owner.finished(started.id)
        await fixture.owner.reconcileIngestion()
        await withCheckedContinuation { continuation in
            fixture.discardCompleted = { continuation.resume() }
            fixture.owner.execute(.init(snapshot: fixture.owner.snapshot, action: .discard(started.id)))
            #expect(fixture.ingestionRevocations == [started.id.rawValue])
            #expect(fixture.discarded.isEmpty)
        }
        #expect(fixture.accepted.isEmpty)
    }

    @Test(arguments: ["tab", "profile", "cancel", "discard"])
    func suspendedAcceptanceRetainsSourceAcrossLifetimeBoundaries(boundary: String) async throws {
        let fixture = try IngestionFixture()
        defer { fixture.removeFiles() }
        fixture.suspendAcceptance = true
        await fixture.owner.refreshIngestionStorage()
        let started = try fixture.start()
        await withCheckedContinuation { continuation in
            fixture.acceptanceStarted = { continuation.resume() }
            fixture.owner.finished(started.id)
        }
        switch boundary {
        case "tab":
            fixture.owner.revokeTab(started.tabID)
        case "profile":
            fixture.owner.revokeAll()
        case "cancel":
            fixture.owner.execute(.init(snapshot: fixture.owner.snapshot, action: .cancel(started.id)))
        default:
            fixture.owner.execute(.init(snapshot: fixture.owner.snapshot, action: .discard(started.id)))
        }
        fixture.owner.retryCleanup()
        #expect(FileManager.default.fileExists(atPath: started.url.path))
        #expect(fixture.accepted.isEmpty)
        #expect(fixture.discarded.isEmpty)
        #expect(fixture.ingestionRevocations == (boundary == "discard" ? [started.id.rawValue] : []))
        if boundary == "discard" {
            await withCheckedContinuation { continuation in
                fixture.discardCompleted = { continuation.resume() }
                fixture.resumeAcceptance()
            }
            #expect(fixture.discarded == [started.id.rawValue])
            #expect(fixture.accepted.isEmpty)
        } else {
            fixture.resumeAcceptance()
            await fixture.owner.reconcileIngestion()
            let adopted = try #require(fixture.accepted[started.id.rawValue])
            #expect(try Data(contentsOf: adopted) == Data([1, 2]))
            #expect(fixture.discarded.isEmpty)
            #expect(fixture.owner.snapshot.records.map(\.id) == [started.id])
            #expect(fixture.owner.snapshot.records.first?.status == .pendingImport)
        }
        #expect(!FileManager.default.fileExists(atPath: started.url.path))
        #expect(started.transfer.cancellations == 0)
    }

    @Test
    func startupRecoversJournalHandoffBeforePurgingNativeOrphans() async throws {
        let fixture = try IngestionFixture(priorHandoff: true, priorOrphan: true)
        defer { fixture.removeFiles() }
        let source = try #require(fixture.handoffSource)
        let orphan = try #require(fixture.orphanURL)
        #expect(FileManager.default.fileExists(atPath: source.path))
        #expect(FileManager.default.fileExists(atPath: orphan.path))
        #expect(fixture.owner.captureAdmissionToken(for: .init()) == nil)

        await fixture.owner.refreshIngestionStorage()
        let recovered = try #require(fixture.recoveredURL)
        #expect(try Data(contentsOf: recovered) == Data([3, 4]))
        #expect(!FileManager.default.fileExists(atPath: source.path))
        #expect(!FileManager.default.fileExists(atPath: orphan.path))
        #expect(!fixture.owner.snapshot.cleanupNeedsRetry)
        #expect(fixture.owner.captureAdmissionToken(for: .init()) != nil)
    }

    @Test(arguments: [false, true])
    func unknownStartupOwnershipPreservesScratchUntilRecoverySucceeds(protectionAvailable: Bool) async throws {
        let fixture = try IngestionFixture(
            priorHandoff: true,
            priorOrphan: true,
            protectionAvailable: protectionAvailable,
            failRecovery: true,
        )
        defer { fixture.removeFiles() }
        let source = try #require(fixture.handoffSource)
        let orphan = try #require(fixture.orphanURL)
        fixture.owner.retryCleanup()
        await fixture.owner.refreshIngestionStorage()
        #expect(FileManager.default.fileExists(atPath: source.path))
        #expect(FileManager.default.fileExists(atPath: orphan.path))
        #expect(fixture.owner.snapshot.cleanupNeedsRetry)
        #expect(fixture.owner.captureAdmissionToken(for: .init()) == nil)

        fixture.protectedDataAvailable = true
        fixture.recoveryFails = false
        await fixture.owner.refreshIngestionStorage()
        let recovered = try #require(fixture.recoveredURL)
        #expect(FileManager.default.fileExists(atPath: recovered.path))
        #expect(!FileManager.default.fileExists(atPath: orphan.path))
        #expect(!fixture.owner.snapshot.cleanupNeedsRetry)
    }

    @Test(arguments: [false, true])
    func acceptedPresentationResolvesOwnedBytesAndRejectsRevokedRequests(imported: Bool) async throws {
        let fixture = try IngestionFixture()
        defer { fixture.removeFiles() }
        fixture.importOnReconcile = imported
        fixture.unsupportedOnReconcile = !imported
        await fixture.owner.refreshIngestionStorage()
        let started = try fixture.start(name: imported ? "image.png" : "document.pdf")
        fixture.owner.finished(started.id)
        await fixture.owner.reconcileIngestion()
        #expect(!FileManager.default.fileExists(atPath: started.url.path))
        let expectedURL = try #require(
            imported ? fixture.canonicalURLs[started.id.rawValue] : fixture.accepted[started.id.rawValue],
        )
        #expect(FileManager.default.fileExists(atPath: expectedURL.path))
        #expect(fixture.owner.snapshot.records.first?.status == (imported ? .imported : .unsupported))
        fixture.owner.execute(.init(snapshot: fixture.owner.snapshot, action: .present(started.id, .preview)))
        let request = try #require(fixture.owner.snapshot.presentation)
        let resolved = await fixture.owner.resolvePresentationURL(for: request)
        let exported = try #require(resolved)
        #expect(exported != expectedURL)
        #expect(try Data(contentsOf: exported) == Data(contentsOf: expectedURL))

        fixture.authorized = false
        fixture.processingGeneration += 1
        fixture.owner.invalidateAuthorization()
        let lockedURL = await fixture.owner.resolvePresentationURL(for: request)
        #expect(lockedURL == nil)
        #expect(fixture.owner.snapshot.presentation == nil)
        #expect(fixture.owner.snapshot.records.isEmpty)
        fixture.owner.presentationDidEnd(request)

        fixture.authorized = true
        fixture.owner.recheckAuthorization()
        let staleURL = await fixture.owner.resolvePresentationURL(for: request)
        #expect(staleURL == nil)
        fixture.owner.execute(.init(snapshot: fixture.owner.snapshot, action: .present(started.id, .share)))
        let freshRequest = try #require(fixture.owner.snapshot.presentation)
        let freshURL = await fixture.owner.resolvePresentationURL(for: freshRequest)
        let freshExport = try #require(freshURL)
        #expect(freshExport != exported)
        #expect(try Data(contentsOf: freshExport) == Data(contentsOf: expectedURL))
        fixture.owner.presentationDidEnd(freshRequest)
    }

    @Test
    func privacyLockedCompletionTransfersOwnershipWithoutPublishingContent() async throws {
        let fixture = try IngestionFixture()
        defer { fixture.removeFiles() }
        await fixture.owner.refreshIngestionStorage()
        let started = try fixture.start()
        let reconciliationsBeforeLock = fixture.reconciliations
        fixture.authorized = false
        fixture.owner.invalidateAuthorization()
        fixture.owner.finished(started.id)
        await fixture.owner.reconcileIngestion()
        #expect(!FileManager.default.fileExists(atPath: started.url.path))
        #expect(fixture.owner.snapshot.records.isEmpty)
        #expect(fixture.owner.activeCount == 0)
        #expect(started.transfer.cancellations == 0)
        #expect(fixture.reconciliations == reconciliationsBeforeLock)
    }

    @Test
    func failedNativeWriterNeverHandsOffPartialBytes() async throws {
        let fixture = try IngestionFixture()
        defer { fixture.removeFiles() }
        await fixture.owner.refreshIngestionStorage()
        let started = try fixture.start()
        fixture.owner.failed(started.id)
        await fixture.owner.reconcileIngestion()
        #expect(fixture.accepted.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: started.url.path))
    }

    @Test
    func unavailableProtectedDataDefersAcceptanceUntilAvailabilityReturns() async throws {
        let fixture = try IngestionFixture()
        defer { fixture.removeFiles() }
        await fixture.owner.refreshIngestionStorage()
        let started = try fixture.start()
        fixture.protectedDataAvailable = false
        fixture.owner.finished(started.id)
        await fixture.owner.reconcileIngestion()
        #expect(FileManager.default.fileExists(atPath: started.url.path))
        #expect(fixture.accepted.isEmpty)
        fixture.authorized = false
        fixture.owner.invalidateAuthorization()
        fixture.protectedDataAvailable = true
        fixture.owner.protectedDataBecameAvailable()
        await fixture.owner.reconcileIngestion()
        #expect(!FileManager.default.fileExists(atPath: started.url.path))
        #expect(fixture.owner.snapshot.records.isEmpty)
    }

    @Test(arguments: [
        BrowserDownloadRecord.Status.pendingImport,
        .imported,
        .unsupported,
    ])
    func acceptedRowsSurviveTabProfileAndCancelBoundaries(status: BrowserDownloadRecord.Status) async throws {
        let fixture = try IngestionFixture()
        defer { fixture.removeFiles() }
        fixture.importOnReconcile = status == .imported
        fixture.unsupportedOnReconcile = status == .unsupported
        await fixture.owner.refreshIngestionStorage()
        let started = try fixture.start()
        fixture.owner.finished(started.id)
        await fixture.owner.reconcileIngestion()
        let source = try #require(fixture.canonicalURLs[started.id.rawValue] ?? fixture.accepted[started.id.rawValue])
        var oldPresentation: BrowserDownloadPresentation?
        if status != .pendingImport {
            fixture.owner.execute(.init(snapshot: fixture.owner.snapshot, action: .present(started.id, .preview)))
            oldPresentation = try #require(fixture.owner.snapshot.presentation)
            if let request = oldPresentation {
                _ = try #require(await fixture.owner.resolvePresentationURL(for: request))
            }
        }
        let staleDiscard = BrowserDownloadCommand(snapshot: fixture.owner.snapshot, action: .discard(started.id))
        fixture.owner.execute(.init(snapshot: fixture.owner.snapshot, action: .cancel(started.id)))
        fixture.owner.revokeTab(started.tabID)
        fixture.owner.execute(staleDiscard)
        #expect(fixture.owner.snapshot.records.map(\.id) == [started.id])
        #expect(fixture.owner.snapshot.records.first?.status == status)
        if let request = oldPresentation {
            #expect(await fixture.owner.resolvePresentationURL(for: request) == nil)
        }
        fixture.owner.revokeAll()
        #expect(fixture.owner.snapshot.records.map(\.id) == [started.id])
        #expect(fixture.owner.snapshot.records.first?.status == status)
        #expect(try Data(contentsOf: source) == Data([1, 2]))
        #expect(fixture.discarded.isEmpty)
        #expect(fixture.ingestionRevocations.isEmpty)
        if status == .imported {
            fixture.owner.execute(.init(snapshot: fixture.owner.snapshot, action: .discard(started.id)))
            #expect(FileManager.default.fileExists(atPath: source.path))
            #expect(fixture.discarded.isEmpty)
        } else {
            await withCheckedContinuation { continuation in
                fixture.discardCompleted = { continuation.resume() }
                fixture.owner.execute(.init(snapshot: fixture.owner.snapshot, action: .discard(started.id)))
            }
            #expect(!FileManager.default.fileExists(atPath: source.path))
        }
        #expect(fixture.owner.snapshot.records.isEmpty)
    }

    @Test
    func importedRowsReleaseTemporaryCapacityAndDiscardNeverDeletesCanonicalBytes() async throws {
        let fixture = try IngestionFixture()
        defer { fixture.removeFiles() }
        fixture.importOnReconcile = true
        await fixture.owner.refreshIngestionStorage()
        var imported: [BrowserDownloadID] = []
        for _ in 0 ..< 9 {
            let started = try fixture.start()
            imported.append(started.id)
            fixture.owner.finished(started.id)
            await fixture.owner.reconcileIngestion()
        }
        #expect(fixture.owner.snapshot.records.count == 9)
        #expect(fixture.owner.snapshot.records.allSatisfy { $0.status == .imported })
        fixture.owner.execute(.init(snapshot: fixture.owner.snapshot, action: .discard(imported[0])))
        #expect(fixture.owner.snapshot.records.count == 8)
        #expect(fixture.discarded.isEmpty)
        #expect(fixture.canonical.count == 9)
        #expect(fixture.ingestionRevocations.isEmpty)
    }
}

@MainActor
private final class IngestionFixture {
    struct Started {
        let id: BrowserDownloadID
        let tabID: BrowserTabID
        let url: URL
        let transfer: IngestionTransfer
    }

    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    var authorized = true
    var protectedDataAvailable = true
    var importOnReconcile = false
    var importedUTI: String?
    var unsupportedOnReconcile = false
    var processingGeneration: UInt64 = 0
    var accepted: [UUID: URL] = [:]
    var canonical: [UUID: MediaAsset] = [:]
    var canonicalURLs: [UUID: URL] = [:]
    var discarded: [UUID] = []
    var ingestionRevocations: [UUID] = []
    var reconciliations = 0
    var handoffSource: URL?
    var orphanURL: URL?
    var recoveredURL: URL?
    var recoveryFails = false
    var storageRecovered = false
    var suspendAcceptance = false
    var acceptanceFailure: CompletedDownloadAcceptanceError?
    var backgroundBegins = 0
    var backgroundEnds: [Int] = []
    var backgroundExpiration: (@MainActor @Sendable () -> Void)?
    var availableBytes: Int64? = 8_589_934_592
    var removalFails = false
    var suspendPresentationCopy = false
    var presentationCopyFails = false
    var extraPendingCount = 0
    var presentationCopyDestination: URL?
    var presentationCopyStarted: (() -> Void)?
    var presentationCopyGate: CheckedContinuation<Void, Never>?
    var acceptOverride: (@MainActor (URL, UUID, String) async throws -> Void)?
    var acceptanceStarted: (() -> Void)?
    var acceptanceGate: CheckedContinuation<Void, Never>?
    var discardCompleted: (() -> Void)?
    lazy var owner = BrowserDownloadOwner(
        store: BrowserDownloadScratchStore(
            root: root.appendingPathComponent("scratch", isDirectory: true),
            verifyProtection: { _ in },
            remove: { [weak self] url in
                guard self?.removalFails == false else {
                    throw CocoaError(.fileWriteNoPermission)
                }

                try FileManager.default.removeItem(at: url)
            },
        ),
        protectedDataAvailable: { [weak self] in self?.protectedDataAvailable ?? false },
        backgroundExecution: .init(begin: { [weak self] expiration in
            guard let self else {
                return .invalid
            }

            backgroundBegins += 1
            backgroundExpiration = expiration
            return UIBackgroundTaskIdentifier(rawValue: backgroundBegins)
        }, end: { [weak self] in self?.backgroundEnds.append($0.rawValue) }),
        ingestion: BrowserDownloadIngestion(
            accept: { [weak self] url, id, filename in
                guard let self else {
                    throw MediaImportError.persistenceFailed
                }

                if let acceptOverride {
                    try await acceptOverride(url, id, filename)
                    return
                }

                if suspendAcceptance {
                    await withCheckedContinuation { continuation in
                        acceptanceGate = continuation
                        let started = acceptanceStarted
                        acceptanceStarted = nil
                        started?()
                    }
                }
                if let acceptanceFailure {
                    throw acceptanceFailure
                }
                let target = root.appendingPathComponent(id.uuidString)
                try FileManager.default.moveItem(at: url, to: target)
                accepted[id] = target
            },
            reconcile: { [weak self] _ in
                guard let self else {
                    return [:]
                }

                reconciliations += 1
                var results: [UUID: CompletedDownloadOutcome] = [:]
                for id in accepted.keys {
                    if importOnReconcile {
                        if canonicalURLs[id] == nil, let source = accepted[id] {
                            let target = root.appendingPathComponent("canonical-" + id.uuidString)
                            do {
                                try FileManager.default.moveItem(at: source, to: target)
                                canonicalURLs[id] = target
                            } catch {
                                results[id] = .failed(.persistenceFailed)
                                continue
                            }
                        }
                        let resources: [MediaResource] = importedUTI.map { uti in
                            [MediaResource(
                                id: id,
                                role: .original,
                                relativePath: id.uuidString,
                                sourceFilename: "image",
                                sourceUTI: uti,
                                byteCount: 2,
                                sha256: String(repeating: "0", count: 64),
                            )]
                        } ?? []
                        let asset = MediaAsset(
                            id: id,
                            kind: .stillImage,
                            importedAt: .distantPast,
                            resources: resources,
                        )
                        canonical[id] = asset
                        results[id] = .imported(asset, duplicate: false)
                    } else if unsupportedOnReconcile, let url = accepted[id] {
                        results[id] = .unsupported(url)
                    } else {
                        results[id] = .pending
                    }
                }
                return results
            },
            revoke: { [weak self] id in self?.ingestionRevocations.append(id) },
            discard: { [weak self] id in
                guard let self else {
                    throw MediaImportError.persistenceFailed
                }

                discarded.append(id)
                if let url = accepted.removeValue(forKey: id) {
                    try FileManager.default.removeItem(at: url)
                }
                let completed = discardCompleted
                discardCompleted = nil
                completed?()
            },
            storage: { [weak self] in
                guard let self else {
                    throw MediaImportError.persistenceFailed
                }

                if !storageRecovered {
                    guard !recoveryFails else {
                        throw MediaImportError.persistenceFailed
                    }

                    if let source = handoffSource {
                        let target = root.appendingPathComponent("recovered")
                        try FileManager.default.moveItem(at: source, to: target)
                        recoveredURL = target
                    }
                    storageRecovered = true
                }
                let pending = accepted.keys.filter { canonical[$0] == nil }
                let recoveredCount = (recoveredURL == nil ? 0 : 1) + extraPendingCount
                return AcceptedDownloadStorage(
                    operationCount: pending.count + recoveredCount,
                    byteCount: Int64((pending.count + recoveredCount) * 2),
                )
            },
            generation: { [weak self] in self?.processingGeneration ?? UInt64.max },
            presentationURL: { [weak self] id, generation in
                guard let self, authorized, generation == processingGeneration else {
                    return nil
                }

                return canonicalURLs[id] ?? (unsupportedOnReconcile ? accepted[id] : nil)
            },
        ),
        availableBytes: { [weak self] in self?.availableBytes },
        copyPresentationFile: { [weak self] source, destination in
            guard let self else {
                throw CocoaError(.fileWriteUnknown)
            }

            presentationCopyDestination = destination
            if presentationCopyFails {
                try Data([9]).write(to: destination)
                throw CocoaError(.fileWriteUnknown)
            }
            if suspendPresentationCopy {
                try Data([1]).write(to: destination)
                await withCheckedContinuation { continuation in
                    presentationCopyGate = continuation
                    let started = presentationCopyStarted
                    presentationCopyStarted = nil
                    started?()
                }
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: source, to: destination)
        },
    )

    init(
        priorHandoff: Bool = false,
        priorOrphan: Bool = false,
        protectionAvailable: Bool = true,
        failRecovery: Bool = false,
    ) throws {
        protectedDataAvailable = protectionAvailable
        recoveryFails = failRecovery
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for isHandoff in [true, false] where isHandoff ? priorHandoff : priorOrphan {
            let directory = root.appendingPathComponent("scratch", isDirectory: true)
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = directory.appendingPathComponent("source")
            try Data([3, 4]).write(to: file)
            if isHandoff {
                handoffSource = file
            } else {
                orphanURL = file
            }
        }
        owner.installAuthorization { [weak self] in self?.authorized ?? false }
    }

    func start(name: String = "image.png", bytes: Data = Data([1, 2])) throws -> Started {
        let transfer = IngestionTransfer()
        let tab = BrowserTabID()
        let id = try #require(owner.admit(transfer, tabID: tab))
        let url = try #require(owner.destination(for: id, suggestedName: name))
        try bytes.write(to: url)
        return Started(id: id, tabID: tab, url: url, transfer: transfer)
    }

    func removeFiles() {
        resumeAcceptance()
        resumePresentationCopy()
        owner.invalidateAuthorization()
        try? FileManager.default.removeItem(at: root)
    }

    func resumeAcceptance() {
        let gate = acceptanceGate
        acceptanceGate = nil
        gate?.resume()
    }

    func resumePresentationCopy() {
        let gate = presentationCopyGate
        presentationCopyGate = nil
        gate?.resume()
    }
}

@MainActor
private final class IngestionTransfer: BrowserDownloadTransfer {
    var identity: AnyObject {
        self
    }

    var cancellations = 0
    func cancel(completion: @MainActor () -> Void) {
        cancellations += 1
        completion()
    }
}
