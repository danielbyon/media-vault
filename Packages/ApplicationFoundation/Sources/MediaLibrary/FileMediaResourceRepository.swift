//
//  FileMediaResourceRepository.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Provides the protected app-controlled filesystem boundary for canonical resources.
public struct FileMediaResourceRepository: Sendable {
    private let rootURL: URL
    private let stagingURL: URL
    private let protectionOperation: @Sendable (URL) throws -> Void

    /// Creates protected resource and staging directories below the supplied root.
    public init(rootURL: URL) throws {
        try self.init(
            rootURL: rootURL,
            protectionOperation: { url in
                try Self.applyCompleteProtection(to: url, using: FileManager.default)
            },
        )
    }

    /// Creates a repository with an injected protection operation for deterministic failure tests.
    @preconcurrency
    @_spi(Testing)
    public init(
        rootURL: URL,
        protectionOperation: @escaping @Sendable (URL) throws -> Void,
    ) throws {
        let normalizedRootURL = rootURL.standardizedFileURL
        self.rootURL = normalizedRootURL
        stagingURL = normalizedRootURL.appendingPathComponent(".staging", isDirectory: true)
        self.protectionOperation = protectionOperation
        let fileManager = FileManager.default

        try fileManager.createDirectory(at: self.rootURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: stagingURL, withIntermediateDirectories: true)
        try protectionOperation(self.rootURL)
        try protectionOperation(stagingURL)
    }

    /// Returns a unique staging path for one import operation.
    public func stagingURL(for identifier: UUID) -> URL {
        stagingURL.appendingPathComponent(identifier.uuidString.lowercased(), isDirectory: false)
    }

    /// Applies complete Data Protection to one copied staging resource before validation.
    public func protectStaging(for identifier: UUID) throws {
        let fileManager = FileManager.default
        let url = stagingURL(for: identifier)
        do {
            guard fileManager.fileExists(atPath: url.path) else {
                throw MediaImportError.finalizationFailed
            }

            try protectionOperation(url)
        } catch let error as MediaImportError {
            throw error
        } catch {
            throw MediaImportError.finalizationFailed
        }
    }

    /// Moves a staged resource to its opaque final path and returns the database-relative path.
    public func finalize(stagingURL: URL, resourceID: UUID) throws -> String {
        let relativePath = resourceID.uuidString.lowercased()
        let finalURL = rootURL.appendingPathComponent(relativePath, isDirectory: false)
        let fileManager = FileManager.default
        var didMove = false
        defer {
            if didMove {
                removeFinalizedResourceIfPresent(for: resourceID)
            }
        }

        do {
            guard stagingURL.standardizedFileURL == self.stagingURL(for: resourceID),
                  fileManager.fileExists(atPath: stagingURL.path),
                  !fileManager.fileExists(atPath: finalURL.path)
            else {
                throw MediaImportError.finalizationFailed
            }

            try protectionOperation(stagingURL)
            try fileManager.moveItem(at: stagingURL, to: finalURL)
            didMove = true
            try protectionOperation(finalURL)
            didMove = false
            return relativePath
        } catch let error as MediaImportError {
            throw error
        } catch {
            throw MediaImportError.finalizationFailed
        }
    }

    /// Returns the final URL for a resource's opaque relative path.
    public func url(for resource: MediaResource) -> URL {
        rootURL.appendingPathComponent(resource.relativePath, isDirectory: false)
    }

    /// Loads canonical bytes after validating that the database path remains relative and opaque.
    public func data(for resource: MediaResource) throws -> Data {
        guard resource.relativePath == resource.id.uuidString.lowercased(),
              !resource.relativePath.contains("/"),
              !resource.relativePath.contains("\\"),
              resource.byteCount >= 0,
              resource.sha256.count == 64
        else {
            throw MediaLibraryStoreError.corrupt
        }

        do {
            let data = try Data(contentsOf: url(for: resource), options: [.mappedIfSafe])
            guard Int64(data.count) == resource.byteCount,
                  SHA256.hash(data: data).hexString == resource.sha256
            else {
                throw MediaLibraryStoreError.corrupt
            }

            return data
        } catch let error as MediaLibraryStoreError {
            throw error
        } catch {
            throw MediaLibraryStoreError.unavailable
        }
    }

    /// Removes an unfinalized staging file when cleanup is certain.
    public func removeStagingIfPresent(at url: URL) {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path) else {
            return
        }

        try? fileManager.removeItem(at: url)
    }

    /// Removes a finalized resource when its metadata commit did not complete.
    public func removeFinalizedResourceIfPresent(for resourceID: UUID) {
        let fileManager = FileManager.default
        let url = rootURL.appendingPathComponent(resourceID.uuidString.lowercased(), isDirectory: false)
        guard fileManager.fileExists(atPath: url.path) else {
            return
        }

        try? fileManager.removeItem(at: url)
    }

    private static func applyCompleteProtection(to url: URL, using fileManager: FileManager) throws {
        try fileManager.setAttributes(
            [.protectionKey: FileProtectionType.complete],
            ofItemAtPath: url.path,
        )
    }
}

/// Copies a document-provider URL while any security-scoped access is valid.
public struct MediaSourceClient: Sendable {
    private let copyOperation: @Sendable (URL, URL) throws -> Void

    /// Creates a source client from a caller-owned copy operation.
    @preconcurrency
    public init(copyOperation: @escaping @Sendable (URL, URL) throws -> Void) {
        self.copyOperation = copyOperation
    }

