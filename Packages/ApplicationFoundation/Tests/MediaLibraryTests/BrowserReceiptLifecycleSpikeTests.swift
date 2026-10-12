//
//  BrowserReceiptLifecycleSpikeTests.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import CryptoKit
import Foundation
import GRDB
import PersistenceSupport
import Testing
@testable import MediaLibrary

/// Test-only handoff from an exported Spike 6 host receipt to the existing journal.
/// The runner copies bytes between containers; this does not prove an in-app
/// production handoff or preserve the source file's Data Protection attributes.
@Suite("Browser receipt lifecycle handoff")
struct BrowserReceiptLifecycleSpikeTests {
    @Test(
        "Fresh stores recover one asset after each receipt-to-journal interruption",
        arguments: ReceiptJournalBoundary.allCases,
    )
    func recoversReceiptJournalBoundary(_ boundary: ReceiptJournalBoundary) async throws {
        let root = FileManager.default
            .temporaryDirectory
            .appendingPathComponent("spike6-boundary-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let bytes = try #require(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="))
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let assetID = UUID()
        let resourceID = UUID()
        let receiptDirectory = root.appendingPathComponent("receipt", isDirectory: true)
        try FileManager.default.createDirectory(at: receiptDirectory, withIntermediateDirectories: true)
        let receiptURL = receiptDirectory.appendingPathComponent("\(resourceID.uuidString).receipt")
        let manifestURL = receiptDirectory.appendingPathComponent("\(resourceID.uuidString).manifest")
        try bytes.write(to: receiptURL)
        try Data("\(resourceID.uuidString):\(bytes.count):\(digest)".utf8).write(to: manifestURL)

        // This synthetic gate validates the copied receipt before constructing SQLite.
        #expect(try Data(contentsOf: receiptURL) == bytes)
        #expect(SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() == digest)
        let resources = try FileMediaResourceRepository(rootURL: root.appendingPathComponent("resources"))
        let databaseURL = root.appendingPathComponent("library.sqlite")
        let firstConnection = try PersistenceStore.makePersistent(at: databaseURL)
        let firstStore = SQLiteMediaLibraryStore(database: firstConnection)
        var entry = MediaIngestionJournalEntry(
            id: assetID,
            resourceID: resourceID,
            state: .received,
            sourceFilename: "fixture.png",
            importedAt: Date(timeIntervalSince1970: 1_791_589_200),
        )
        if boundary != .beforeReceived {
            try bytes.write(to: resources.stagingURL(for: resourceID))
            try resources.protectStaging(for: resourceID)
            try await firstStore.ingestionJournal.accept(entry)
        }
        if boundary == .afterValidation || boundary == .afterCanonicalCommit || boundary == .afterReceiptCleanup {
            entry = try await firstStore.ingestionJournal.transition(entry, to: .validating)
            let inspection = ImageInspection(
                uti: "public.png",
                byteCount: Int64(bytes.count),
                sha256: digest,
                capturedAt: nil,
            )
            entry = try await firstStore.ingestionJournal.transition(
                entry,
                to: .duplicateCheck,
                inspection: inspection,
            )
        }
        if boundary == .afterCanonicalCommit || boundary == .afterReceiptCleanup {
            entry = try await firstStore.ingestionJournal.transition(entry, to: .ready)
            entry = try await firstStore.ingestionJournal.transition(entry, to: .committing)
            _ = try resources.promoteOrVerify(
                stagingURL: resources.stagingURL(for: resourceID),
                resourceID: resourceID,
                byteCount: Int64(bytes.count),
                sha256: digest,
            )
            try await firstStore.commit(
                makeSpike6Asset(from: entry),
                completingIngestion: entry.id,
            )
            let committedEntries = try await firstStore.ingestionJournal.snapshot().entries
            #expect(committedEntries.count == 1)
            #expect(committedEntries[0].state == .complete)
        }
        if boundary == .afterReceiptCleanup {
            try FileManager.default.removeItem(at: receiptURL)
            try FileManager.default.removeItem(at: manifestURL)
        }
        if boundary != .afterCanonicalCommit, boundary != .afterReceiptCleanup {
            #expect(try await firstStore.loadAssets().isEmpty)
        }
        try firstConnection.close()

