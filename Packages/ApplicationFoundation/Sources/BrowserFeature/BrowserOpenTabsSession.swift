//
//  BrowserOpenTabsSession.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import ComposableArchitecture
import CoreFoundation
import Darwin
import Foundation

/// Describes whether storage inspection found a usable session, no session, or an unsafe read.
enum BrowserOpenTabsSessionLoadOutcome: Equatable, Sendable {
    /// The persistence domain and legacy location were inspected successfully and contain no session.
    case missing

    /// A committed or recoverable session was read after its storage protections were verified.
    case loaded(Data)

    /// Filesystem, protection, or recovery errors prevented a safe read decision.
    case failed
}

/// Synchronously orders one persistence domain before its effects can run out of order.
final class BrowserPersistenceRevisionGate: @unchecked Sendable {
    static let shared = BrowserPersistenceRevisionGate()
    static let settingsShared = BrowserPersistenceRevisionGate()

    private let lock = NSLock()
    private var newestRevision: UInt64 = 0

    /// Reserves a revision before its asynchronous persistence work is scheduled.
    func reserve(after revision: UInt64) -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        let base = max(newestRevision, revision)
        let next = base == .max ? .max : base + 1
        newestRevision = next
        return next
    }

    /// Starts a current mutation, then releases the revision lock before storage work begins.
    @discardableResult
    func perform(revision: UInt64, _ operation: () -> Void) -> Bool {
        lock.lock()
        guard revision >= newestRevision else {
            lock.unlock()
            return false
        }

        newestRevision = revision
        lock.unlock()

        operation()
        return true
    }
}

/// Versioned, privacy-minimal description of the logical Browser tabs that can be reopened.
struct BrowserOpenTabsSession: Equatable, Sendable {
    static let currentVersion = 1

    /// One restorable tab at its original position in the logical tab order.
    struct Entry: Equatable, Sendable {
        enum Kind: Equatable, Sendable {
            case startPage
            case web(URL)
        }

        var position: Int
        var kind: Kind
    }

    /// Logical tabs produced from a saved session with new process-local identities.
    struct Restoration: Equatable, Sendable {
        var tabs: [BrowserTab]
        var selectedTabID: BrowserTabID
        var selectedURL: URL?
        var lazyWebTabURLs: [BrowserTabID: URL]

        static func freshStartPage(uuid: @Sendable () -> UUID) -> Self {
            let id = BrowserTabID(uuid())
            return Self(
                tabs: [.startPage(id: id)],
                selectedTabID: id,
                selectedURL: nil,
                lazyWebTabURLs: [:],
            )
        }
    }

    private struct EncodedEntry: Encodable {
        var position: Int
        var kind: String
        var url: String?
    }

    private struct EncodedEnvelope: Encodable {
        var version: Int
        var selectedPosition: Int
        var entries: [EncodedEntry]
    }

    var selectedPosition: Int
    var entries: [Entry]

    /// The surviving entry nearest the saved selected position, preferring the earlier entry on ties.
    var selectedEntryPosition: Int? {
        entries.min { lhs, rhs in
            let leftDistance = abs(Int64(lhs.position) - Int64(selectedPosition))
            let rightDistance = abs(Int64(rhs.position) - Int64(selectedPosition))
            return leftDistance == rightDistance ? lhs.position < rhs.position : leftDistance < rightDistance
        }?.position
    }

    /// Projects tab state while discarding WebKit and presentation-only data.
    static func project(from tabs: [BrowserTab], selectedTabID: BrowserTabID) -> Self {
        let selectedPosition = tabs.firstIndex(where: { $0.id == selectedTabID }) ?? 0
        let entries = tabs.enumerated().compactMap { position, tab -> Entry? in
            if tab.isStartPage {
                return Entry(position: position, kind: .startPage)
            }
            guard let url = restorableURL(for: tab) else {
                return nil
            }

            return Entry(position: position, kind: .web(url))
        }
        return Self(selectedPosition: selectedPosition, entries: entries)
    }

    /// Encodes the versioned session envelope without runtime tab identities or transient state.
    func encoded() throws -> Data {
        let encodedEntries = entries.map { entry -> EncodedEntry in
            switch entry.kind {
            case .startPage:
                EncodedEntry(position: entry.position, kind: "startPage")
            case let .web(url):
                EncodedEntry(position: entry.position, kind: "web", url: url.absoluteString)
            }
        }
        return try JSONEncoder().encode(EncodedEnvelope(
            version: Self.currentVersion,
            selectedPosition: selectedPosition,
            entries: encodedEntries,
        ))
    }

