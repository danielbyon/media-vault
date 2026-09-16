//
//  BrowserClipboardClient.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import ComposableArchitecture
import Foundation
import UIKit

/// User-initiated clipboard inspection and writing boundary for Browser behavior.
struct BrowserClipboardClient: Sendable {
    var readHTTPURL: @Sendable () async -> URL?
    var writeURL: @Sendable (URL) async -> Void
}

extension BrowserClipboardClient: DependencyKey {
    static let liveValue = Self(
        readHTTPURL: { await readLiveClipboardURL() },
        writeURL: { url in await MainActor.run { UIPasteboard.general.url = url } },
    )
    static let testValue = Self(readHTTPURL: { nil }, writeURL: { _ in })

    @MainActor
    private static func readLiveClipboardURL() -> URL? {
        let url = UIPasteboard.general.url
        guard let scheme = url?.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return nil
        }

        return url
    }
}

extension DependencyValues {
    /// Reducer-facing clipboard boundary.
    var browserClipboard: BrowserClipboardClient {
        get { self[BrowserClipboardClient.self] }
        set { self[BrowserClipboardClient.self] = newValue }
    }
}
