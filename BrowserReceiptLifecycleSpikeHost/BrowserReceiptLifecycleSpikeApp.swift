//
//  BrowserReceiptLifecycleSpikeApp.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Observation
import SwiftUI
import UIKit

private enum Spike6Fixture {
    static let backgroundIdentifier = "com.danielbyon.mediavault.browserreceiptlifecycle.background"
    /// Test-only launch argument that holds task enumeration open long enough to verify the start gate.
    static let delayedTaskEnumerationArgument = "--spike-delay-task-enumeration"
    /// A physical-device build may name one RFC 1918 host for the same fixed fixture routes.
    private static let host: String = {
        let configured = Bundle.main.object(forInfoDictionaryKey: "Spike6FixtureHost") as? String
        let address = configured ?? "127.0.0.1"
        let octets = address.split(separator: ".").compactMap { UInt8($0) }
        precondition(octets.count == 4 && (
            octets[0] == 127
                || octets[0] == 10
                || (octets[0] == 172 && (16 ... 31).contains(octets[1]))
                || (octets[0] == 192 && octets[1] == 168)
        ), "The fixture host must be a numeric loopback or private IPv4 address")
        return address
    }()

    static let still: URL = {
        guard let url = URL(string: "http://\(host):18756/media/still") else {
            preconditionFailure("The static still fixture URL must be valid")
        }

        return url
    }()

    static let slow: URL = {
        guard let url = URL(string: "http://\(host):18756/media/slow") else {
            preconditionFailure("The static slow fixture URL must be valid")
        }

        return url
    }()

    static let timeout: URL = {
        guard let url = URL(string: "http://\(host):18756/media/timeout") else {
            preconditionFailure("The static timeout fixture URL must be valid")
        }

        return url
    }()
}

@main
@MainActor
struct BrowserReceiptLifecycleSpikeApp: App {
    @UIApplicationDelegateAdaptor(ReceiptSpikeDelegate.self)
    private var appDelegate
    @State
    private var coordinator = ReceiptSpikeCoordinator.shared
    @Environment(\.scenePhase)
    private var scenePhase

    var body: some Scene {
        WindowGroup {
            VStack(spacing: 16) {
                Text("Receipt lifecycle experiment").font(.title2)
                Text(coordinator.status).accessibilityIdentifier("receipt-status")
                Text("Published receipts: \(coordinator.publishedCount)")
                    .accessibilityIdentifier("receipt-count")
                Button("Start still GET") { coordinator.startTransfer(at: Spike6Fixture.still) }
                    .accessibilityIdentifier("start-still")
                    .disabled(coordinator.isRestoringTasks)
                Button("Start slow GET") { coordinator.startTransfer(at: Spike6Fixture.slow) }
                    .accessibilityIdentifier("start-slow")
                    .disabled(coordinator.isRestoringTasks)
                Button("Start timeout GET") { coordinator.startTransfer(at: Spike6Fixture.timeout) }
                    .accessibilityIdentifier("start-timeout")
                    .disabled(coordinator.isRestoringTasks)
                Button("Cancel transfer") { coordinator.cancelActiveTransfer() }
                    .accessibilityIdentifier("cancel-transfer")
                Button("Explicit test unlock") { coordinator.unlockTestSeam() }
                    .accessibilityIdentifier("test-unlock")
                Button("Inspect after unlock") { coordinator.verifyReceiptsAfterUnlock() }
                    .accessibilityIdentifier("verify-receipts")
            }
            .padding()
            .task { coordinator.startIfNeeded() }
            .onChange(of: scenePhase) { _, phase in
                coordinator.record("scene-phase", fields: ["phase": String(describing: phase)])
            }
        }
    }
}

/// Reattaches the single background session before delivery of restored events.
@MainActor
final class ReceiptSpikeDelegate: NSObject, UIApplicationDelegate {
    func application(
        _: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil,
    ) -> Bool {
        ReceiptSpikeCoordinator.shared.startIfNeeded()
        ReceiptSpikeCoordinator.shared.record(
            "app-launched",
            fields: ["launchOptionsPresent": String(launchOptions?.isEmpty == false)],
        )
        return true
    }

