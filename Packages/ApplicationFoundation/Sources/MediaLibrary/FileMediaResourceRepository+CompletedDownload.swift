//
//  FileMediaResourceRepository+CompletedDownload.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import CryptoKit
import Darwin
import Foundation

/// Reasons a native completion cannot transfer into protected shared staging.
public enum CompletedDownloadAcceptanceError: Error, Equatable, Sendable {
    /// No bytes were completed, and no journal ownership intent was written.
    case emptyFile
    /// Ownership may already be durable; callers must retain bytes for reconciliation.
    case ownershipUncertain

    /// Whether this rejection proves the operation never entered durable acceptance.
    public var isDefiniteRejection: Bool {
        self != .ownershipUncertain
    }

    /// The source failed path, file identity, ownership, or same-volume checks.
    case unsafeSource
    /// The completed item exceeds the accepted-pending per-item limit.
    case itemTooLarge
    /// Shared temporary byte or operation capacity cannot admit another item.
    case stagingCapacityExceeded
    /// Available storage is below the admission floor.
    case insufficientStorage
}

struct DownloadFileIdentity {
    let device: Int64
    let inode: Int64
    let byteCount: Int64
}

extension FileMediaResourceRepository {
    /// Opens only the caller's UUID directory below the native browser scratch root.
    /// Resolving the trusted system temporary root permits iOS's /var alias; child links are rejected.
    func completedDownloadIdentity(at url: URL, operationID: UUID) throws -> DownloadFileIdentity {
        let root = completedDownloadRootURL.deletingLastPathComponent()
            .resolvingSymlinksInPath()
            .appendingPathComponent(completedDownloadRootURL.lastPathComponent)
            .standardizedFileURL
        let source = url.standardizedFileURL
        guard url.isFileURL,
              UUID(uuidString: source.deletingLastPathComponent().lastPathComponent) == operationID,
              source.deletingLastPathComponent().deletingLastPathComponent().resolvingSymlinksInPath().path == root
              .path,
              !source.lastPathComponent.isEmpty
        else {
            throw CompletedDownloadAcceptanceError.unsafeSource
        }

        let rootFD = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard rootFD >= 0 else {
            throw CompletedDownloadAcceptanceError.unsafeSource
        }

        defer { close(rootFD) }
        var rootInfo = stat()
        guard fstat(rootFD, &rootInfo) == 0, rootInfo.st_uid == getuid() else {
            throw CompletedDownloadAcceptanceError.unsafeSource
        }

        let operationFD = openat(
            rootFD,
            source.deletingLastPathComponent().lastPathComponent,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW,
        )
        guard operationFD >= 0 else {
            throw CompletedDownloadAcceptanceError.unsafeSource
        }

        defer { close(operationFD) }
        var parent = stat()
        guard fstat(operationFD, &parent) == 0, parent.st_uid == getuid() else {
            throw CompletedDownloadAcceptanceError.unsafeSource
        }

        let fileFD = openat(operationFD, source.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fileFD >= 0 else {
            throw CompletedDownloadAcceptanceError.unsafeSource
        }

        defer { close(fileFD) }
        var info = stat()
        var destination = stat()
        guard fstat(fileFD, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_nlink == 1, info.st_size >= 0,
              lstat(stagingURL.path, &destination) == 0, destination.st_mode & S_IFMT == S_IFDIR,
              destination.st_uid == getuid(), info.st_dev == destination.st_dev,
              fsync(fileFD) == 0
        else {
            throw CompletedDownloadAcceptanceError.unsafeSource
        }

        return DownloadFileIdentity(device: Int64(info.st_dev), inode: Int64(info.st_ino), byteCount: info.st_size)
    }

    func verifyDownloadIdentity(at url: URL, record: CompletedDownloadRecord) throws {
        do {
            try checkStagedDownloadIdentity(at: url, record: record)
        } catch {
            throw CompletedDownloadAcceptanceError.unsafeSource
        }
    }

    func checkStagedDownloadIdentity(at url: URL, record: CompletedDownloadRecord) throws {
        var info = stat()
        var directory = stat()
        guard lstat(stagingURL.path, &directory) == 0 else {
            throw MediaLibraryStoreError.unavailable
        }
        guard directory.st_mode & S_IFMT == S_IFDIR, directory.st_uid == getuid() else {
            throw MediaLibraryStoreError.corrupt
        }
        guard lstat(url.path, &info) == 0 else {
            throw MediaLibraryStoreError.unavailable
        }
        guard info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_nlink == 1,
              Int64(info.st_dev) == record.device, Int64(info.st_ino) == record.inode,
              info.st_size == record.byteCount,
              url.deletingLastPathComponent().resolvingSymlinksInPath().path == stagingURL.resolvingSymlinksInPath()
              .path
        else {
            throw MediaLibraryStoreError.corrupt
        }
    }

    /// Uses an exclusive rename on the verified volume; this path never falls back to copying.
    func finishDownloadHandoff(_ record: CompletedDownloadRecord) throws {
        let target = stagingURL(for: record.operationID)
        if FileManager.default.fileExists(atPath: target.path) {
            try verifyDownloadIdentity(at: target, record: record)
            try protectStaging(for: record.operationID)
            return
        }
        let source = URL(fileURLWithPath: record.sourcePath)
        let identity = try completedDownloadIdentity(at: source, operationID: record.operationID)
        guard identity.device == record.device, identity.inode == record.inode,
              identity.byteCount == record.byteCount else {
            throw CompletedDownloadAcceptanceError.unsafeSource
        }

        try protectionOperation(source)
        let sourceParent = open(source.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        let targetParent = open(stagingURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard sourceParent >= 0, targetParent >= 0 else {
            if sourceParent >= 0 {
                close(sourceParent)
            }
            if targetParent >= 0 {
                close(targetParent)
            }
            throw CompletedDownloadAcceptanceError.unsafeSource
        }

        defer { close(sourceParent)
            close(targetParent)
        }
        var before = stat()
        guard fstatat(sourceParent, source.lastPathComponent, &before, AT_SYMLINK_NOFOLLOW) == 0,
              Int64(before.st_ino) == record.inode, Int64(before.st_dev) == record.device,
              before.st_mode & S_IFMT == S_IFREG, before.st_nlink == 1,
              renameatx_np(
                  sourceParent,
                  source.lastPathComponent,
                  targetParent,
                  target.lastPathComponent,
                  UInt32(RENAME_EXCL),
              ) == 0
        else {
            throw CompletedDownloadAcceptanceError.unsafeSource
        }
        guard fsync(sourceParent) == 0, fsync(targetParent) == 0 else {
            throw MediaImportError.persistenceFailed
        }

        try verifyDownloadIdentity(at: target, record: record)
        try protectStaging(for: record.operationID)
    }

    func availableDownloadBytes() throws -> Int64 {
        let attributes = try FileManager.default.attributesOfFileSystem(forPath: stagingURL.path)
        guard let bytes = attributes[.systemFreeSize] as? Int64 else {
            throw MediaImportError.persistenceFailed
        }

        return bytes
    }

    func removeUncommittedDownloadFinal(_ operationID: UUID) throws {
        let url = rootURL.appendingPathComponent(operationID.uuidString.lowercased())
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    func removeAcceptedDownloadStaging(_ operationID: UUID) throws {
        let url = stagingURL(for: operationID)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }
}

extension FileMediaResourceRepository {
    /// Hashes the canonical file in bounded chunks while retaining its verified file descriptor.
    func verifiedPresentationURL(for resource: MediaResource, isCurrent: () -> Bool) throws -> URL {
        try withCanonicalResource(resource, isCurrent: isCurrent, inspectChunk: { _ in }) { digest in
            guard digest == resource.sha256 else {
                throw MediaLibraryStoreError.corrupt
            }
            guard isCurrent() else {
                throw CancellationError()
            }

            return url(for: resource)
        }
    }

    #if DEBUG
    func readCanonicalResource(
        _ resource: MediaResource,
        isCurrent: () -> Bool,
        inspectChunk: (Data) -> Void,
    ) throws -> String {
        guard isCurrent() else {
            throw CancellationError()
        }

        return try withCanonicalResource(resource, isCurrent: isCurrent, inspectChunk: inspectChunk) { digest in
            guard isCurrent() else {
                throw CancellationError()
            }

            return digest
        }
    }
    #endif

    /// Keeps the descriptor open through the directory-entry check and the caller's final authorization check.
    private func withCanonicalResource<Result>(
        _ resource: MediaResource,
        isCurrent: () -> Bool,
        inspectChunk: (Data) -> Void,
        finish: (String) throws -> Result,
    ) throws -> Result {
        guard resource.relativePath == resource.id.uuidString.lowercased(), resource.byteCount >= 0,
              resource.sha256.count == 64 else {
            throw MediaLibraryStoreError.corrupt
        }

        let directory = open(rootURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard directory >= 0 else {
            throw MediaLibraryStoreError.unavailable
        }

        defer { close(directory) }
        var parent = stat()
        guard fstat(directory, &parent) == 0, parent.st_uid == getuid() else {
            throw MediaLibraryStoreError.corrupt
        }

        let descriptor = openat(directory, resource.relativePath, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else {
            throw MediaLibraryStoreError.unavailable
        }

        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_nlink == 1, info.st_size == resource.byteCount else {
            throw MediaLibraryStoreError.corrupt
        }

        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        var digest = SHA256()
        while true {
            guard isCurrent() else {
                throw CancellationError()
            }

            let bytes = try handle.read(upToCount: 64 * 1_024) ?? Data()
            if bytes.isEmpty {
                break
            }
            digest.update(data: bytes)
            inspectChunk(bytes)
        }
        let hash = digest.finalize().map { String(format: "%02x", $0) }.joined()
        var current = stat()
        guard fstatat(directory, resource.relativePath, &current, AT_SYMLINK_NOFOLLOW) == 0,
              current.st_ino == info.st_ino, current.st_dev == info.st_dev,
              current.st_size == info.st_size, current.st_mode & S_IFMT == S_IFREG,
              current.st_nlink == 1, current.st_uid == getuid() else {
            throw MediaLibraryStoreError.corrupt
        }

        return try finish(hash)
    }
}

struct TemporaryResourceInventoryItem {
    let operationKey: String
    let byteCount: Int64
}

extension FileMediaResourceRepository {
    /// Inventories actual temporary files, including legacy and unjournaled staging leftovers.
    /// Canonical final paths are excluded; a second physical file still consumes bytes even when
    /// it belongs to the same operation. Inode identity prevents double-counting hard links.
    func temporaryResourceInventory(excluding canonicalPaths: Set<String>) throws -> [TemporaryResourceInventoryItem] {
        var result: [TemporaryResourceInventoryItem] = []
        var identities = Set<String>()
        for directory in [stagingURL, rootURL] {
            var parent = stat()
            guard lstat(directory.path, &parent) == 0, parent.st_mode & S_IFMT == S_IFDIR,
                  parent.st_uid == getuid() else {
                throw MediaLibraryStoreError.corrupt
            }

            let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            for url in files {
                let identifier = UUID(uuidString: url.lastPathComponent)
                if directory == rootURL {
                    guard identifier != nil, !canonicalPaths.contains(url.lastPathComponent) else {
                        continue
                    }
                }
                var info = stat()
                guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
                      info.st_uid == getuid(), info.st_size >= 0 else {
                    throw MediaLibraryStoreError.corrupt
                }

                let identity = "\(info.st_dev):\(info.st_ino)"
                let key = identifier?.uuidString.lowercased() ?? "orphan:\(url.lastPathComponent)"
                result.append(TemporaryResourceInventoryItem(
                    operationKey: key,
                    byteCount: identities.insert(identity).inserted ? info.st_size : 0,
                ))
            }
        }
        return result
    }
}
