//
//  MediaAsset.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

/// The canonical logical media item types supported by the media library.
public enum MediaAssetKind: String, Equatable, Sendable {
    /// A single renderable still-image resource.
    case stillImage
}

/// The role a resource plays within its logical media asset.
public enum MediaResourceRole: String, Equatable, Sendable {
    /// The immutable resource supplied by the user.
    case original
}

/// A logical media item stored in the authenticated library.
public struct MediaAsset: Equatable, Identifiable, Sendable {
    /// The opaque logical identifier for this asset.
    public let id: UUID

    /// The canonical media representation.
    public let kind: MediaAssetKind

    /// The time at which the import was committed.
    public let importedAt: Date

    /// The source capture time when the image supplied one.
    public let capturedAt: Date?

    /// The canonical resources belonging to this asset.
    public let resources: [MediaResource]

    /// Creates a canonical media asset.
    public init(
        id: UUID,
        kind: MediaAssetKind,
        importedAt: Date,
        resources: [MediaResource],
        capturedAt: Date? = nil,
    ) {
        self.id = id
        self.kind = kind
        self.importedAt = importedAt
        self.capturedAt = capturedAt
        self.resources = resources
    }
}

/// The durable metadata for one canonical media resource.
public struct MediaResource: Equatable, Identifiable, Sendable {
    /// The opaque resource identifier and final filename.
    public let id: UUID

    /// The resource's role within its asset.
    public let role: MediaResourceRole

    /// The path relative to the app-controlled resource root.
    public let relativePath: String

    /// The filename supplied by the source provider.
    public let sourceFilename: String

    /// The Uniform Type Identifier detected by Apple image decoding.
    public let sourceUTI: String

    /// The exact number of bytes in the canonical original.
    public let byteCount: Int64

    /// The lowercase hexadecimal SHA-256 digest of the canonical original.
    public let sha256: String

    /// Creates canonical resource metadata.
    public init(
        id: UUID,
        role: MediaResourceRole,
        relativePath: String,
        sourceFilename: String,
        sourceUTI: String,
        byteCount: Int64,
        sha256: String,
    ) {
        self.id = id
        self.role = role
        self.relativePath = relativePath
        self.sourceFilename = sourceFilename
        self.sourceUTI = sourceUTI
        self.byteCount = byteCount
        self.sha256 = sha256
    }
}

/// Errors raised while reading or writing the canonical media store.
public enum MediaLibraryStoreError: Error, Equatable, Sendable {
    /// The database could not be opened or used.
    case unavailable

    /// The database contained a record that cannot be represented by the domain model.
    case corrupt
}

/// Errors raised while importing a source file into canonical storage.
public enum MediaImportError: Error, Equatable, Sendable {
    /// The source URL could not be accessed or copied while access was valid.
    case sourceAccessFailed

    /// The source is not one supported ordinary still image.
    case unsupportedMedia

    /// ImageIO could identify the resource as an image but could not render it.
    case unrenderableMedia

    /// The protected resource could not be finalized.
    case finalizationFailed

    /// The canonical metadata transaction could not be committed.
    case persistenceFailed
}
