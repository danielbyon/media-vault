//
//  Issue42BrowserNoticeQualification.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import SwiftUI
#if DEBUG && ISSUE42_STANDALONE_QUALIFICATION
import ComposableArchitecture
@testable import BrowserFeature
#endif

/// Opt-in UI-test surface compiled only into the standalone qualification application. The
/// package-free unit-test host remains inert. This surface owns no transfers or files;
/// explicit revisions replace the notice through the same projection consumed by BrowserView.
@MainActor
enum Issue42BrowserNoticeQualification {
    static let argument = "--issue42-browser-notice-qualification"

    @ViewBuilder
    static var root: some View {
        #if DEBUG && ISSUE42_STANDALONE_QUALIFICATION
        Issue42BrowserNoticeRoot()
        #else
        Color.clear
        #endif
    }
}

#if DEBUG && ISSUE42_STANDALONE_QUALIFICATION
@MainActor
private struct Issue42BrowserNoticeRoot: View {
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
                    .accessibilityIdentifier("issue42ShowRetainedLimitNotice")

                    Button("Replace download notice") {
                        var snapshot = BrowserDownloadSnapshot()
                        snapshot.revision = 3
                        snapshot.notice = .transferFailed
                        store.send(.downloadsChanged(snapshot))
                    }
                    .accessibilityIdentifier("issue42ReplaceDownloadNotice")
                }
                .padding()
            }
    }
}
#endif
