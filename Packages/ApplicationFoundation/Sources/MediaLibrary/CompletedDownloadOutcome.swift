//
//  CompletedDownloadOutcome.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

/// The authenticated result of reconciling a durably accepted native download.
public enum CompletedDownloadOutcome: Equatable, Sendable {
    /// The operation still owns temporary bytes and has no terminal result.
    case pending
    /// The operation resolves to a canonical asset, including an exact duplicate skip.
    case imported(MediaAsset, duplicate: Bool)
    /// Unsupported bytes remain protected for the current process to present or discard.
    case unsupported(URL)
    /// Processing failed while durable ownership remains available for recovery.
    case failed(MediaImportError)
}

/// Temporary ownership still charged to accepted-download capacity.
public struct AcceptedDownloadStorage: Equatable, Sendable {
    /// The number of shared temporary operations, including legacy work and orphans.
    public let operationCount: Int
    /// The bytes charged to shared temporary ownership, excluding canonical final resources.
    public let byteCount: Int64

    /// Creates a snapshot of shared temporary capacity usage.
    public init(operationCount: Int, byteCount: Int64) {
        self.operationCount = operationCount
        self.byteCount = byteCount
    }
}

/// Permission for exactly one operation's final transaction, claimed under the Lock mutex.
struct DownloadCommitClaim: Sendable {
    let operationID: UUID
}

struct CompletedDownloadRecord: Sendable {
    let operationID: UUID
    let sourcePath: String
    let byteCount: Int64
    let device: Int64
    let inode: Int64
    let status: String
    let canonicalID: UUID?
}

struct AcceptedDownloadLimits: Equatable, Sendable {
    let itemBytes: Int64
    let aggregateBytes: Int64
    let freeBytes: Int64

    static let production = Self(
        itemBytes: 512 * 1_024 * 1_024,
        aggregateBytes: 2 * 1_024 * 1_024 * 1_024,
        freeBytes: 512 * 1_024 * 1_024,
    )
}