    /// Decodes a valid v1 envelope and drops malformed entries independently.
    static func decode(_ data: Data) -> Self? {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let envelope = object as? [String: Any],
              integer(envelope["version"]) == currentVersion,
              let selectedPosition = integer(envelope["selectedPosition"]),
              selectedPosition >= 0,
              let rawEntries = envelope["entries"] as? [Any]
        else {
            return nil
        }

        var seenPositions: Set<Int> = []
        let entries = rawEntries.compactMap { rawEntry -> Entry? in
            guard let rawEntry = rawEntry as? [String: Any],
                  let position = integer(rawEntry["position"]),
                  position >= 0,
                  let kind = rawEntry["kind"] as? String
            else {
                return nil
            }

            let entry: Entry?
            switch kind {
            case "startPage":
                entry = Entry(position: position, kind: .startPage)
            case "web":
                guard let rawURL = rawEntry["url"] as? String,
                      let url = BrowserNavigation.bookmarkURL(rawURL)
                else {
                    return nil
                }

                entry = Entry(position: position, kind: .web(url))
            default:
                return nil
            }
            guard seenPositions.insert(position).inserted else {
                return nil
            }

            return entry
        }
        .sorted { $0.position < $1.position }

        guard !entries.isEmpty else {
            return nil
        }

        return Self(selectedPosition: selectedPosition, entries: entries)
    }

    /// Reconstructs ordinary tabs with fresh identities and marks unselected web tabs for lazy loading.
    func restore(uuid: @Sendable () -> UUID) -> Restoration {
        guard !entries.isEmpty else {
            return .freshStartPage(uuid: uuid)
        }

        let selectedPosition = selectedEntryPosition ?? entries[0].position
        var selectedTabID: BrowserTabID?
        var selectedURL: URL?
        var tabs: [BrowserTab] = []
        var lazyWebTabURLs: [BrowserTabID: URL] = [:]

        for entry in entries.sorted(by: { $0.position < $1.position }) {
            let id = BrowserTabID(uuid())
            let tab: BrowserTab
            switch entry.kind {
            case .startPage:
                tab = .startPage(id: id)
            case let .web(url):
                tab = .web(id: id, url: url)
                if entry.position == selectedPosition {
                    selectedURL = url
                } else {
                    lazyWebTabURLs[id] = url
                }
            }
            if entry.position == selectedPosition {
                selectedTabID = id
            }
            tabs.append(tab)
        }

        guard let selectedTabID else {
            return .freshStartPage(uuid: uuid)
        }

        return Restoration(
            tabs: tabs,
            selectedTabID: selectedTabID,
            selectedURL: selectedURL,
            lazyWebTabURLs: lazyWebTabURLs,
        )
    }

    private static func restorableURL(for tab: BrowserTab) -> URL? {
        let otherCommittedURL: URL? =
            if case let .terminated(lastCommittedURL) = tab.content {
                lastCommittedURL
            } else {
                nil
            }
        if let committedURL = [tab.metadata.committedURL, otherCommittedURL]
            .compactMap(\.self)
            .compactMap(validatedWebURL)
            .first {
            return committedURL
        }

        switch tab.content {
        case let .web(requestedURL):
            return validatedWebURL(requestedURL)
        case let .error(error):
            return validatedWebURL(error.url)
        case .startPage,
             .terminated:
            return nil
        }
    }

    private static func validatedWebURL(_ url: URL) -> URL? {
        guard BrowserNavigation.isHTTPURL(url) else {
            return nil
        }

        return BrowserNavigation.bookmarkURL(url.absoluteString)
    }

    private static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite,
              number.doubleValue.rounded(.towardZero) == number.doubleValue
        else {
            return nil
        }

        return number.intValue
    }
}

