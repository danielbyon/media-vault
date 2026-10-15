//
//  Issue42DownloadSeparationFixture.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import ComposableArchitecture
import ConcurrencyExtras
import CoreFoundation
import Foundation
import SwiftUI
import Testing
import UIKit
@testable import AppFeature
@testable import BrowserFeature
@testable import MediaLibrary

/// Records every call the application makes through the real import dependency.
///
/// A fixture installs this recorder as the app's media-library dependency so ordinary
/// download work can be proven never to reach the library. Assertions read the ordered
/// transcript of operation names.
final class Issue42DownloadImportRecorder: Sendable {
    private let transcript = LockIsolated<[String]>([])

    /// Ordered names of library operations the application attempted.
    var calls: [String] {
        transcript.value
    }

    /// Import operations the application attempted, in order. Download-separation assertions
    /// read this projection so Library startup work cannot be mistaken for an import.
    var importFileCalls: [String] {
        transcript.value.filter { $0 == "importFile" }
    }

    func record(_ call: String) {
        transcript.withValue { $0.append(call) }
    }
}

/// Runs a real Root composition with isolated app persistence and the shared WebKit adapter.
@MainActor
func withIssue42DownloadSeparationFixture(
    _ body: (Issue42DownloadSeparationFixture) async throws -> Void,
) async throws {
    let fixture = try Issue42DownloadSeparationFixture()
    do {
        try await fixture.prepare()
        try await body(fixture)
    } catch {
        await fixture.remove()
        throw error
    }
    await fixture.remove()
}

/// Owns the Root, real WebKit transfers, and independent persistence stores used by the test.
///
/// The download owner and adapter are fixture instances instead of the process-wide singletons.
/// The shared owner's scratch store demands native file-protection readback, which the simulator
/// cannot provide, so the shared owner can never finish its startup cleanup there. Real WebKit
/// downloads still flow through the production adapter, and the Root download host authorizes
/// the fixture owner through the ordinary scene-registration path.
@MainActor
final class Issue42DownloadSeparationFixture {
    let rootDirectory: URL
    let defaults: UserDefaults
    private let defaultsSuite: String
    let settingsStorage: BrowserSettingsStorage
    let sessionStorage: BrowserOpenTabsSessionStorage
    let settingsGate: BrowserPersistenceRevisionGate
    let sessionGate: BrowserPersistenceRevisionGate
    let settingsWrites = LockIsolated<[String]>([])
    let sessionWrites = LockIsolated<[String]>([])
    let importRecorder = Issue42DownloadImportRecorder()
    let initialSettings: BrowserSettings
    let mediaLibraryClient: MediaLibraryClient
    let browserSettingsClient: BrowserSettingsClient
    let browserSessionClient: BrowserOpenTabsSessionClient
    let webKitClient: BrowserWebKitClient
    let downloadClient: BrowserDownloadClient
    let pdfServer: Issue42LoopbackServer
    let adapter: BrowserWebKitAdapter
    let owner: BrowserDownloadOwner
    let scratch = BrowserDownloadScratchStore(verifyProtection: { url in
        #if !targetEnvironment(simulator)
        try BrowserDownloadScratchStore.verifyNativeProtection(url)
        #endif
    })
    var rootStore: StoreOf<RootFeature>?
    var rootController: UIHostingController<AnyView>?
    var window: UIWindow?
    var coordinator: BrowserDownloadNativeCoordinator?
    var tabID = BrowserTabID()
    var committedURL: URL?
    var fixtureTabIDs: Set<BrowserTabID> = []

    /// Name of the isolated UserDefaults domain owned by this fixture.
    var ownedDefaultsDomainName: String { defaultsSuite }

