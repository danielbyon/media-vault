//
//  BrowserReceiptIngestionTests.swift
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

@Suite("Browser receipt ingestion")
struct BrowserReceiptIngestionTests {
    @Test(
        "A transferred browser receipt enters the SQLite journal and reconciles unchanged bytes",
        .enabled(
            if: ProcessInfo.processInfo.environment["SPIKE_BROWSER_RECEIPT_BASE64"] != nil
                || ProcessInfo.processInfo.environment["SPIKE_BROWSER_RECEIPT_PATH"] != nil,
            "The spike runner supplies a receipt copied from the simulator app container.",
        ),
    )
    func reconcilesTransferredReceipt() async throws {
        let environment = ProcessInfo.processInfo.environment
        let bytes: Data
        if let encoded = environment["SPIKE_BROWSER_RECEIPT_BASE64"] {
            bytes = try #require(Data(base64Encoded: encoded))
        } else {
            let receiptPath = try #require(environment["SPIKE_BROWSER_RECEIPT_PATH"])
            bytes = try Data(contentsOf: URL(fileURLWithPath: receiptPath), options: [.mappedIfSafe])
        }
        #expect(!bytes.isEmpty)

        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("browser-receipt-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }

        let receiptDirectory = root.appendingPathComponent("receipt-staging", isDirectory: true)
        try fileManager.createDirectory(at: receiptDirectory, withIntermediateDirectories: true)
        let protectedReceiptURL = receiptDirectory.appendingPathComponent("selected-browser-receipt")
        try bytes.write(to: protectedReceiptURL, options: .atomic)
        #if os(iOS)
        try fileManager.setAttributes(
            [.protectionKey: FileProtectionType.completeUnlessOpen],
            ofItemAtPath: protectedReceiptURL.path,
        )
        let receiptProtection = try fileManager.attributesOfItem(atPath: protectedReceiptURL.path)[.protectionKey]
        print(
            "SPIKE4 receipt_protection_requested=completeUnlessOpen receipt_protection_actual=\(String(describing: receiptProtection))",
        )
        #endif
        #expect(try Data(contentsOf: protectedReceiptURL) == bytes)

        let databaseURL = root.appendingPathComponent("media-library.sqlite")
        let database = try PersistenceStore.makePersistent(at: databaseURL)
        defer { try? database.close() }
        let store = SQLiteMediaLibraryStore(database: database)
        let resources = try FileMediaResourceRepository(rootURL: root.appendingPathComponent("resources"))
        let assetID = UUID()
        let resourceID = UUID()
        let canonicalStagingURL = resources.stagingURL(for: resourceID)
        try bytes.write(to: canonicalStagingURL, options: .atomic)
        try resources.protectStaging(for: resourceID)
        #if os(iOS)
        let canonicalProtection = try fileManager.attributesOfItem(atPath: canonicalStagingURL.path)[.protectionKey]
        print(
            "SPIKE4 canonical_protection_requested=complete canonical_protection_actual=\(String(describing: canonicalProtection))",
        )
        #endif

        let entry = MediaIngestionJournalEntry(
            id: assetID,
            resourceID: resourceID,
            state: .received,
            sourceFilename: "browser-receipt",
            importedAt: Date(timeIntervalSince1970: 1_791_589_200),
        )
        try await store.ingestionJournal.accept(entry)
        #expect(try await store.ingestionJournal.snapshot().entries.map(\.state) == [.received])
        #expect(try await store.loadAssets().isEmpty)

        try await database.write { db in
            try db.execute(sql: "CREATE TABLE spike4_journal_transitions (state TEXT NOT NULL)")
            try db.execute(
                sql: """
                CREATE TRIGGER spike4_capture_journal_transition
                AFTER UPDATE OF state ON media_ingestion_journal
                BEGIN
                  INSERT INTO spike4_journal_transitions(state) VALUES (NEW.state);
                END
                """,
            )
        }

        let importer = MediaLibraryImporter(
            store: store,
            resources: resources,
            source: .localFile,
            id: { UUID() },
            now: { Date(timeIntervalSince1970: 1_791_589_200) },
        )
        let assets = try await importer.loadAssets()
        #expect(assets.count == 1)
        #expect(assets[0].id == assetID)
        #expect(assets[0].kind == .stillImage)
        #expect(assets[0].resources.count == 1)

        let resource = try #require(assets[0].resources.first)
        #expect(resource.byteCount == Int64(bytes.count))
        #expect(resource.sha256 == sha256(bytes))
        #expect(try resources.data(for: resource) == bytes)
        #expect(try Data(contentsOf: resources.url(for: resource)) == bytes)
        #expect(try await store.loadAssets() == assets)

        let transitions = try await database.read { db in
            try String.fetchAll(db, sql: "SELECT state FROM spike4_journal_transitions ORDER BY rowid")
        }
        #expect(transitions == ["validating", "duplicateCheck", "ready", "committing", "complete"])
        #expect(try await store.ingestionJournal.snapshot().entries.isEmpty)
        #expect(fileManager.fileExists(atPath: databaseURL.path))

        try database.close()
        let reopenedDatabase = try PersistenceStore.makePersistent(at: databaseURL)
        defer { try? reopenedDatabase.close() }
        let reopenedStore = SQLiteMediaLibraryStore(database: reopenedDatabase)
        #expect(try await reopenedStore.loadAssets() == assets)
        #expect(try await reopenedStore.ingestionJournal.snapshot().entries.isEmpty)
    }
}

private func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}