        // Reconstruct storage after the injected process boundary, then reconcile twice.
        let secondConnection = try PersistenceStore.makePersistent(at: databaseURL)
        let secondStore = SQLiteMediaLibraryStore(database: secondConnection)
        let reopenedResources = try FileMediaResourceRepository(rootURL: root.appendingPathComponent("resources"))
        if boundary == .beforeReceived {
            #expect(try await secondStore.loadAssets().isEmpty)
            #expect(try await secondStore.ingestionJournal.snapshot().entries.isEmpty)
            try Data(contentsOf: receiptURL).write(to: reopenedResources.stagingURL(for: resourceID))
            try reopenedResources.protectStaging(for: resourceID)
            try await secondStore.ingestionJournal.accept(entry)
        }
        let importer = MediaLibraryImporter(store: secondStore, resources: reopenedResources, source: .localFile)
        let firstLoad = try await importer.loadAssets()
        #expect(firstLoad.count == 1)
        let asset = try #require(firstLoad.first)
        #expect(asset.id == assetID)
        let resource = try #require(asset.resources.first)
        #expect(resource.id == resourceID)
        #expect(resource.byteCount == Int64(bytes.count))
        #expect(resource.sha256 == digest)
        #expect(try reopenedResources.data(for: resource) == bytes)
        #expect(try await importer.loadAssets() == [asset])
        #expect(try await secondStore.ingestionJournal.snapshot().entries.isEmpty)
        if FileManager.default.fileExists(atPath: receiptURL.path) {
            try FileManager.default.removeItem(at: receiptURL)
            try FileManager.default.removeItem(at: manifestURL)
        }
        try secondConnection.close()