    init() throws {
        rootDirectory = FileManager.default
            .temporaryDirectory
            .appendingPathComponent("Issue42DownloadSeparation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)

        defaultsSuite = "Issue42DownloadSeparation.\(UUID().uuidString)"
        guard let suite = UserDefaults(suiteName: defaultsSuite) else {
            throw FixtureError.defaultsUnavailable
        }

        defaults = suite
        suite.removePersistentDomain(forName: defaultsSuite)

        settingsGate = BrowserPersistenceRevisionGate()
        // The settings actor owns a separate handle to the same isolated defaults domain.
        // The fixture's observation handle remains on the main actor.
        guard let settingsDefaults = UserDefaults(suiteName: defaultsSuite) else {
            throw FixtureError.defaultsUnavailable
        }

        settingsStorage = BrowserSettingsStorage(userDefaults: settingsDefaults, revisionGate: settingsGate)
        sessionGate = BrowserPersistenceRevisionGate()
        sessionStorage = BrowserOpenTabsSessionStorage(
            directoryURL: rootDirectory.appendingPathComponent("Browser/OpenTabsSession", isDirectory: true),
            legacyDirectoryURL: rootDirectory.appendingPathComponent("Browser/Legacy", isDirectory: true),
            revisionGate: sessionGate,
        )

        pdfServer = try Issue42LoopbackServer()

        let fixtureOwner = BrowserDownloadOwner(store: scratch)
        owner = fixtureOwner
        adapter = BrowserWebKitAdapter(requiresProfileConfiguration: true, downloadOwner: fixtureOwner)

        mediaLibraryClient = makeIssue42RecordingMediaLibraryClient(recorder: importRecorder)

        browserSettingsClient = makeIssue42BrowserSettingsClient(
            storage: settingsStorage,
            gate: settingsGate,
            writes: settingsWrites,
        )
        browserSessionClient = makeIssue42BrowserSessionClient(
            storage: sessionStorage,
            gate: sessionGate,
            writes: sessionWrites,
        )

        let browserClients = makeIssue42BrowserWebKitClients(adapter: adapter, owner: owner)
        webKitClient = browserClients.webKit
        downloadClient = browserClients.downloads

        initialSettings = makeIssue42InitialSettings()
    }

    func remove() async {
        owner.invalidateAuthorization()
        unmountRoot()
        destroyFixtureAdapterContexts()
        pdfServer.stop()
        let drained = await waitForOwnedWorkToDrain()
        #expect(
            drained,
            "Fixture teardown waits for shared WebKit writer acknowledgements and scratch cleanup before returning.",
        )
        defaults.removePersistentDomain(forName: defaultsSuite)
        if drained {
            try? FileManager.default.removeItem(at: rootDirectory)
        }
    }

    private func destroyFixtureAdapterContexts() {
        for fixtureTabID in fixtureTabIDs {
            adapter.destroyContext(for: fixtureTabID)
        }
        fixtureTabIDs.removeAll()
    }

    private func waitForOwnedWorkToDrain() async -> Bool {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            let isDrained = owner.activeCount == 0
                && owner.retainedCount == 0
                && !owner.privacyCleanupPending
                && scratchEntries().isEmpty
            if isDrained {
                return true
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return owner.activeCount == 0
            && owner.retainedCount == 0
            && !owner.privacyCleanupPending
            && scratchEntries().isEmpty
    }

    func wait(_ description: String, until predicate: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !predicate(), Date() < deadline {
            rootController?.viewIfLoaded?.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(predicate(), "Timed out waiting for \(description)")
    }

    private enum FixtureError: Error {
        case defaultsUnavailable
    }
}

/// Values captured after startup so setup writes cannot be misattributed to a download.
struct PersistenceCheckpoint: Equatable {
    let settings: BrowserSettings
    let defaultsDomain: DefaultsDomainSnapshot
    let settingsWrites: [String]
    let sessionWrites: [String]
    let sessionData: Data?
    let sessionOutcome: BrowserOpenTabsSessionLoadOutcome
    let importFileCalls: [String]
}

/// Order-independent semantic snapshot of one UserDefaults domain.
///
/// The snapshot stores decoded property-list values so two captures of the same domain can be
/// compared key by key. Comparing snapshots avoids depending on the byte layout of a serialized
/// aggregate, which is not a persistence property.
struct DefaultsDomainSnapshot: Equatable {
    /// Decoded value for every key currently present in the domain.
    let entries: [String: DefaultsDomainValue]

    /// Captures the semantic content of a domain dictionary returned by `persistentDomain(forName:)`.
    init(domain: [String: Any]) {
        entries = domain.mapValues { DefaultsDomainValue(plistValue: $0) }
    }

    /// Computes how this snapshot differs from an earlier one.
    func difference(from baseline: DefaultsDomainSnapshot) -> DefaultsDomainDifference {
        var added: [String] = []
        var removed: [String] = []
        var changed: [String] = []
        for (key, value) in entries where baseline.entries[key] == nil {
            added.append(key + ":" + value.typeName)
        }
        for (key, value) in baseline.entries {
            guard let current = entries[key] else {
                removed.append(key + ":" + value.typeName)
                continue
            }
            if current != value {
                changed.append(key + ":" + value.typeName + "->" + current.typeName)
            }
        }
        return DefaultsDomainDifference(
            added: added.sorted(),
            removed: removed.sorted(),
            changed: changed.sorted(),
        )
    }
}

/// Difference between two defaults domain snapshots.
///
/// Every entry names only a key and its value type, so diagnostics never expose stored values.
struct DefaultsDomainDifference: Equatable {
    /// Keys the current snapshot added, formatted as `key:ValueType`.
    var added: [String]
    /// Keys the current snapshot dropped, formatted as `key:ValueType`.
    var removed: [String]
    /// Keys whose value changed, formatted as `key:OldValueType->NewValueType`.
    var changed: [String]

    /// True when the two snapshots describe the same keys with semantically equal values.
    var isEmpty: Bool {
        added.isEmpty && removed.isEmpty && changed.isEmpty
    }

    /// Sorted, human-readable summary for assertion diagnostics.
    var summary: String {
        var parts: [String] = []
        if !added.isEmpty {
            parts.append("added [" + added.joined(separator: ", ") + "]")
        }
        if !removed.isEmpty {
            parts.append("removed [" + removed.joined(separator: ", ") + "]")
        }
        if !changed.isEmpty {
            parts.append("changed [" + changed.joined(separator: ", ") + "]")
        }
        return parts.joined(separator: "; ")
    }
}

/// Semantic representation of one decoded defaults value.
///
/// Equality compares stored content, while `typeName` provides the only rendering that
/// diagnostics may use.
enum DefaultsDomainValue: Equatable {
    case bool(Bool)
    case int(Int64)
    case uint(UInt64)
    case double(Double)
    case string(String)
    case data(Data)
    case date(Date)
    case array([DefaultsDomainValue])
    case dictionary([String: DefaultsDomainValue])
    case other(String)

    /// Decodes a property-list value returned by `UserDefaults`.
    init(plistValue: Any) {
        if let number = plistValue as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                self = .bool(number.boolValue)
            } else {
                switch String(cString: number.objCType) {
                case "f", "d":
                    self = .double(number.doubleValue)
                case "c", "s", "i", "l", "q":
                    self = .int(number.int64Value)
                case "C", "S", "I", "L", "Q":
                    self = .uint(number.uint64Value)
                default:
                    // Unknown numeric encodings compare as doubles so a fractional
                    // value can never be silently conflated with its truncation.
                    self = .double(number.doubleValue)
                }
            }
        } else if let string = plistValue as? String {
            self = .string(string)
        } else if let data = plistValue as? Data {
            self = .data(data)
        } else if let date = plistValue as? Date {
            self = .date(date)
        } else if let array = plistValue as? [Any] {
            self = .array(array.map { DefaultsDomainValue(plistValue: $0) })
        } else if let dictionary = plistValue as? [String: Any] {
            self = .dictionary(dictionary.mapValues { DefaultsDomainValue(plistValue: $0) })
        } else {
            self = .other(String(describing: type(of: plistValue)))
        }
    }

