//
//  native-api-probe.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import SwiftUI
import WebKit

@MainActor
func probeNativeContextMenu(_ view: WebView) {
    _ = view.webViewContextMenu { element in
        Button("Save to Vault: \(element.linkURL?.absoluteString ?? "absent")") {}
    }
}
