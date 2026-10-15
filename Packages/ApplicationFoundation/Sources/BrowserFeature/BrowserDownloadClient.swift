//
//  BrowserDownloadClient.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Dependencies
import Foundation

/// Opaque identity of one transient download; it contains no request or filesystem information.
public struct BrowserDownloadID: Hashable, Sendable {
    let rawValue: UUID

    init() {
        rawValue = UUID()
    }
}

/// A safe projection of a transfer. Partial bytes are never a presentation destination.
public struct BrowserDownloadRecord: Equatable, Sendable, Identifiable {
    /// Operation identity stable through progress and completion.
    public let id: BrowserDownloadID
    /// Logical tab that owns this operation.
    public let tabID: BrowserTabID
    /// Bounded, sanitized filename, available only after completed-file verification.
    public let filename: String?
    /// Monotonic received-byte count, or actual regular-file size after completion.
    public let receivedBytes: Int64
    /// Known expected byte count; absent for indeterminate progress.
    public let expectedBytes: Int64?
    /// Whether the completed file passed its storage verification.
    public let isReady: Bool
}

/// Opaque native presentation request. A later presenter must resolve it through the live owner.
public struct BrowserDownloadPresentation: Equatable, Sendable {
    /// Native presentation purpose.
    public enum Kind: Equatable, Sendable {
        /// Display verified completed bytes with Quick Look.
        case preview
        /// Offer verified completed bytes to native sharing.
        case share
    }

    /// Prevents a dismissed request from being replayed against the same completed operation.
    public let requestID: UUID
    /// Completed operation to resolve.
    public let downloadID: BrowserDownloadID
    /// Authorization generation under which this request was admitted.
    public let generation: UInt64
    /// Requested native action.
    public let kind: Kind
}

/// Atomic revisioned reconciliation value. No framework objects or scratch paths enter reducers.
public struct BrowserDownloadSnapshot: Equatable, Sendable {
    /// One replaceable, redacted admission or storage explanation.
    public enum Notice: Equatable, Sendable {
        /// Privacy authorization is unavailable.
        case unauthorized
        /// The four-active-transfer limit was reached.
        case activeTransferLimitReached
        /// The eight-retained-record limit was reached.
        case retainedRecordLimitReached
        /// A transfer or its required storage verification failed.
        case transferFailed
        /// Native Quick Look cannot display this verified completed file.
        case previewUnavailable
        /// Scratch cleanup must succeed before downloads become available again.
        case cleanupRequired
        /// A handoff did not belong to the existing originating tab surface.
        case invalidOrigin
    }

    /// Strictly increasing owner revision; older deliveries cannot resurrect projections.
    public var revision: UInt64 = 0
    /// Synchronous privacy generation; revoked operations never join a newer generation.
    public var generation: UInt64 = 0
    /// True only while the owner is authorized and cleanup is verified.
    public var isAvailable = false
    /// Download-only recovery state; ordinary browsing remains independent.
    public var cleanupNeedsRetry = false
    /// Safe transfer projections, excluding every revoked operation.
    public var records: [BrowserDownloadRecord] = []
    /// Current native request, cleared synchronously by privacy invalidation.
    public var presentation: BrowserDownloadPresentation?
    /// Latest redacted notice, replaced rather than accumulated.
    public var notice: Notice?

    /// Creates an empty, unauthorized projection.
    public init() {}
}

/// Revision-aware commands; operation identities and privacy generations reject stale work.
public struct BrowserDownloadCommand: Equatable, Sendable {
    /// Action that never transports a scratch URL into reducer state.
    public enum Action: Equatable, Sendable {
        /// Revoke an operation and cancel its writer before cleanup.
        case cancel(BrowserDownloadID)
        /// Remove a completed operation, or cancel it if WebKit is still writing.
        case discard(BrowserDownloadID)
        /// Retry opaque cleanup ownership without restoring revoked operations.
        case retryCleanup
        /// Request presentation of verified completed bytes.
        case present(BrowserDownloadID, BrowserDownloadPresentation.Kind)
        /// End one exact native request while retaining completed bytes.
        case dismissPresentation(UUID)
    }

    /// Privacy generation captured by the sender.
    public let generation: UInt64
    /// Snapshot revision captured by the sender.
    public let revision: UInt64
    /// Requested action.
    public let action: Action

    /// Captures a command against one reconciled owner snapshot.
    public init(snapshot: BrowserDownloadSnapshot, action: Action) {
        generation = snapshot.generation
        revision = snapshot.revision
        self.action = action
    }
}

/// Reducer bridge to shared transient download ownership.
public struct BrowserDownloadClient: Sendable {
    /// Executes an opaque command on the main actor.
    public var execute: @Sendable (BrowserDownloadCommand) async -> Void
    /// Atomically subscribes and yields the current snapshot before subsequent revisions.
    public var events: @Sendable () async -> AsyncStream<BrowserDownloadSnapshot>
}

extension BrowserDownloadClient: DependencyKey {
    /// Live shared-browser owner; authorization starts disabled.
    public static let liveValue = Self(
        execute: { await BrowserDownloadOwner.shared.execute($0) },
        events: { await BrowserDownloadOwner.shared.subscribe() },
    )
    /// No-op dependency leaves unrelated reducer tests independent of native storage.
    public static let testValue = Self(execute: { _ in }, events: { AsyncStream { $0.finish() } })
}

extension DependencyValues {
    /// Shared-browser download dependency, separate from navigation events.
    public var browserDownloads: BrowserDownloadClient {
        get { self[BrowserDownloadClient.self] }
        set { self[BrowserDownloadClient.self] = newValue }
    }
}

/// Synchronous core privacy hook for a later scene/authentication registry.
@MainActor
public enum BrowserDownloadPrivacy {
    /// Live generation used to reject a previously evaluated root render, never to authorize it.
    public static var generation: UInt64 {
        BrowserDownloadOwner.shared.snapshot.generation
    }

    /// Installs a live authorization predicate. The caller must inspect authentication and all
    /// registered hosting scenes synchronously, and explicitly invalidate on authorization loss.
    public static func installAuthorization(_ predicate: @escaping @MainActor () -> Bool) {
        BrowserDownloadOwner.shared.installAuthorization(predicate)
    }

    /// Revokes every operation before deferred reducer effects or native dismissal can run.
    public static func invalidate() {
        BrowserDownloadOwner.shared.invalidateAuthorization()
    }

    /// Rechecks live authorization and retries cleanup without resurrecting old operations.
    public static func recheck() {
        BrowserDownloadOwner.shared.recheckAuthorization()
    }
}