    func application(
        _: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void,
    ) {
        ReceiptSpikeCoordinator.shared.handleBackgroundEvents(
            identifier: identifier,
            completionHandler: completionHandler,
        )
    }
}

/// Test-only acquisition coordinator. It cannot open a vault database.
@MainActor
@Observable
final class ReceiptSpikeCoordinator: NSObject, URLSessionDownloadDelegate {
    static let shared = ReceiptSpikeCoordinator()

    private(set) var status = "starting"
    private(set) var publishedCount = 0
    /// Prevents a new transfer until the background session task inventory is restored.
    private(set) var isRestoringTasks = true
    private var session: URLSession?
    private var activeTask: URLSessionDownloadTask?
    private var cancelledTaskIdentifiers: Set<Int> = []
    private var backgroundCompletionHandler: (() -> Void)?
    private var didFinishBackgroundEvents = false
    private var pendingReceiptCallbacks = 0
    private var transferTimeoutTask: Task<Void, Never>?
    private let processID = UUID().uuidString.lowercased()
    private let fileManager = FileManager.default
    private var testUnlocked = false

    private var experimentRoot: URL {
        guard let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            preconditionFailure("Application Support must exist for a protected receipt")
        }

        return support.appendingPathComponent("BrowserReceiptLifecycleSpike", isDirectory: true)
    }

    private var eventURL: URL {
        experimentRoot.appendingPathComponent("events.jsonl")
    }

    private var receiptRoot: URL {
        experimentRoot.appendingPathComponent("receipts", isDirectory: true)
    }

    /// Recreates the same URLSession identifier and enumerates system-owned tasks.
    func startIfNeeded() {
        guard session == nil else {
            return
        }

        do {
            try fileManager.createDirectory(at: experimentRoot, withIntermediateDirectories: true)
            let store = try ReceiptStore(rootURL: receiptRoot)
            publishedCount = try store.discoverMetadata().count
            status = "locked; \(publishedCount) receipt(s) discoverable"
            record("locked-metadata-scan", fields: ["receiptCount": String(publishedCount), "vaultOpened": "false"])
        } catch {
            status = "receipt metadata unavailable"
            record("metadata-scan-failed", fields: ["errorCode": String((error as NSError).code)])
        }

        let configuration = URLSessionConfiguration.background(withIdentifier: Spike6Fixture.backgroundIdentifier)
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.isDiscretionary = false
        configuration.sessionSendsLaunchEvents = true
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 120
        let created = URLSession(configuration: configuration, delegate: self, delegateQueue: .main)
        session = created
        isRestoringTasks = true
        let delaysTaskEnumeration = ProcessInfo.processInfo.arguments.contains(
            Spike6Fixture.delayedTaskEnumerationArgument,
        )
        created.getAllTasks { [weak self] tasks in
            Task { @MainActor in
                guard let self else { return }
                if delaysTaskEnumeration {
                    try? await Task.sleep(for: .seconds(12))
                }
                let restoredTask = tasks
                    .compactMap { $0 as? URLSessionDownloadTask }
                    .first { task in
                        (task.state == .running || task.state == .suspended)
                            && self.identity(for: task) != nil
                    }
                guard self.session === created else { return }
                self.isRestoringTasks = false
                self.activeTask = self.activeTask ?? restoredTask
                if let restoredTask, let identity = self.identity(for: restoredTask) {
                    self.status = "downloading (reattached)"
                    self.record("session-reattached", identity: identity, fields: [
                        "taskCount": String(tasks.count),
                        "taskID": String(restoredTask.taskIdentifier),
                    ])
                } else {
                    self.record("session-reattached", fields: ["taskCount": String(tasks.count)])
                }
            }
        }
    }

    /// Starts only a fixture-backed, explicit idempotent GET with no credentials.
    func startTransfer(at url: URL) {
        record("transfer-start-attempt")
        guard url == Spike6Fixture.still || url == Spike6Fixture.slow || url == Spike6Fixture.timeout else {
            status = "unsupported request"
            record("transfer-start-rejected", fields: ["reason": "unsupported"])
            return
        }

        startIfNeeded()
        guard !isRestoringTasks else {
            status = "restoring background tasks"
            record("transfer-start-rejected", fields: ["reason": "active-or-unavailable"])
            return
        }
        guard activeTask == nil, let session else {
            status = "transfer already active or session unavailable"
            record("transfer-start-rejected", fields: ["reason": "active-or-unavailable"])
            return
        }

        do {
            let store = try ReceiptStore(rootURL: receiptRoot)
            let reported = try store.probeProtectionInheritance()
            record("protection-inheritance", fields: ["inheritanceProtection": reported])
        } catch {
            status = "receipt protection unavailable"
            record("transfer-start-rejected", fields: ["reason": "protection"])
            return
        }

        let identity = ReceiptIdentity(transferID: UUID(), assetID: UUID(), resourceID: UUID())
        let correlatedURL = url.appending(queryItems: [URLQueryItem(
            name: "transfer",
            value: identity.transferID.uuidString.lowercased(),
        )])
        var request = URLRequest(url: correlatedURL)
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false
        let task = session.downloadTask(with: request)
        task.taskDescription = try? String(data: JSONEncoder().encode(identity), encoding: .utf8)
        activeTask = task
        status = "downloading"
        record("transfer-started", identity: identity, fields: ["method": "GET", "credentialsAttached": "false"])
        task.resume()
        if url == Spike6Fixture.timeout {
            let taskID = task.taskIdentifier
            transferTimeoutTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled, let self,
                      activeTask?.taskIdentifier == taskID else {
                    return
                }

                activeTask?.cancel()
                activeTask = nil
                transferTimeoutTask = nil
                status = "transfer timed out"
                record("transfer-timeout", identity: identity, fields: ["synthetic": "true"])
            }
        }
    }

    func cancelActiveTransfer() {
        guard let activeTask else {
            return
        }

        cancelledTaskIdentifiers.insert(activeTask.taskIdentifier)
        activeTask.cancel()
        self.activeTask = nil
        transferTimeoutTask?.cancel()
        transferTimeoutTask = nil
        status = "cancelled"
        record("transfer-cancelled")
    }

    /// Synthetic gate only; it is neither real vault authentication nor device unlock.
    func unlockTestSeam() {
        testUnlocked = true
        record("test-unlock", fields: ["synthetic": "true"])
        status = "test seam unlocked"
    }

    func verifyReceiptsAfterUnlock() {
        guard testUnlocked else {
            status = "test unlock required"
            record("verification-deferred", fields: ["vaultOpened": "false"])
            return
        }

        do {
            let store = try ReceiptStore(rootURL: receiptRoot)
            let manifests = try store.discoverMetadata()
            for manifest in manifests {
                let verified = try store.verifyAfterUnlock(manifest)
                record("receipt-verified", identity: manifest.identity, fields: [
                    "verified": String(verified),
                    "byteCount": String(manifest.byteCount),
                    "sha256": manifest.sha256,
                ])
                guard verified else {
                    status = "receipt mismatch"
                    return
                }
            }
            publishedCount = manifests.count
            status = "verified \(manifests.count) receipt(s)"
        } catch {
            status = "receipt verification failed"
            record("verification-failed", fields: ["errorCode": String((error as NSError).code)])
        }
    }

    func handleBackgroundEvents(identifier: String, completionHandler: @escaping () -> Void) {
        guard identifier == Spike6Fixture.backgroundIdentifier else {
            completionHandler()
            return
        }

        startIfNeeded()
        backgroundCompletionHandler = completionHandler
        didFinishBackgroundEvents = false
        record("background-events-delivered")
    }

    nonisolated func urlSession(
        _: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL,
    ) {
        MainActor.assumeIsolated {
            pendingReceiptCallbacks += 1
            defer { pendingReceiptCallbacks -= 1
                finishBackgroundEventsIfSettled()
            }
            guard let identity = identity(for: downloadTask),
                  let response = downloadTask.response as? HTTPURLResponse,
                  response.statusCode == 200
            else {
                status = "rejected response"
                record("receipt-rejected", fields: ["reason": "response"])
                return
            }

            do {
                let sourceAttributes = try fileManager.attributesOfItem(atPath: location.path)
                guard let size = sourceAttributes[.size] as? Int else {
                    throw ReceiptStoreError.invalidTransfer
                }
                guard response.expectedContentLength < 0
                    || response.expectedContentLength == Int64(size) else {
                    throw ReceiptStoreError.invalidTransfer
                }

                let store = try ReceiptStore(rootURL: receiptRoot)
                // This synchronous call preserves URLSession's temporary file
                // before the download delegate returns to Foundation.
                let manifest = try store.publish(
                    from: location,
                    identity: identity,
                    expectedByteCount: Int64(size),
                )
                publishedCount = try store.discoverMetadata().count
                status = "receipt accepted"
                var evidence = store.protectionEvidence(for: manifest)
                evidence.merge([
                    "byteCount": String(manifest.byteCount),
                    "sha256": manifest.sha256,
                    "protectionRequested": "completeUnlessOpen",
                    "vaultOpened": "false",
                ]) { _, new in new }
                record("receipt-accepted", identity: identity, fields: evidence)
            } catch {
                status = "receipt rejected"
                record("receipt-rejected", identity: identity, fields: ["errorCode": String((error as NSError).code)])
            }
        }
    }

    nonisolated func urlSession(_: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        MainActor.assumeIsolated {
            if activeTask?.taskIdentifier == task.taskIdentifier {
                activeTask = nil
                transferTimeoutTask?.cancel()
                transferTimeoutTask = nil
            }
            record("transfer-terminal", identity: identity(for: task), fields: [
                "errorCode": error.map { String(($0 as NSError).code) } ?? "none",
                "taskID": String(task.taskIdentifier),
            ])
            if cancelledTaskIdentifiers.remove(task.taskIdentifier) != nil {
                status = "cancelled (terminal callback observed)"
            }
            finishBackgroundEventsIfSettled()
        }
    }

    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession _: URLSession) {
        MainActor.assumeIsolated {
            didFinishBackgroundEvents = true
            finishBackgroundEventsIfSettled()
        }
    }

    private func finishBackgroundEventsIfSettled() {
        guard didFinishBackgroundEvents, pendingReceiptCallbacks == 0,
              let completion = backgroundCompletionHandler else {
            return
        }

        backgroundCompletionHandler = nil
        didFinishBackgroundEvents = false
        record("background-events-settled")
        completion()
    }

    private func identity(for task: URLSessionTask) -> ReceiptIdentity? {
        guard let description = task.taskDescription else {
            return nil
        }

        let data = Data(description.utf8)
        return try? JSONDecoder().decode(ReceiptIdentity.self, from: data)
    }

    /// Writes only fixed event names, opaque IDs, counts, and digests.
    func record(_ kind: String, identity: ReceiptIdentity? = nil, fields: [String: String] = [:]) {
        var row = fields
        row["kind"] = kind
        row["processID"] = processID
        if let identity {
            row["transferID"] = identity.transferID.uuidString.lowercased()
            row["assetID"] = identity.assetID.uuidString.lowercased()
            row["resourceID"] = identity.resourceID.uuidString.lowercased()
        }
        do {
            try fileManager.createDirectory(at: experimentRoot, withIntermediateDirectories: true)
            try requestBackupExclusion(at: experimentRoot)
            let data = try JSONEncoder().encode(row) + Data([0x0a])
            if !fileManager.fileExists(atPath: eventURL.path) {
                _ = fileManager.createFile(atPath: eventURL.path, contents: nil)
            }
            try requestBackupExclusion(at: eventURL)
            let handle = try FileHandle(forWritingTo: eventURL)
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
        } catch {
            status = "evidence write failed"
        }
    }
}
