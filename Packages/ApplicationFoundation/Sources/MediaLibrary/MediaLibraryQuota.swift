//
//  MediaLibraryQuota.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Entitlement

/// Limits applied when admitting a newly committed logical asset.
public enum MediaLibraryQuota {
    /// Maximum number of committed assets available without Pro.
    ///
    /// A logical asset counts once regardless of its resource count or byte
    /// size. The cap applies to new imports only; saved assets and their read,
    /// export, and delete behavior remain available.
    public static let freeLogicalAssetLimit = 50

    /// Returns whether new-import admission must verify Pro entitlement.
    static func requiresEntitlementLookup(forCommittedAssetCount count: Int) -> Bool {
        count >= freeLogicalAssetLimit
    }

    /// Returns whether the committed count and verified entitlement admit an import.
    static func admitsNewImport(
        committedAssetCount: Int,
        entitlementState: ProEntitlementState,
    ) -> Bool {
        !requiresEntitlementLookup(forCommittedAssetCount: committedAssetCount)
            || entitlementState == .entitled
    }
}
