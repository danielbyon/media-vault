//
//  BrowserWebKitReadinessCoordinator.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import UIKit
import WebKit

/// Revision-scoped evidence supplied by the current in-memory preview.
@MainActor
struct BrowserWebKitReadinessContext: Equatable {
    let revision: BrowserTabPreviewRevision
    let expectedSignature: BrowserWebKitVisualSignature?
    /// Prevents a pending reducer navigation from treating the previously committed document as
    /// evidence until that operation has completed and the reducer has consumed its metadata.
    let requiresFreshCommit: Bool

    init(
        revision: BrowserTabPreviewRevision,
        expectedSignature: BrowserWebKitVisualSignature? = nil,
        requiresFreshCommit: Bool = false,
    ) {
        self.revision = revision
        self.expectedSignature = expectedSignature
        self.requiresFreshCommit = requiresFreshCommit
    }
}

/// Retains only revision-scoped preview signatures needed to build readiness contexts.
@MainActor
private final class BrowserWebKitReadinessCache {
    private struct CachedPreview {
        let revision: BrowserTabPreviewRevision
        /// Required to distinguish same-revision preview replacement without hashing or weakening
        /// the exact byte-equality contract. `Data` remains copy-on-write with preview state.
        let pngData: Data
        let signature: BrowserWebKitVisualSignature?
    }

    private var previewEntries: [BrowserTabID: CachedPreview] = [:]

    /// Removes decoded preview evidence for tabs that no longer exist in reducer state.
    func removeEntries(except tabIDs: Set<BrowserTabID>) {
        previewEntries = previewEntries.filter { tabIDs.contains($0.key) }
    }

    /// Drops every retained preview signature after memory pressure or an explicit readiness reset.
    func removeAll() {
        previewEntries.removeAll()
    }

    /// Builds the revision-scoped evidence context consumed by the mounted WebKit boundary.
    func context(
        for tab: BrowserTab,
        revision: BrowserTabPreviewRevision,
        previewEntry: BrowserTabPreviewCacheEntry?,
        requiresFreshCommit: Bool = false,
    ) -> BrowserWebKitReadinessContext {
        BrowserWebKitReadinessContext(
            revision: revision,
            expectedSignature: expectedSignature(
                for: tab,
                revision: revision,
                previewEntry: previewEntry,
            ),
            requiresFreshCommit: requiresFreshCommit,
        )
    }

    private func expectedSignature(
        for tab: BrowserTab,
        revision: BrowserTabPreviewRevision,
        previewEntry: BrowserTabPreviewCacheEntry?,
    ) -> BrowserWebKitVisualSignature? {
        let representation = BrowserTabPreviewRepresentation.cachedOrFallback(
            for: tab,
            revision: revision,
            entry: previewEntry,
        )
        guard case let .snapshot(data) = representation,
              !data.isEmpty
        else {
            previewEntries[tab.id] = nil
            return nil
        }

        if let entry = previewEntries[tab.id],
           entry.revision == revision,
           entry.pngData == data {
            return entry.signature
        }

        let signature = BrowserWebKitVisualSignature(imageData: data)
        previewEntries[tab.id] = CachedPreview(
            revision: revision,
            pngData: data,
            signature: signature,
        )
        return signature
    }
}

/// Owns the active WebKit probe and coordinates it with adapter identity and transition events.
@MainActor
final class BrowserWebKitReadinessCoordinator {
    private let adapter: BrowserWebKitAdapter
    private let cache = BrowserWebKitReadinessCache()
    private var readinessProbe: BrowserWebKitReadinessProbe?
    private var readinessProbeGeneration = 0

    init(adapter: BrowserWebKitAdapter = .shared) {
        self.adapter = adapter
    }

    func removeEntries(except tabIDs: Set<BrowserTabID>) {
        cache.removeEntries(except: tabIDs)
    }

    func removeAll() {
        invalidate()
        cache.removeAll()
    }

    func context(
        for tab: BrowserTab,
        revision: BrowserTabPreviewRevision,
        previewEntry: BrowserTabPreviewCacheEntry?,
        requiresFreshCommit: Bool = false,
    ) -> BrowserWebKitReadinessContext {
        cache.context(
            for: tab,
            revision: revision,
            previewEntry: previewEntry,
            requiresFreshCommit: requiresFreshCommit,
        )
    }

    func invalidate() {
        readinessProbeGeneration &+= 1
        readinessProbe?.invalidate()
        readinessProbe = nil
    }

    private func ownsReadinessProbe(generation: Int) -> Bool {
        readinessProbeGeneration == generation && readinessProbe != nil
    }

    func resolve(
        _ readinessContext: BrowserWebKitReadinessContext?,
        for webView: WKWebView,
        tabID: BrowserTabID,
    ) -> BrowserWebKitReadinessContext? {
        guard let readinessContext else {
            return nil
        }
        guard adapter.webView(for: tabID) === webView else {
            return nil
        }

        return readinessContext
    }

    func schedule(
        for view: UIView,
        tabID: BrowserTabID,
        readinessContext: BrowserWebKitReadinessContext?,
        onResult: @escaping (BrowserWebKitReadinessResult) -> Void,
        onVisualInvalid: @escaping () -> Void,
    ) {
        if readinessProbe?.matches(view: view, readinessContext: readinessContext) == true {
            return
        }

        readinessProbe?.invalidate()
        readinessProbeGeneration &+= 1
        let generation = readinessProbeGeneration
        let probe = BrowserWebKitReadinessProbe(
            view: view,
            readinessContext: readinessContext,
            hasCommittedDocument: { [weak view, adapter] in
                guard let view,
                      let adapterWebView = adapter.webView(for: tabID),
                      adapterWebView === view
                else {
                    return false
                }

                return adapter.hasCommittedDocument(for: tabID)
            },
            onResult: { [weak self] result in
                guard let self,
                      ownsReadinessProbe(generation: generation)
                else {
                    return
                }

                readinessProbe = nil
                onResult(result)
            },
            onVisualInvalid: { [weak self] in
                guard let self,
                      ownsReadinessProbe(generation: generation)
                else {
                    return
                }

                onVisualInvalid()
            },
        )
        readinessProbe = probe
        probe.start()
    }
}
