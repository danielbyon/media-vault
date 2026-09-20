//
//  BrowserTabPreviewRepresentation.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

/// The deterministic visual fallback used when a tab has no usable snapshot.
enum BrowserTabPreviewPlaceholder: Equatable, Sendable {
    /// The app-owned Start Page surface.
    case startPage
    /// A web tab whose live page has not produced a usable preview.
    case web
    /// App-owned recoverable navigation failure UI.
    case error
    /// App-owned terminated-process recovery UI.
    case terminated
}

/// Disposable preview bytes paired with the document revision that produced them.
///
/// Preview bytes are intentionally retained only in reducer memory. The revision prevents a
/// capture that belongs to an earlier document from being rendered after the tab has advanced.
struct BrowserTabPreviewCacheEntry: Equatable, Sendable {
    /// The live document revision represented by `pngData`.
    let revision: BrowserTabPreviewRevision
    /// PNG bytes captured from the corresponding visible surface.
    let pngData: Data

    /// Creates one revision-scoped transient preview entry.
    init(revision: BrowserTabPreviewRevision, pngData: Data) {
        self.revision = revision
        self.pngData = pngData
    }
}

/// A preview representation that can be frozen independently of live Browser content.
enum BrowserTabPreviewRepresentation: Equatable, Sendable {
    /// Disposable PNG bytes captured from a visible Browser surface.
    case snapshot(Data)
    /// A deterministic representation used when no snapshot is available.
    case placeholder(BrowserTabPreviewPlaceholder)

    /// Returns the content-specific fallback for a logical tab.
    static func fallback(for tab: BrowserTab) -> Self {
        switch tab.content {
        case .startPage:
            .placeholder(.startPage)
        case .web:
            .placeholder(.web)
        case .error:
            .placeholder(.error)
        case .terminated:
            .placeholder(.terminated)
        }
    }

    /// Uses a cached non-empty snapshot only when it belongs to the current document revision.
    static func cachedOrFallback(
        for tab: BrowserTab,
        revision: BrowserTabPreviewRevision,
        entry: BrowserTabPreviewCacheEntry?,
    ) -> Self {
        guard let entry,
              entry.revision == revision,
              !entry.pngData.isEmpty
        else {
            return fallback(for: tab)
        }

        return .snapshot(entry.pngData)
    }
}