        let thirdConnection = try PersistenceStore.makePersistent(at: databaseURL)
        defer { try? thirdConnection.close() }
        let thirdStore = SQLiteMediaLibraryStore(database: thirdConnection)
        let thirdImporter = MediaLibraryImporter(store: thirdStore, resources: reopenedResources, source: .localFile)
        #expect(try await thirdImporter.loadAssets() == [asset])
        #expect(!FileManager.default.fileExists(atPath: receiptURL.path))
        #expect(!FileManager.default.fileExists(atPath: manifestURL.path))
    }

    @Test(
        "A verified host receipt enters one journal and commits exactly once",
        .enabled(
            if: ProcessInfo.processInfo.environment["SPIKE6_RECEIPT_MANIFEST_BASE64"] != nil
                && ProcessInfo.processInfo.environment["SPIKE6_RECEIPT_FILE_BASE64"] != nil,
            "The spike runner supplies a simulator receipt and its matching manifest.",
        ),
    )
    func authenticatedHandoff() async throws {
        let environment = ProcessInfo.processInfo.environment
        let encodedManifest = try #require(environment["SPIKE6_RECEIPT_MANIFEST_BASE64"])
        let encodedReceipt = try #require(environment["SPIKE6_RECEIPT_FILE_BASE64"])
        let manifestData = try #require(Data(base64Encoded: encodedManifest))
        let manifest = try JSONDecoder().decode(
            ExportedReceipt.self,
            from: manifestData,
        )
        let bytes = try #require(Data(base64Encoded: encodedReceipt))
        #expect(Int64(bytes.count) == manifest.byteCount)
        #expect(SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() == manifest.sha256)
        #expect(manifest.identity.transferID != manifest.identity.assetID)
        #expect(manifest.identity.assetID != manifest.identity.resourceID)

        // Nothing in this test constructs SQLite until the explicit runner gate
        // has supplied both paths and verified their identity and exact bytes.
        let root = FileManager.default
            .temporaryDirectory
            .appendingPathComponent("spike6-journal-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let resources = try FileMediaResourceRepository(rootURL: root.appendingPathComponent("resources"))
        let stagingURL = resources.stagingURL(for: manifest.identity.resourceID)
        try bytes.write(to: stagingURL)
        try resources.protectStaging(for: manifest.identity.resourceID)

        let databaseURL = root.appendingPathComponent("library.sqlite")
        let firstConnection = try PersistenceStore.makePersistent(at: databaseURL)
        let firstStore = SQLiteMediaLibraryStore(database: firstConnection)
        let entry = MediaIngestionJournalEntry(
            id: manifest.identity.assetID,
            resourceID: manifest.identity.resourceID,
            state: .received,
            sourceFilename: manifest.identity.resourceID.uuidString.lowercased(),
            importedAt: Date(timeIntervalSince1970: 1_791_589_200),
        )
        try await firstStore.ingestionJournal.accept(entry)
        #expect(try await firstStore.loadAssets().isEmpty)
        #expect(try await firstStore.ingestionJournal.snapshot().entries.map(\.state) == [.received])
        try firstConnection.close()

        // A fresh SQLite connection and importer model an interrupted process
        // after .received insertion, before validation or canonical commit.
        let secondConnection = try PersistenceStore.makePersistent(at: databaseURL)
        defer { try? secondConnection.close() }
        let secondStore = SQLiteMediaLibraryStore(database: secondConnection)
        let importer = MediaLibraryImporter(store: secondStore, resources: resources, source: .localFile)
        let assets = try await importer.loadAssets()
        #expect(assets.count == 1)
        let asset = try #require(assets.first)
        #expect(asset.id == manifest.identity.assetID)
        let resource = try #require(asset.resources.first)
        #expect(resource.id == manifest.identity.resourceID)
        #expect(resource.byteCount == manifest.byteCount)
        #expect(resource.sha256 == manifest.sha256)
        #expect(try resources.data(for: resource) == bytes)
        let canonicalURL = resources.url(for: resource)
        let canonicalAttributes = try FileManager.default.attributesOfItem(atPath: canonicalURL.path)
        if let reported = canonicalAttributes[.protectionKey] {
            let raw = (reported as? FileProtectionType)?.rawValue ?? (reported as? String)
            #expect(raw == FileProtectionType.complete.rawValue)
        }
        #expect(try await importer.loadAssets() == assets)
        #expect(try await secondStore.ingestionJournal.snapshot().entries.isEmpty)
    }
}

/// Process-stop positions in the test-only receipt-to-journal handoff.
enum ReceiptJournalBoundary: CaseIterable {
    case beforeReceived
    case afterReceived
    case afterValidation
    case afterCanonicalCommit
    case afterReceiptCleanup
}

/// Builds the canonical row used to model a stop after file promotion and SQLite commit.
private func makeSpike6Asset(from entry: MediaIngestionJournalEntry) throws -> MediaAsset {
    guard let sourceUTI = entry.sourceUTI,
          let byteCount = entry.byteCount,
          let sha256 = entry.sha256 else {
        throw MediaLibraryStoreError.corrupt
    }

    let resource = MediaResource(
        id: entry.resourceID,
        role: .original,
        relativePath: entry.resourceID.uuidString.lowercased(),
        sourceFilename: entry.sourceFilename,
        sourceUTI: sourceUTI,
        byteCount: byteCount,
        sha256: sha256,
    )
    return MediaAsset(
        id: entry.id,
        kind: .stillImage,
        importedAt: entry.importedAt,
        resources: [resource],
        capturedAt: entry.capturedAt,
    )
}

private struct ExportedReceipt: Decodable {
    let identity: Identity
    let byteCount: Int64
    let sha256: String

    struct Identity: Decodable {
        let transferID: UUID
        let assetID: UUID
        let resourceID: UUID
    }
}
