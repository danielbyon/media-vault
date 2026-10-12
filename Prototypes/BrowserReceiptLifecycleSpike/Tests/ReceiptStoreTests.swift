//
//  ReceiptStoreTests.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import CryptoKit
import Foundation
import Testing
#if canImport(Darwin)
import Darwin
#endif
@testable import ReceiptLifecycle

@Suite("Protected receipt publication")
struct ReceiptStoreTests {
    @Test("Exclusive receipt creation keeps its original writable descriptor open")
    func protectedDescriptorLifetime() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ReceiptStore(rootURL: root)
        let provisional = store.receiptDirectoryURL.appendingPathComponent(UUID().uuidString + ".partial")
        let handle = try store.openProtectedProvisional(at: provisional)
        #expect(fcntl(handle.fileDescriptor, F_GETFD) >= 0)
        #expect(try provisional.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
        #expect(throws: ReceiptStoreError.duplicateIdentity) {
            _ = try store.openProtectedProvisional(at: provisional)
        }
        try handle.write(contentsOf: Data([0x52]))
        try handle.synchronize()
        let descriptor = handle.fileDescriptor
        try handle.close()
        #expect(fcntl(descriptor, F_GETFD) == -1)
        #expect(try Data(contentsOf: provisional) == Data([0x52]))
    }

    @Test("A published receipt survives coordinator recreation and repeated recovery")
    func publication() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("input")
        let bytes = Data(repeating: 0x47, count: 32_768)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try bytes.write(to: input)
        let identity = ReceiptIdentity(transferID: UUID(), assetID: UUID(), resourceID: UUID())
        let store = try ReceiptStore(rootURL: root.appendingPathComponent("receipts"))
        #expect(store.receiptDirectoryURL != store.metadataDirectoryURL)
        let receipt = try store.publish(from: input, identity: identity, expectedByteCount: Int64(bytes.count))
        #expect(try store.rootURL.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
        #expect(try store.receiptURL(for: receipt)
            .resourceValues(forKeys: [.isExcludedFromBackupKey])
            .isExcludedFromBackup == true)
        let metadataURL = store.metadataDirectoryURL.appendingPathComponent(
            identity.resourceID.uuidString.lowercased() + ".manifest",
        )
        #expect(try metadataURL.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
        #expect(receipt.identity == identity)
        #expect(receipt.byteCount == Int64(bytes.count))
        #expect(receipt.sha256 == SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
        #expect(throws: ReceiptStoreError.duplicateIdentity) {
            try store.publish(from: input, identity: identity, expectedByteCount: Int64(bytes.count))
        }
        #expect(try store.discoverMetadata() == [receipt])

        let restarted = try ReceiptStore(rootURL: root.appendingPathComponent("receipts"))
        #expect(try restarted.discoverMetadata() == [receipt])
        #expect(try restarted.verifyAfterUnlock(receipt) == true)
        #expect(try restarted.discoverMetadata() == [receipt])
        #expect(restarted.receiptURL(for: receipt).deletingLastPathComponent() == restarted.receiptDirectoryURL)
        try Data(repeating: 0x42, count: bytes.count).write(to: restarted.receiptURL(for: receipt))
        #expect(try restarted.verifyAfterUnlock(receipt) == false)
    }

    @Test("Every prepublication interruption remains unaccepted", arguments: ReceiptCheckpoint.allCases)
    func prepublicationInterruption(checkpoint: ReceiptCheckpoint) throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let input = root.appendingPathComponent("input")
        try Data(repeating: 0x19, count: 8_192).write(to: input)
        let store = try ReceiptStore(rootURL: root.appendingPathComponent("receipts"))
        let identity = ReceiptIdentity(transferID: UUID(), assetID: UUID(), resourceID: UUID())
        #expect(throws: InjectedInterruption.self) {
            try store.publish(from: input, identity: identity, expectedByteCount: 8_192) { reached in
                if reached == checkpoint {
                    throw InjectedInterruption()
                }
            }
        }
        let restarted = try ReceiptStore(rootURL: root.appendingPathComponent("receipts"))
        let discovered = try restarted.discoverMetadata()
        #expect(discovered.isEmpty || checkpoint == .afterPublication)
        if checkpoint == .afterPublication {
            #expect(discovered.count == 1)
            #expect(try restarted.verifyAfterUnlock(discovered[0]))
        } else {
            let inventory = try restarted.inspectRecovery()
            #expect(inventory.acceptedCount == 0)
            if checkpoint == .beforeProtectedCreate {
                #expect(inventory.unacceptedArtifactCount == 0)
            } else {
                #expect(inventory.unacceptedArtifactCount > 0)
            }
            try restarted.reconcileUnacceptedArtifacts()
            #expect(try restarted.inspectRecovery().unacceptedArtifactCount == 0)
        }
    }

    @Test("Temporary bytes lost before materialization cannot become an accepted receipt")
    func temporaryFileLostBeforePreservation() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let temporaryDownload = root.appendingPathComponent("urlsession-temporary")
        let bytes = Data(repeating: 0x36, count: 4_096)
        try bytes.write(to: temporaryDownload)
        let store = try ReceiptStore(rootURL: root.appendingPathComponent("receipts"))
        let identity = ReceiptIdentity(transferID: UUID(), assetID: UUID(), resourceID: UUID())
        #expect(throws: InjectedInterruption.self) {
            try store.publish(
                from: temporaryDownload,
                identity: identity,
                expectedByteCount: Int64(bytes.count),
            ) { checkpoint in
                if checkpoint == .beforeProtectedCreate {
                    throw InjectedInterruption()
                }
            }
        }
        try FileManager.default.removeItem(at: temporaryDownload)
        let restarted = try ReceiptStore(rootURL: root.appendingPathComponent("receipts"))
        #expect(try restarted.discoverMetadata().isEmpty)
        #expect(try restarted.inspectRecovery().acceptedCount == 0)
    }

    @Test("A published receipt survives loss of URLSession's temporary file and callback")
    func temporaryFileLostAfterPreservation() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let temporaryDownload = root.appendingPathComponent("urlsession-temporary")
        let bytes = Data(repeating: 0x36, count: 4_096)
        try bytes.write(to: temporaryDownload)
        let store = try ReceiptStore(rootURL: root.appendingPathComponent("receipts"))
        let identity = ReceiptIdentity(transferID: UUID(), assetID: UUID(), resourceID: UUID())
        #expect(throws: InjectedInterruption.self) {
            try store.publish(
                from: temporaryDownload,
                identity: identity,
                expectedByteCount: Int64(bytes.count),
            ) { checkpoint in
                if checkpoint == .afterPublication {
                    throw InjectedInterruption()
                }
            }
        }
        try FileManager.default.removeItem(at: temporaryDownload)
        let restarted = try ReceiptStore(rootURL: root.appendingPathComponent("receipts"))
        let discovered = try restarted.discoverMetadata()
        #expect(discovered.count == 1)
        let manifest = try #require(discovered.first)
        #expect(manifest.identity == identity)
        #expect(try restarted.verifyAfterUnlock(manifest))
        try restarted.reconcileUnacceptedArtifacts()
        #expect(try restarted.discoverMetadata() == [manifest])
    }

    @Test("Truncation cannot publish an accepted receipt")
    func truncated() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let input = root.appendingPathComponent("input")
        try Data(repeating: 0x19, count: 32).write(to: input)
        let store = try ReceiptStore(rootURL: root.appendingPathComponent("receipts"))
        let identity = ReceiptIdentity(transferID: UUID(), assetID: UUID(), resourceID: UUID())
        #expect(throws: ReceiptStoreError.self) {
            try store.publish(from: input, identity: identity, expectedByteCount: 64)
        }
        #expect(try store.discoverMetadata().isEmpty)
        #expect(try store.inspectRecovery().unacceptedArtifactCount == 0)
    }

    @Test("A provisional path lost during streaming fails without accepting bytes")
    func lostProvisionalPath() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let input = root.appendingPathComponent("input")
        try Data(repeating: 0x51, count: 128).write(to: input)
        let store = try ReceiptStore(rootURL: root.appendingPathComponent("receipts"))
        let identity = ReceiptIdentity(transferID: UUID(), assetID: UUID(), resourceID: UUID())
        #expect(throws: (any Error).self) {
            try store.publish(from: input, identity: identity, expectedByteCount: 128) { checkpoint in
                if checkpoint == .afterProtectedCreate {
                    let provisional = store.receiptDirectoryURL.appendingPathComponent(
                        identity.resourceID.uuidString.lowercased() + ".partial",
                    )
                    try FileManager.default.removeItem(at: provisional)
                }
            }
        }
        #expect(try store.discoverMetadata().isEmpty)
        #expect(try store.inspectRecovery().unacceptedArtifactCount == 0)
    }

    @Test("Malformed published metadata is not accepted or silently deleted")
    func invalidMetadata() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ReceiptStore(rootURL: root)
        let metadata = store.metadataDirectoryURL.appendingPathComponent(UUID().uuidString.lowercased() + ".manifest")
        try Data("{incomplete".utf8).write(to: metadata)
        #expect(try store.discoverMetadata().isEmpty)
        let inventory = try store.inspectRecovery()
        #expect(inventory.invalidMetadataCount == 1)
        try store.reconcileUnacceptedArtifacts()
        #expect(FileManager.default.fileExists(atPath: metadata.path))
    }

    @Test("An empty child probes directory protection inheritance")
    func inheritanceProbe() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ReceiptStore(rootURL: root)
        let result = try store.probeProtectionInheritance()
        #expect(!result.isEmpty)
        #expect(try FileManager.default
            .contentsOfDirectory(
                at: store.receiptDirectoryURL,
                includingPropertiesForKeys: nil,
            )
            .isEmpty)
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }
}