/// Dedicated Browser-owned session persistence with revision ordering and private file protection.
actor BrowserOpenTabsSessionStorage {
    private enum TransactionArtifactKind: String {
        case pending
        case previous
        case transaction
        case recovery
    }

    private struct TransactionArtifact {
        let id: String
        let kind: TransactionArtifactKind
        let url: URL
    }

    private enum StorageError: Error {
        case storageProtectionNotVerified
        case recoveryUnavailable
    }

    nonisolated let directoryURL: URL
    nonisolated let fileURL: URL
    private let revisionGate: BrowserPersistenceRevisionGate
    private let applyAndVerifyStorageProtection: @Sendable (URL) throws -> Bool
    private let legacyDirectoryURL: URL?
    private var newestRevision: UInt64 = 0

    init(
        directoryURL: URL,
        legacyDirectoryURL: URL? = nil,
        revisionGate: BrowserPersistenceRevisionGate = BrowserPersistenceRevisionGate(),
        applyAndVerifyStorageProtection: @escaping @Sendable (URL) throws -> Bool =
            BrowserOpenTabsSessionStorage.applyAndVerifyStorageProtection,
    ) {
        self.directoryURL = directoryURL
        fileURL = directoryURL.appendingPathComponent("open-tabs.json", isDirectory: false)
        self.legacyDirectoryURL = legacyDirectoryURL
        self.revisionGate = revisionGate
        self.applyAndVerifyStorageProtection = applyAndVerifyStorageProtection
    }

    /// Applies and verifies complete Data Protection and backup exclusion for one storage URL.
    nonisolated static func applyAndVerifyStorageProtection(_ url: URL) throws -> Bool {
        let fileManager = FileManager.default
        try fileManager.setAttributes(
            [.protectionKey: FileProtectionType.complete],
            ofItemAtPath: url.path,
        )
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableURL = url
        try mutableURL.setResourceValues(values)

        let storedValues = try url.resourceValues(forKeys: [.isExcludedFromBackupKey])
        let storedAttributes = try fileManager.attributesOfItem(atPath: url.path)
        return storedValues.isExcludedFromBackup == true
            && storedAttributes[.protectionKey] as? FileProtectionType == .complete
    }

    /// Reads the current committed snapshot after checking storage access and recovering transactions.
    func load() -> BrowserOpenTabsSessionLoadOutcome {
        do {
            if try itemExists(at: directoryURL) {
                try ensureStorageProtection(for: directoryURL)
                if let recoverableData = try reconcileInterruptedTransactions() {
                    return .loaded(recoverableData)
                }

                if try itemExists(at: fileURL) {
                    let data = try readProtectedData(at: fileURL)
                    removeLegacySessionFiles()
                    return .loaded(data)
                }
            }
            return try loadLegacySession()
        } catch {
            return .failed
        }
    }

    /// Commits a prepared session atomically and records enough state to recover after interruption.
    func save(_ session: BrowserOpenTabsSession, revision: UInt64) {
        guard let data = try? session.encoded()
        else {
            return
        }

        revisionGate.perform(revision: revision) {
            guard revision >= newestRevision else {
                return
            }

            newestRevision = revision
            let fileManager = FileManager.default
            do {
                try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
                try ensureStorageProtection(for: directoryURL)
                guard try reconcileInterruptedTransactions() == nil else {
                    throw StorageError.recoveryUnavailable
                }

                try commit(data)
            } catch {
                // Persistence failures must not interrupt Browser operation.
            }
        }
    }

    /// Deletes this complete persistence domain and its recognized pre-directory session files.
    func purge(revision: UInt64) {
        revisionGate.perform(revision: revision) {
            guard revision >= newestRevision else {
                return
            }

            newestRevision = revision
            removeSessionDirectory()
            removeLegacySessionFiles(removeCommittedSession: true)
        }
    }

    /// Advances the ordering barrier while preserving the current durable session file.
    func advance(revision: UInt64) {
        revisionGate.perform(revision: revision) {
            newestRevision = max(newestRevision, revision)
        }
    }

    private func commit(_ data: Data) throws {
        let fileManager = FileManager.default
        let transactionID = UUID().uuidString
        let pendingURL = artifactURL(.pending, id: transactionID)
        let previousURL = artifactURL(.previous, id: transactionID)
        let transactionURL = artifactURL(.transaction, id: transactionID)
        var hasPreviousSession = false
        var didPromoteCandidate = false

        do {
            try data.write(to: pendingURL, options: .atomic)
            try ensureStorageProtection(for: pendingURL)

            if try itemExists(at: fileURL) {
                try fileManager.copyItem(at: fileURL, to: previousURL)
                hasPreviousSession = true
                try ensureStorageProtection(for: previousURL)
            }

            try Data().write(to: transactionURL, options: .atomic)
            try ensureStorageProtection(for: transactionURL)

            try Self.atomicallyReplace(stagingFileAt: pendingURL, destinationFileAt: fileURL)
            didPromoteCandidate = true
            try ensureStorageProtection(for: directoryURL)
            try ensureStorageProtection(for: fileURL)

            // Removing the marker commits the candidate. Until then, recovery prefers previous.
            try fileManager.removeItem(at: transactionURL)
            removeObsoleteSessionFiles()
            removeLegacySessionFiles()
        } catch {
            rollBack(
                transactionID: transactionID,
                hasPreviousSession: hasPreviousSession,
                didPromoteCandidate: didPromoteCandidate,
            )
        }
    }

    private func rollBack(
        transactionID: String,
        hasPreviousSession: Bool,
        didPromoteCandidate: Bool,
    ) {
        let fileManager = FileManager.default
        let transactionURL = artifactURL(.transaction, id: transactionID)
        let previousURL = artifactURL(.previous, id: transactionID)

        if didPromoteCandidate {
            if hasPreviousSession {
                do {
                    try restoreCommittedSnapshot(from: previousURL, transactionID: transactionID)
                } catch {
                    // Keep the marker and previous snapshot so the next access can retry recovery.
                    return
                }
            } else if fileManager.fileExists(atPath: fileURL.path) {
                do {
                    try fileManager.removeItem(at: fileURL)
                } catch {
                    // Keep the marker so an uncommitted first snapshot is never loaded.
                    return
                }
            }
        }

        if fileManager.fileExists(atPath: transactionURL.path) {
            do {
                try fileManager.removeItem(at: transactionURL)
            } catch {
                // Keep recovery data whenever the transaction marker remains.
                return
            }
        }
        removeObsoleteSessionFiles()
    }

    /// Restores a copied previous snapshot without consuming the only recovery file.
    private func restoreCommittedSnapshot(from previousURL: URL, transactionID: String) throws {
        let fileManager = FileManager.default
        try ensureStorageProtection(for: directoryURL)
        try ensureStorageProtection(for: previousURL)
        let recoveryURL = artifactURL(.recovery, id: transactionID)
        if try itemExists(at: recoveryURL) {
            try fileManager.removeItem(at: recoveryURL)
        }
        try fileManager.copyItem(at: previousURL, to: recoveryURL)

        do {
            try ensureStorageProtection(for: recoveryURL)
            try Self.atomicallyReplace(stagingFileAt: recoveryURL, destinationFileAt: fileURL)
            try ensureStorageProtection(for: directoryURL)
            try ensureStorageProtection(for: fileURL)
        } catch {
            try? fileManager.removeItem(at: recoveryURL)
            throw error
        }
    }

    /// Reconciles transaction markers before returning the current session to Browser.
    private func reconcileInterruptedTransactions() throws -> Data? {
        let fileManager = FileManager.default
        let artifacts = try transactionArtifacts(in: directoryURL)
        let markers = artifacts.filter { $0.kind == .transaction }
        let hasCurrentSession = try itemExists(at: fileURL)

        if let marker = markers.first {
            let previous = artifacts.first(where: { $0.kind == .previous && $0.id == marker.id })
                ?? artifacts.first(where: { $0.kind == .previous })
            if let previous {
                do {
                    try restoreCommittedSnapshot(from: previous.url, transactionID: marker.id)
                } catch {
                    return try readProtectedData(at: previous.url)
                }
            } else if hasCurrentSession {
                // Without a previous snapshot, the marked current file is only a candidate.
                try fileManager.removeItem(at: fileURL)
            }
        } else if !hasCurrentSession,
                  let previous = artifacts.first(where: { $0.kind == .previous }) {
            // A previous file is recovery material only when no committed current file exists.
            do {
                try restoreCommittedSnapshot(from: previous.url, transactionID: previous.id)
            } catch {
                return try readProtectedData(at: previous.url)
            }
        }

        let currentExists = try itemExists(at: fileURL)
        if currentExists {
            try ensureStorageProtection(for: fileURL)
        }
        removeObsoleteSessionFiles()
        return nil
    }

    private func loadLegacySession() throws -> BrowserOpenTabsSessionLoadOutcome {
        guard let legacyDirectoryURL,
              legacyDirectoryURL.standardizedFileURL != directoryURL.standardizedFileURL
        else {
            return .missing
        }
        guard try itemExists(at: legacyDirectoryURL) else {
            return .missing
        }

        let legacyFileURL = legacyDirectoryURL.appendingPathComponent("open-tabs.json", isDirectory: false)
        let artifacts = try transactionArtifacts(in: legacyDirectoryURL)
        let currentExists = try itemExists(at: legacyFileURL)
        try protectLegacySessionFiles(artifacts, currentFileURL: legacyFileURL, currentExists: currentExists)
        return try legacySessionOutcome(
            artifacts: artifacts,
            currentFileURL: legacyFileURL,
            currentExists: currentExists,
        )
    }

    /// Verifies legacy files before they can be read and discards files that remain unsafe.
    private func protectLegacySessionFiles(
        _ artifacts: [TransactionArtifact],
        currentFileURL: URL,
        currentExists: Bool,
    ) throws {
        let fileManager = FileManager.default
        var protectionFailure: (any Error)?
        for artifact in artifacts {
            do {
                try ensureStorageProtection(for: artifact.url)
            } catch {
                // Do not retain a legacy URL artifact whose protection could not be established.
                try? fileManager.removeItem(at: artifact.url)
                protectionFailure = error
            }
        }

        if currentExists {
            do {
                try ensureStorageProtection(for: currentFileURL)
            } catch {
                // Do not leave an unsafe legacy URL file behind after protection could not be established.
                try? fileManager.removeItem(at: currentFileURL)
                protectionFailure = error
            }
        }
        if let protectionFailure {
            throw protectionFailure
        }
    }

    /// Chooses the committed legacy snapshot after its storage protections have been established.
    private func legacySessionOutcome(
        artifacts: [TransactionArtifact],
        currentFileURL: URL,
        currentExists: Bool,
    ) throws -> BrowserOpenTabsSessionLoadOutcome {
        let transaction = artifacts.first(where: { $0.kind == .transaction })
        let previous = transaction.flatMap { marker in
            artifacts.first(where: { $0.kind == .previous && $0.id == marker.id })
        } ?? artifacts.first(where: { $0.kind == .previous })

        if transaction != nil {
            guard let previous else {
                removeLegacySessionFiles()
                return .missing
            }

            return try .loaded(readProtectedData(at: previous.url))
        }

        if currentExists {
            return try .loaded(readProtectedData(at: currentFileURL))
        }

        if let previous {
            return try .loaded(readProtectedData(at: previous.url))
        }

        removeLegacySessionFiles(removeCommittedSession: false)
        return .missing
    }

    private func ensureStorageProtection(for url: URL) throws {
        guard try applyAndVerifyStorageProtection(url) else {
            throw StorageError.storageProtectionNotVerified
        }
    }

    private func readProtectedData(at url: URL) throws -> Data {
        try ensureStorageProtection(for: url)
        return try Data(contentsOf: url)
    }

    private func itemExists(at url: URL) throws -> Bool {
        do {
            _ = try FileManager.default.attributesOfItem(atPath: url.path)
            return true
        } catch {
            let fileError = error as NSError
            if fileError.domain == NSCocoaErrorDomain,
               fileError.code == CocoaError.fileReadNoSuchFile.rawValue {
                return false
            }
            if fileError.domain == NSPOSIXErrorDomain, fileError.code == 2 {
                return false
            }
            throw error
        }
    }

    private func transactionArtifacts(in directory: URL) throws -> [TransactionArtifact] {
        guard try itemExists(at: directory) else {
            return []
        }

        return try FileManager.default
            .contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: [])
            .compactMap { url in
                guard let (id, kind) = Self.transactionArtifactComponents(for: url.lastPathComponent) else {
                    return nil
                }

                return TransactionArtifact(id: id, kind: kind, url: url)
            }
            .sorted { $0.url.lastPathComponent < $1.url.lastPathComponent }
    }

    private func removeObsoleteSessionFiles() {
        guard let contents = try? FileManager.default
            .contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: nil, options: [])
        else {
            return
        }

        for url in contents where url.standardizedFileURL != fileURL.standardizedFileURL {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func removeSessionDirectory() {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: directoryURL.path) else {
            return
        }

        do {
            try fileManager.removeItem(at: directoryURL)
        } catch {
            guard let contents = try? fileManager
                .contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: nil, options: [])
            else {
                return
            }

            for url in contents {
                try? fileManager.removeItem(at: url)
            }
            try? fileManager.removeItem(at: directoryURL)
        }
    }

    private func removeLegacySessionFiles(removeCommittedSession: Bool = true) {
        guard let legacyDirectoryURL,
              legacyDirectoryURL.standardizedFileURL != directoryURL.standardizedFileURL
        else {
            return
        }

        let fileManager = FileManager.default
        if removeCommittedSession {
            try? fileManager.removeItem(
                at: legacyDirectoryURL.appendingPathComponent("open-tabs.json", isDirectory: false),
            )
        }
        for artifact in (try? transactionArtifacts(in: legacyDirectoryURL)) ?? [] {
            try? fileManager.removeItem(at: artifact.url)
        }
    }

    private func artifactURL(_ kind: TransactionArtifactKind, id: String) -> URL {
        directoryURL.appendingPathComponent(".open-tabs-\(id).\(kind.rawValue)", isDirectory: false)
    }

    private static func transactionArtifactComponents(
        for fileName: String,
    ) -> (id: String, kind: TransactionArtifactKind)? {
        let prefix = ".open-tabs-"
        guard fileName.hasPrefix(prefix) else {
            return nil
        }

        let suffixStart = fileName.lastIndex(of: ".")
        guard let suffixStart else {
            return nil
        }

        let idStart = fileName.index(fileName.startIndex, offsetBy: prefix.count)
        let id = String(fileName[idStart ..< suffixStart])
        let suffix = String(fileName[fileName.index(after: suffixStart)...])
        guard UUID(uuidString: id) != nil,
              let kind = TransactionArtifactKind(rawValue: suffix)
        else {
            return nil
        }

        return (id, kind)
    }

    /// Replaces one same-directory file with an atomic filesystem rename.
    private nonisolated static func atomicallyReplace(
        stagingFileAt stagingURL: URL,
        destinationFileAt destinationURL: URL,
    ) throws {
        let result = stagingURL.path.withCString { stagingPath in
            destinationURL.path.withCString { destinationPath in
                Darwin.rename(stagingPath, destinationPath)
            }
        }
        guard result == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}

