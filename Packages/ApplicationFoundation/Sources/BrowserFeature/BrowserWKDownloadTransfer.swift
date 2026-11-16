//
//  BrowserWKDownloadTransfer.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import ObjectiveC
import WebKit

/// Keeps the actual originating download, its delegate, and progress observations alive together.
/// It never reconstructs requests, retains credentials/resume data, or creates another web view.
@MainActor
final class BrowserWKDownloadTransfer: NSObject, BrowserDownloadTransfer, WKDownloadDelegate {
    private let download: WKDownload
    private var originatingWebView: WKWebView?
    private weak var owner: BrowserDownloadOwner?
    private var id: BrowserDownloadID?
    private var observations: [NSKeyValueObservation] = []

    var identity: AnyObject {
        download
    }

    init(download: WKDownload, owner: BrowserDownloadOwner) {
        self.download = download
        originatingWebView = download.webView
        self.owner = owner
        super.init()
        download.delegate = self
    }

    /// Starts observations only after the owner has registered this writer's identity.
    func registered(_ id: BrowserDownloadID) {
        self.id = id
        observations = [
            download.progress.observe(\.completedUnitCount, options: [.initial, .new]) { [weak self] progress, _ in
                let completed = progress.completedUnitCount
                let total = progress.totalUnitCount
                Task { @MainActor in self?.reportProgress(completed: completed, total: total) }
            },
            download.progress.observe(\.totalUnitCount, options: [.new]) { [weak self] progress, _ in
                let completed = progress.completedUnitCount
                let total = progress.totalUnitCount
                Task { @MainActor in self?.reportProgress(completed: completed, total: total) }
            },
        ]
    }

    func cancel(completion: @escaping @MainActor () -> Void) {
        download.cancel { [weak self] _ in
            self?.originatingWebView = nil
            completion()
        }
    }

    func download(
        _: WKDownload,
        decideDestinationUsing response: URLResponse,
        suggestedFilename: String,
        completionHandler: @MainActor (URL?) -> Void,
    ) {
        guard let id else {
            completionHandler(nil)
            return
        }

        completionHandler(owner?.destination(
            for: id,
            suggestedName: suggestedFilename,
            expectedLength: response.expectedContentLength > 0 ? response.expectedContentLength : nil,
        ))
    }

    /// Placeholders would create a second, system-managed copy outside the protected scratch root.
    func download(
        _: WKDownload,
        decidePlaceholderPolicy completionHandler: @MainActor (WKDownload.PlaceholderPolicy, URL?) -> Void,
    ) {
        completionHandler(.disable, nil)
    }

    func downloadDidFinish(_: WKDownload) {
        originatingWebView = nil
        observations.removeAll()
        if let id {
            owner?.finished(id)
        } else {
            owner?.rejectedTerminated(download)
        }
    }

    func download(_: WKDownload, didFailWithError error: Error, resumeData _: Data?) {
        originatingWebView = nil
        observations.removeAll()
        if let id {
            owner?.failed(id, error: error)
        } else {
            owner?.rejectedTerminated(download)
        }
    }

    private func reportProgress(completed: Int64, total: Int64) {
        if let id {
            owner?.progress(id: id, completed: completed, total: total > 0 ? total : nil)
        }
    }
}
