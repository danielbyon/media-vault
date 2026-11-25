//
//  BrowserDownloadNoticeQualification.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import SwiftUI
#if DEBUG && BROWSER_DOWNLOAD_STANDALONE_QUALIFICATION
import ComposableArchitecture
@testable import BrowserFeature
#endif

/// Opt-in UI-test surface compiled only into the standalone qualification application. The
/// package-free unit-test host remains inert. This surface owns no transfers or files;
/// explicit revisions replace the notice through the same projection consumed by BrowserView.
@MainActor
enum BrowserDownloadNoticeQualification {
    static let argument = "--browser-download-notice-qualification"

    @ViewBuilder
    static var root: some View {
        #if DEBUG && BROWSER_DOWNLOAD_STANDALONE_QUALIFICATION
        BrowserDownloadNoticeQualificationRoot()
        #else
        Color.clear
        #endif
    }
}

#if DEBUG && BROWSER_DOWNLOAD_STANDALONE_QUALIFICATION
@MainActor
private struct BrowserDownloadNoticeQualificationRoot: View {
    private let store: StoreOf<BrowserFeature>

    init() {
        var state = BrowserFeature.State()
        state.downloads.revision = 1
        state.downloads.notice = .activeTransferLimitReached
        store = Store(initialState: state) {
            Reduce<BrowserFeature.State, BrowserFeature.Action> { state, action in
                if case let .downloadsChanged(snapshot) = action {
                    state.downloads = snapshot
                }
                return .none
            }
        }
    }

    var body: some View {
        BrowserView(store: store)
            .safeAreaInset(edge: .top) {
                VStack {
                    Button("Show retained-limit notice") {
                        var snapshot = BrowserDownloadSnapshot()
                        snapshot.revision = 2
                        snapshot.notice = .retainedRecordLimitReached
                        store.send(.downloadsChanged(snapshot))
                    }
                    .accessibilityIdentifier("downloadQualificationShowRetainedLimitNotice")

                    Button("Replace download notice") {
                        var snapshot = BrowserDownloadSnapshot()
                        snapshot.revision = 3
                        snapshot.notice = .transferFailed
                        store.send(.downloadsChanged(snapshot))
                    }
                    .accessibilityIdentifier("downloadQualificationReplaceDownloadNotice")
                }
                .padding()
            }
    }
}
#endif
