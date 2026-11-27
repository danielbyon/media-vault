//
//  MediaImportOutcome.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

/// The result of accepting an image for import.
public enum MediaImportOutcome: Equatable, Sendable {
    /// The image was committed to the Library.
    case imported(MediaAsset)

    /// The staged image matches committed content and needs a user decision.
    case duplicatePending(MediaDuplicateDecisionRequest)
}

/// A staged image that matches one or more committed assets.
public struct MediaDuplicateDecisionRequest: Equatable, Identifiable, Sendable {
    /// The journal identifier used to resolve this decision.
    public let id: UUID

    /// The source filename shown in the confirmation prompt.
    public let sourceFilename: String

    /// The acceptance time used to order multiple pending prompts.
    public let importedAt: Date

    /// Creates a duplicate prompt from durable journal metadata.
    public init(id: UUID, sourceFilename: String, importedAt: Date) {
        self.id = id
        self.sourceFilename = sourceFilename
        self.importedAt = importedAt
    }
}

/// A decision the user can make for a staged duplicate.
public enum MediaDuplicateDecisionChoice: Equatable, Sendable {
    /// Discard the staged copy and keep the existing Library items.
    case skip

    /// Continue through quota admission and commit the staged copy.
    case importAnyway
}

/// The durable result of resolving a duplicate prompt.
public enum MediaDuplicateResolutionResult: Equatable, Sendable {
    /// The staged copy was marked skipped and removed.
    case skipped

    /// The staged copy passed admission and was committed.
    case imported(MediaAsset)
}

/// A consistent view of committed Library assets and unresolved duplicate prompts.
public struct MediaLibrarySnapshot: Equatable, Sendable {
    /// Assets whose metadata is committed to the canonical store.
    public let assets: [MediaAsset]

    /// Valid duplicate decisions that remain unresolved.
    public let pendingDuplicateDecisions: [MediaDuplicateDecisionRequest]

    /// Creates a snapshot returned by the media-library client.
    public init(
        assets: [MediaAsset],
        pendingDuplicateDecisions: [MediaDuplicateDecisionRequest] = [],
    ) {
        self.assets = assets
        self.pendingDuplicateDecisions = pendingDuplicateDecisions
    }
}

/// The duplicate decision persisted with a journal row.
enum MediaDuplicateDecision: String, Equatable, Sendable {
    case pending
    case skipped
    case overridden
}

/// The quota result persisted with a journal row.
enum MediaQuotaAdmission: String, Equatable, Sendable {
    case pending
    case admitted
    case denied
}

/// A normalized, order-independent identity for an asset's complete resource set.
struct MediaAssetDuplicateIdentity: Equatable, Hashable, Sendable {
    /// The role and normalized digest that identify one resource in the collection.
    struct Component: Equatable, Hashable, Sendable {
        let role: String
        let sha256: String
    }

    let components: [Component]

    /// Returns nil when the resource set is empty or any digest is incomplete or malformed.
    init?(resources: [MediaResource]) {
        guard !resources.isEmpty else {
            return nil
        }

        let identities = resources.compactMap { resource -> Component? in
            guard let digest = Self.normalizedDigest(resource.sha256) else {
                return nil
            }

            return Component(role: resource.role.rawValue, sha256: digest)
        }
        guard identities.count == resources.count else {
            return nil
        }

        components = identities.sorted {
            if $0.role == $1.role {
                return $0.sha256 < $1.sha256
            }
            return $0.role < $1.role
        }
    }

    private static func normalizedDigest(_ digest: String) -> String? {
        let bytes = Array(digest.utf8)
        guard bytes.count == 64,
              bytes.allSatisfy({
                  (48 ... 57).contains($0)
                      || (65 ... 70).contains($0)
                      || (97 ... 102).contains($0)
              })
        else {
            return nil
        }

        return digest.lowercased()
    }
}
