//
//  BrowserDownloadPersistenceIsolationTests.swift
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
private let protectionReadbackSupported = false
#else
private let protectionReadbackSupported = true
#endif

extension AppHostedUITests {
    /// Keeps downloads, Browser preferences, tabs, and Library imports in separate persistence domains.
    @Suite(
        "Browser download persistence isolation",
        .serialized,
    )
    @MainActor
    struct BrowserDownloadPersistenceIsolationTests {
        @Test("Download completion requires preview projection settlement")
        func downloadCompletionRequiresPreviewProjectionSettlement() {
            let operation = BrowserNavigationOperationID()
            #expect(
                !DownloadSeparationTestSupport.downloadCompletionIsSettled(
                    hasReadyRecord: false,
                    previewOperation: nil,
                ),
            )
            #expect(
                !DownloadSeparationTestSupport.downloadCompletionIsSettled(
                    hasReadyRecord: true,
                    previewOperation: operation,
                ),
            )
            #expect(
                DownloadSeparationTestSupport.downloadCompletionIsSettled(
                    hasReadyRecord: true,
                    previewOperation: nil,
                ),
            )
        }

        @Test(
            "Completed WebKit files retain protection and backup exclusion",
            .enabled(
                if: protectionReadbackSupported,
                "Skip on simulator: file-protection attributes only persist on a physical iPhone.",
            ),
        )
        func completedFilesRetainProtectionAndBackupExclusion() async throws {
            try await withBrowserDownloadPersistenceFixture { fixture in
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
            try await withBrowserDownloadPersistenceFixture { fixture in
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
            try await withBrowserDownloadPersistenceFixture { fixture in
                #expect(fixture.importRecorder.importFileCalls.isEmpty)

                await #expect(throws: MediaImportError.persistenceFailed) {
                    try await fixture.mediaLibraryClient.importFile(URL(fileURLWithPath: "/dev/null"))
                }

                #expect(fixture.importRecorder.importFileCalls == ["importFile"])
            }
        }
    }
}

/// Regression tests for the semantic defaults-domain comparator used by persistence assertions.
///
/// The comparator backs download-separation assertions, so these tests pin dictionary-order
/// independence, nested value equality, boolean versus numeric distinction, and the
/// added/removed/changed diagnostics that may expose key names and value type names only.
@Suite("Defaults domain snapshot comparison")
struct DefaultsDomainSnapshotTests {
    @Test("Comparison ignores dictionary ordering")
    func comparisonIgnoresDictionaryOrdering() {
        let first = DefaultsDomainSnapshot(domain: [
            "alpha": "one",
            "beta": 1,
        ])
        let second = DefaultsDomainSnapshot(domain: [
            "beta": 1,
            "alpha": "one",
        ])
        #expect(first == second)
        #expect(first.difference(from: second).isEmpty)
    }

    @Test("Nested arrays and dictionaries compare by value")
    func nestedCollectionsCompareByValue() {
        let list: [Any] = [["id": 1], ["id": 2]]
        let mapping: [String: Any] = ["enabled": true, "count": 3]
        let baseline = DefaultsDomainSnapshot(domain: ["list": list, "map": mapping])

        let reorderedList: [Any] = [["id": 1], ["id": 2]]
        let reorderedMapping: [String: Any] = ["count": 3, "enabled": true]
        let identical = DefaultsDomainSnapshot(domain: ["map": reorderedMapping, "list": reorderedList])
        #expect(baseline == identical)
        #expect(baseline.difference(from: identical).isEmpty)

        let mutatedList: [Any] = [["id": 1], ["id": 2], ["id": 3]]
        let changed = DefaultsDomainSnapshot(domain: ["list": mutatedList, "map": mapping])
        #expect(changed.difference(from: baseline).changed == ["list:Array->Array"])
    }

    @Test("Boolean and numeric values stay distinguishable")
    func booleanAndNumericValuesStayDistinguishable() {
        let boolean = DefaultsDomainSnapshot(domain: ["flag": true])
        let integer = DefaultsDomainSnapshot(domain: ["flag": Int64(1)])
        #expect(boolean != integer)
        #expect(integer.difference(from: boolean).changed == ["flag:Bool->Int"])

        let float = DefaultsDomainSnapshot(domain: ["flag": Double(1.5)])
        #expect(float.entries["flag"]?.typeName == "Double")
        #expect(float.difference(from: integer).changed == ["flag:Int->Double"])

        let integralDouble = DefaultsDomainSnapshot(domain: ["flag": Double(2.0)])
        let integralInteger = DefaultsDomainSnapshot(domain: ["flag": Int64(2)])
        #expect(integralDouble.entries["flag"]?.typeName == "Double")
        #expect(integralDouble != integralInteger)
        #expect(integralDouble.difference(from: integralInteger).changed == ["flag:Int->Double"])

        let smaller = DefaultsDomainSnapshot(domain: ["flag": Float(1.25)])
        let larger = DefaultsDomainSnapshot(domain: ["flag": Float(1.75)])
        #expect(smaller != larger)
        #expect(smaller.difference(from: larger).changed == ["flag:Double->Double"])

        let signedNegative = DefaultsDomainSnapshot(domain: ["count": Int64(-1)])
        let unsignedMaximum = DefaultsDomainSnapshot(domain: ["count": UInt64.max])
        #expect(signedNegative != unsignedMaximum)
        #expect(signedNegative.difference(from: unsignedMaximum).changed == ["count:UInt->Int"])

        let signedFive = DefaultsDomainSnapshot(domain: ["count": Int64(5)])
        let unsignedFive = DefaultsDomainSnapshot(domain: ["count": UInt64(5)])
        #expect(signedFive == unsignedFive)
    }

    @Test("Difference reports added, removed, and changed keys with type names only")
    func differenceReportsKeyNamesAndTypeNamesOnly() {
        let baseline = DefaultsDomainSnapshot(domain: [
            "kept": "same",
            "removed": Int64(1),
            "changed": "before",
        ])
        let current = DefaultsDomainSnapshot(domain: [
            "kept": "same",
            "changed": Int64(2),
            "added": true,
        ])
        let difference = current.difference(from: baseline)
        #expect(!difference.isEmpty)
        #expect(difference.added == ["added:Bool"])
        #expect(difference.removed == ["removed:Int"])
        #expect(difference.changed == ["changed:String->Int"])
        #expect(difference.summary == "added [added:Bool]; removed [removed:Int]; changed [changed:String->Int]")
    }

    @Test("Data values compare by content and never render content")
    func dataValuesCompareByContentOnly() {
        let first = DefaultsDomainSnapshot(domain: ["blob": Data([0x01, 0x02])])
        let second = DefaultsDomainSnapshot(domain: ["blob": Data([0x01, 0x02])])
        let third = DefaultsDomainSnapshot(domain: ["blob": Data([0x01, 0x03])])
        #expect(first == second)
        #expect(first.difference(from: second).isEmpty)
        let difference = third.difference(from: first)
        #expect(difference == DefaultsDomainDifference(added: [], removed: [], changed: ["blob:Data->Data"]))
        #expect(difference.summary == "changed [blob:Data->Data]")
    }
}
