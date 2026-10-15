//
//  BrowserDownloadsView.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import ComposableArchitecture
import Foundation
import SwiftUI

/// Transient session downloads, separate from the vault and browsing history. Partial files expose
/// progress and cancellation only; native preview and sharing resolve verified bytes outside state.
@MainActor
struct BrowserDownloadsView: View {
    let store: StoreOf<BrowserFeature>

    var body: some View {
        NavigationStack {
            List {
                if let notice = store.downloads.notice {
                    Text(notice.message)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("downloadNotice")
                }
                if store.downloads.cleanupNeedsRetry {
                    Button("Retry Download Cleanup", systemImage: "arrow.clockwise") { send(.retryCleanup) }
                }
                if store.downloads.records.isEmpty, !store.downloads.cleanupNeedsRetry {
                    ContentUnavailableView("No Downloads", systemImage: "arrow.down.circle")
                }
                ForEach(store.downloads.records) { record in
                    VStack(alignment: .leading, spacing: 12) {
                        Text(record.filename ?? "Downloading")
                            .font(.headline)
                        Text(ByteCountFormatter.string(fromByteCount: record.receivedBytes, countStyle: .file))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if record.isReady {
                            ViewThatFits(in: .horizontal) {
                                // Measure unwrapped actions so compact widths choose the vertical layout.
                                HStack { completedActions(record, unwrappedLabels: true) }
                                VStack(alignment: .leading, spacing: 12) { completedActions(record) }
                            }
                        } else {
                            if let total = record.expectedBytes {
                                ProgressView(value: Double(record.receivedBytes), total: Double(max(total, 1)))
                                    .accessibilityLabel("Download progress")
                            } else {
                                ProgressView().accessibilityLabel("Downloading")
                            }
                            Button("Cancel", role: .destructive) { send(.cancel(record.id)) }
                        }
                    }
                    .padding(.vertical, 8)
                }
            }
            .navigationTitle("Downloads")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { store.send(.downloadsPresented(false)) }
                }
            }
        }
        .presentationDetents([.large])
    }

    private func completedActions(_ record: BrowserDownloadRecord, unwrappedLabels: Bool = false) -> some View {
        Group {
            Button { send(.present(record.id, .preview)) } label: {
                Label("Preview", systemImage: "doc.text.magnifyingglass")
                    .labelStyle(.titleAndIcon)
                    .fixedSize(horizontal: unwrappedLabels, vertical: true)
            }
            .disabled(!store.downloads.isAvailable || store.downloads.presentation != nil)
            Button { send(.present(record.id, .share)) } label: {
                Label("Share", systemImage: "square.and.arrow.up")
                    .labelStyle(.titleAndIcon)
                    .fixedSize(horizontal: unwrappedLabels, vertical: true)
            }
            .disabled(!store.downloads.isAvailable || store.downloads.presentation != nil)
            Button(role: .destructive) { send(.discard(record.id)) } label: {
                Text("Discard").fixedSize(horizontal: unwrappedLabels, vertical: true)
            }
        }
        .buttonStyle(.bordered)
    }

    private func send(_ action: BrowserDownloadCommand.Action) {
        store.send(.downloadCommand(.init(snapshot: store.downloads, action: action)))
    }
}

extension BrowserDownloadSnapshot.Notice {
    /// Redacted explanations never contain request URLs, credentials, filenames, or scratch paths.
    var message: String {
        switch self {
        case .unauthorized:
            "Downloads are unavailable while this session is inactive."
        case .activeTransferLimitReached:
            "Download limit reached. Four downloads can transfer at once. Cancel an active download and try again."
        case .retainedRecordLimitReached:
            "Download limit reached. Eight downloads are kept in the list. Discard a download and try again."
        case .previewUnavailable:
            "Preview is unavailable for this file. You can share or discard it."
        case .transferFailed:
            "The download could not be completed safely."
        case .cleanupRequired:
            "Downloads are unavailable until temporary-file cleanup succeeds."
        case .invalidOrigin:
            "This download could not be accepted from the current browser session."
        }
    }
}
