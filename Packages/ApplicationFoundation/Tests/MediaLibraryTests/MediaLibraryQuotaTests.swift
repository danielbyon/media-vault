//
//  MediaLibraryQuotaTests.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Entitlement
import Foundation
import PersistenceSupport
import Testing
@testable import MediaLibrary

@Suite("Media library quota")
struct MediaLibraryQuotaTests {
    @Test("Import policy requires entitlement lookup only from 50 logical assets", arguments: [
        QuotaBoundaryCase(committedAssetCount: 0, requiresEntitlementLookup: false),
        QuotaBoundaryCase(committedAssetCount: 49, requiresEntitlementLookup: false),
        QuotaBoundaryCase(committedAssetCount: 50, requiresEntitlementLookup: true),
        QuotaBoundaryCase(committedAssetCount: 51, requiresEntitlementLookup: true),
    ])
    func entitlementLookupStartsAtFreeLimit(_ testCase: QuotaBoundaryCase) {
        #expect(
            MediaLibraryQuota.requiresEntitlementLookup(
                forCommittedAssetCount: testCase.committedAssetCount,
            ) == testCase.requiresEntitlementLookup,
        )
    }

    @Test("Import policy admits only verified Pro at the free boundary", arguments: [
        QuotaAdmissionCase(committedAssetCount: 0, entitlementState: .notEntitled, admitted: true),
        QuotaAdmissionCase(committedAssetCount: 49, entitlementState: .notEntitled, admitted: true),
        QuotaAdmissionCase(committedAssetCount: 50, entitlementState: .entitled, admitted: true),
        QuotaAdmissionCase(committedAssetCount: 50, entitlementState: .notEntitled, admitted: false),
        QuotaAdmissionCase(committedAssetCount: 50, entitlementState: .revoked, admitted: false),
        QuotaAdmissionCase(committedAssetCount: 51, entitlementState: .entitled, admitted: true),
        QuotaAdmissionCase(committedAssetCount: 51, entitlementState: .notEntitled, admitted: false),
    ])
    func verifiesEntitlementAtFreeLimit(_ testCase: QuotaAdmissionCase) {
        #expect(
            MediaLibraryQuota.admitsNewImport(
                committedAssetCount: testCase.committedAssetCount,
                entitlementState: testCase.entitlementState,
            ) == testCase.admitted,
        )
    }

    @Test("A fresh database has no committed logical assets")
    func freshDatabaseCountsZero() async throws {
        let store = try SQLiteMediaLibraryStore(database: PersistenceStore.makeInMemory())

        #expect(try await store.logicalAssetCount() == 0)
    }

    @Test("Multiple resources count as one committed logical asset")
    func multipleResourcesCountOnce() async throws {
        let store = try SQLiteMediaLibraryStore(database: PersistenceStore.makeInMemory())
        try await store.commit(QuotaFixtures.assetWithTwoResources)

        #expect(try await store.logicalAssetCount() == 1)
    }
}

struct QuotaBoundaryCase: Sendable {
    let committedAssetCount: Int
    let requiresEntitlementLookup: Bool
}

struct QuotaAdmissionCase: Sendable {
    let committedAssetCount: Int
    let entitlementState: ProEntitlementState
    let admitted: Bool
}

private enum QuotaFixtures {
    static let assetID = requiredUUID("00000000-0000-0000-0000-000000000050")
    static let firstResourceID = requiredUUID("00000000-0000-0000-0000-000000000051")
    static let secondResourceID = requiredUUID("00000000-0000-0000-0000-000000000052")
    static let importedAt = Date(timeIntervalSince1970: 1_725_000_000)

    static let assetWithTwoResources = MediaAsset(
        id: assetID,
        kind: .stillImage,
        importedAt: importedAt,
        resources: [
            resource(
                id: firstResourceID,
                relativePath: "first",
                sourceFilename: "first.png",
                byteCount: 4,
            ),
            resource(
                id: secondResourceID,
                relativePath: "second",
                sourceFilename: "second.png",
                byteCount: 8,
            ),
        ],
    )

    private static func resource(
        id: UUID,
        relativePath: String,
        sourceFilename: String,
        byteCount: Int64,
    ) -> MediaResource {
        MediaResource(
            id: id,
            role: .original,
            relativePath: relativePath,
            sourceFilename: sourceFilename,
            sourceUTI: "public.png",
            byteCount: byteCount,
            sha256: String(repeating: "0", count: 64),
        )
    }
}

private func requiredUUID(_ string: String) -> UUID {
    guard let uuid = UUID(uuidString: string) else {
        preconditionFailure("Invalid deterministic UUID: \(string)")
    }

    return uuid
}