    /// Copies a source URL into the supplied staging URL.
    public func copyToStaging(from sourceURL: URL, to stagingURL: URL) throws {
        try copyOperation(sourceURL, stagingURL)
    }

    /// The production adapter for Files/document-provider URLs.
    public static let live = Self { sourceURL, stagingURL in
        let hasSecurityScopedAccess = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if hasSecurityScopedAccess {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        let fileManager = FileManager.default
        guard fileManager.isReadableFile(atPath: sourceURL.path),
              let values = try? sourceURL.resourceValues(forKeys: [.isDirectoryKey]),
              values.isDirectory != true
        else {
            throw MediaImportError.sourceAccessFailed
        }

        do {
            try fileManager.copyItem(at: sourceURL, to: stagingURL)
        } catch {
            throw MediaImportError.sourceAccessFailed
        }
    }

    /// A test adapter for local temporary files that uses the same byte-copy operation.
    public static let localFile = Self { sourceURL, stagingURL in
        do {
            try FileManager.default.copyItem(at: sourceURL, to: stagingURL)
        } catch {
            throw MediaImportError.sourceAccessFailed
        }
    }
}

/// Imports one source file into the canonical media model and protected resource store.
public actor MediaLibraryImporter {
    private let store: any MediaLibraryStore
    private let resources: FileMediaResourceRepository
    private let source: MediaSourceClient
    private let id: @Sendable () -> UUID
    private let now: @Sendable () -> Date

    /// Creates an importer with explicit storage and source-access seams.
    @preconcurrency
    public init(
        store: any MediaLibraryStore,
        resources: FileMediaResourceRepository,
        source: MediaSourceClient = .live,
        id: @escaping @Sendable () -> UUID = UUID.init,
        now: @escaping @Sendable () -> Date = Date.init,
    ) {
        self.store = store
        self.resources = resources
        self.source = source
        self.id = id
        self.now = now
    }

    /// Copies, validates, finalizes, and commits one ordinary still image.
    public func importFile(at sourceURL: URL) async throws -> MediaAsset {
        let assetID = id()
        let resourceID = id()
        let stagingFileURL = resources.stagingURL(for: resourceID)
        var didFinalize = false
        var didCommit = false
        defer {
            if !didCommit {
                if didFinalize {
                    resources.removeFinalizedResourceIfPresent(for: resourceID)
                } else {
                    resources.removeStagingIfPresent(at: stagingFileURL)
                }
            }
        }

        do {
            try source.copyToStaging(from: sourceURL, to: stagingFileURL)
        } catch let error as MediaImportError {
            throw error
        } catch {
            throw MediaImportError.sourceAccessFailed
        }
        try resources.protectStaging(for: resourceID)

        let inspection = try inspectStillImage(at: stagingFileURL)
        let relativePath = try resources.finalize(stagingURL: stagingFileURL, resourceID: resourceID)
        didFinalize = true

        let resource = MediaResource(
            id: resourceID,
            role: .original,
            relativePath: relativePath,
            sourceFilename: sourceURL.lastPathComponent,
            sourceUTI: inspection.uti,
            byteCount: inspection.byteCount,
            sha256: inspection.sha256,
        )
        let asset = MediaAsset(
            id: assetID,
            kind: .stillImage,
            importedAt: now(),
            resources: [resource],
            capturedAt: inspection.capturedAt,
        )

        do {
            try await store.commit(asset)
        } catch {
            throw MediaImportError.persistenceFailed
        }
        didCommit = true

        return asset
    }

    private func inspectStillImage(at url: URL) throws -> ImageInspection {
        guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw MediaImportError.unrenderableMedia
        }

        let count = CGImageSourceGetCount(imageSource)
        guard count > 0 else {
            throw MediaImportError.unrenderableMedia
        }
        guard count == 1 else {
            throw MediaImportError.unsupportedMedia
        }
        guard let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil), image.width > 0, image.height > 0 else {
            throw MediaImportError.unrenderableMedia
        }
        guard let sourceType = CGImageSourceGetType(imageSource) else {
            throw MediaImportError.unrenderableMedia
        }

        let sourceTypeString = sourceType as String
        guard let type = UTType(sourceTypeString),
              type.conforms(to: .image),
              !type.conforms(to: .rawImage),
              type != .livePhoto
        else {
            throw MediaImportError.unsupportedMedia
        }

        do {
            let bytes = try Data(contentsOf: url, options: [.mappedIfSafe])
            let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [String: Any]
            return ImageInspection(
                uti: sourceTypeString,
                byteCount: Int64(bytes.count),
                sha256: SHA256.hash(data: bytes).hexString,
                capturedAt: captureDate(from: properties),
            )
        } catch {
            throw MediaImportError.unrenderableMedia
        }
    }

    private func captureDate(from properties: [String: Any]?) -> Date? {
        let exifKey = kCGImagePropertyExifDictionary as String
        let dateKey = kCGImagePropertyExifDateTimeOriginal as String
        let value = properties?[exifKey] as? [String: Any]
        guard let dateString = value?[dateKey] as? String else {
            return nil
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter.date(from: dateString)
    }
}

private struct ImageInspection: Sendable {
    let uti: String
    let byteCount: Int64
    let sha256: String
    let capturedAt: Date?
}

extension SHA256.Digest {
    fileprivate var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