    /// Name of the represented value type, safe to include in diagnostics.
    var typeName: String {
        switch self {
        case .bool: "Bool"
        case .int: "Int"
        case .uint: "UInt"
        case .double: "Double"
        case .string: "String"
        case .data: "Data"
        case .date: "Date"
        case .array: "Array"
        case .dictionary: "Dictionary"
        case .other(let name): name
        }
    }

    /// Compares values by semantics rather than by encoding.
    ///
    /// Signed and unsigned integers holding the same non-negative number are equal, while a
    /// negative signed value never equals an unsigned value such as `UInt64.max`.
    static func == (lhs: DefaultsDomainValue, rhs: DefaultsDomainValue) -> Bool {
        switch (lhs, rhs) {
        case let (.bool(lhsValue), .bool(rhsValue)):
            lhsValue == rhsValue
        case let (.int(lhsValue), .int(rhsValue)):
            lhsValue == rhsValue
        case let (.uint(lhsValue), .uint(rhsValue)):
            lhsValue == rhsValue
        case let (.int(lhsValue), .uint(rhsValue)) where lhsValue >= 0:
            UInt64(lhsValue) == rhsValue
        case let (.uint(lhsValue), .int(rhsValue)) where rhsValue >= 0:
            UInt64(rhsValue) == lhsValue
        case let (.double(lhsValue), .double(rhsValue)):
            lhsValue == rhsValue
        case let (.string(lhsValue), .string(rhsValue)):
            lhsValue == rhsValue
        case let (.data(lhsValue), .data(rhsValue)):
            lhsValue == rhsValue
        case let (.date(lhsValue), .date(rhsValue)):
            lhsValue == rhsValue
        case let (.array(lhsValue), .array(rhsValue)):
            lhsValue == rhsValue
        case let (.dictionary(lhsValue), .dictionary(rhsValue)):
            lhsValue == rhsValue
        case let (.other(lhsValue), .other(rhsValue)):
            lhsValue == rhsValue
        default:
            false
        }
    }
}

/// Replaces the app's import dependency with a recorder that performs no library work.
///
/// Reads answer with empty results so Library startup reaches its ordinary loaded state.
/// Imports and resource reads record their own name and then fail like an unavailable
/// library, so a caller expecting a successful import cannot silently pass. Recording only
/// the call name keeps the transcript free of source paths and media content.
@MainActor
func makeIssue42RecordingMediaLibraryClient(recorder: Issue42DownloadImportRecorder) -> MediaLibraryClient {
    MediaLibraryClient(
        loadAssets: {
            recorder.record("loadAssets")
            return []
        },
        importFile: { _ in
            recorder.record("importFile")
            throw MediaImportError.persistenceFailed
        },
        resourceData: { _ in
            recorder.record("resourceData")
            throw MediaLibraryStoreError.unavailable
        },
    )
}
