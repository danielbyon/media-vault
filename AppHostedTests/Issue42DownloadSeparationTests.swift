//
//  Issue42DownloadSeparationTests.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import AppFeature
import Foundation
import MediaLibrary
import Testing
import VaultFeature
@testable import BrowserFeature

// File-protection attributes are only observable on a physical device. The simulator run
// still checks file identity, size, and backup exclusion through the injected verifier.
#if targetEnvironment(simulator)
private let issue42ProtectionReadbackSupported = false
#else
private let issue42ProtectionReadbackSupported = true
#endif

extension AppHostedUITests {
    /// Keeps downloads, Browser preferences, tabs, and Library imports in separate persistence domains.
    @Suite(
        "Issue 42 download persistence separation",
        .serialized,
    )
    @MainActor
    struct Issue42DownloadSeparationTests {
        @Test(
            "Completed WebKit files retain protection and backup exclusion",
            .enabled(
                if: issue42ProtectionReadbackSupported,
                "Skip on simulator: file-protection attributes only persist on a physical iPhone.",
            ),
        )
        func completedFilesRetainProtectionAndBackupExclusion() async throws {
            try await withIssue42DownloadSeparationFixture { fixture in
                let id = try await fixture.completeDownload(
                    url: fixture.pdfServer.url("attachment"),
                    bytes: fixture.pdfServer.payload,
                    filename: "fixture.pdf",
                )
                let file = fixture.scratch.allocation(id: id, suggestedName: "fixture.pdf").destination
                let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
                #expect(attributes[.protectionKey] as? FileProtectionType == .complete)
                let values = try file.resourceValues(forKeys: [.isExcludedFromBackupKey])
                #expect(values.isExcludedFromBackup == true)
            }
        }

        @Test("PDF and image completion, discard, and cancellation leave app persistence unchanged")
        func downloadTransitionsLeaveAppPersistenceUnchanged() async throws {
            try await withIssue42DownloadSeparationFixture { fixture in
                let baseline = try await fixture.checkpoint()
                #expect(fixture.rootStore?.vault.shell.library.assets.isEmpty == true)
                #expect(fixture.owner.snapshot.records.isEmpty)
                #expect(fixture.importRecorder.importFileCalls.isEmpty)

                let pdfID = try await fixture.completeDownload(
                    url: fixture.pdfServer.url("attachment"),
                    bytes: fixture.pdfServer.payload,
                    filename: "fixture.pdf",
                )
                try await fixture.assertUnchanged(baseline)
                #expect(fixture.importRecorder.importFileCalls.isEmpty)
                try await fixture.discard(pdfID, filename: "fixture.pdf")
                try await fixture.assertUnchanged(baseline)

                let imageID = try await fixture.completeDownload(
                    url: fixture.pdfServer.url("image"),
                    bytes: fixture.pdfServer.imageBytes,
                    filename: "valid-image.png",
                )
                #expect(fixture.pdfServer.requests.contains { $0.path.hasSuffix("/image") })
                try await fixture.assertUnchanged(baseline)
                #expect(fixture.importRecorder.importFileCalls.isEmpty)
                try await fixture.discard(imageID, filename: "valid-image.png")
                try await fixture.assertUnchanged(baseline)

                try await fixture.cancelSlowDownload()
                try await fixture.assertUnchanged(baseline)
                #expect(fixture.importRecorder.importFileCalls.isEmpty)

                try await fixture.reconstructRoot()
                #expect(fixture.importRecorder.importFileCalls.isEmpty)
            }
        }

        /// Positive control: the recorder observes the dependency the application actually uses.
        ///
        /// This deliberately invokes importFile through the client injected into Root, so an
        /// empty import transcript in the download test above cannot come from a broken observer.
        /// The client records and fails instead of forwarding to a real importer, so no library
        /// work happens on the fixture's behalf.
        @Test("Import dependency recorder observes a direct importFile call")
        func importDependencyRecorderObservesDirectOperations() async throws {
            try await withIssue42DownloadSeparationFixture { fixture in
                #expect(fixture.importRecorder.importFileCalls.isEmpty)

                await #expect(throws: MediaImportError.persistenceFailed) {
                    try await fixture.mediaLibraryClient.importFile(URL(fileURLWithPath: "/dev/null"))
                }

                #expect(fixture.importRecorder.importFileCalls == ["importFile"])
            }
        }
    }
}