extension BrowserOpenTabsSessionStorage {
    static let live: BrowserOpenTabsSessionStorage? = {
        guard let supportDirectory = FileManager.default
            .urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
            )
            .first else {
            return nil
        }

        return BrowserOpenTabsSessionStorage(
            directoryURL: supportDirectory
                .appendingPathComponent("Browser", isDirectory: true)
                .appendingPathComponent("OpenTabsSession", isDirectory: true),
            legacyDirectoryURL: supportDirectory.appendingPathComponent("Browser", isDirectory: true),
            revisionGate: .shared,
        )
    }()
}

/// Reducer-facing boundary for loading, replacing, invalidating, or purging the Browser tab session.
struct BrowserOpenTabsSessionClient: Sendable {
    var load: @Sendable () async -> BrowserOpenTabsSessionLoadOutcome
    var save: @Sendable (BrowserOpenTabsSession, UInt64) async -> Void
    var purge: @Sendable (UInt64) async -> Void
    var advance: @Sendable (UInt64) async -> Void
    var reserveRevision: @Sendable (UInt64) -> UInt64
}

extension BrowserOpenTabsSessionClient: DependencyKey {
    static var liveValue: Self {
        let storage = BrowserOpenTabsSessionStorage.live
        return Self(
            load: { await storage?.load() ?? .failed },
            save: { session, revision in await storage?.save(session, revision: revision) },
            purge: { revision in await storage?.purge(revision: revision) },
            advance: { revision in await storage?.advance(revision: revision) },
            reserveRevision: { BrowserPersistenceRevisionGate.shared.reserve(after: $0) },
        )
    }

    static let testValue = Self(
        load: { .missing },
        save: { _, _ in },
        purge: { _ in },
        advance: { _ in },
        reserveRevision: { $0 == .max ? .max : $0 + 1 },
    )
}

extension DependencyValues {
    /// Browser-owned durable logical-tab session independent from History and website data.
    var browserOpenTabsSession: BrowserOpenTabsSessionClient {
        get { self[BrowserOpenTabsSessionClient.self] }
        set { self[BrowserOpenTabsSessionClient.self] = newValue }
    }
}
