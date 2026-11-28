//
//  MediaLibraryView.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import ComposableArchitecture
import CoreFoundation
import Entitlement
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Presents committed Library assets and controls for importing supported still images.
@MainActor
public struct MediaLibraryView: View {
    private let store: StoreOf<MediaLibraryFeature>
    private let loadsOnAppear: Bool

    /// Creates a Library surface backed by media-library state.
    public init(store: StoreOf<MediaLibraryFeature>) {
        self.init(store: store, loadsOnAppear: true)
    }

    init(store: StoreOf<MediaLibraryFeature>, loadsOnAppear: Bool) {
        self.store = store
        self.loadsOnAppear = loadsOnAppear
    }

    /// Renders committed stills, an empty state, import progress, and import errors.
    public var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if store.isLoading {
                    ProgressView("Loading Library")
                } else if store.assets.isEmpty {
                    emptyState
                } else {
                    ForEach(store.assets) { asset in
                        assetRow(asset)
                    }
                }

                if store.isImporting {
                    ProgressView("Importing")
                        .frame(maxWidth: .infinity)
                }

                if let error = store.error {
                    errorPanel(error)
                }
            }
            .frame(maxWidth: 640)
            .padding(16)
            .frame(maxWidth: .infinity)
        }
        .overlay(alignment: .topTrailing) {
            importButton
                .padding()
        }
        .fileImporter(
            isPresented: pickerBinding,
            allowedContentTypes: [.image],
            allowsMultipleSelection: false,
        ) { result in
            switch result {
            case let .success(urls):
                guard let url = urls.first else {
                    store.send(.pickerCancelled)
                    return
                }

                store.send(.fileSelected(url))
            case .failure:
                store.send(.pickerCancelled)
            }
        }
        .confirmationDialog(
            "Duplicate image",
            isPresented: duplicateDecisionBinding,
            titleVisibility: .visible,
        ) {
            if let decision = store.pendingDuplicateDecisions.first,
               let generation = store.duplicateDecisionGeneration {
                Button("Skip") {
                    store.send(.duplicateDecisionTapped(
                        id: decision.id,
                        generation: generation,
                        choice: .skip,
                    ))
                }
                Button("Import Anyway") {
                    store.send(.duplicateDecisionTapped(
                        id: decision.id,
                        generation: generation,
                        choice: .importAnyway,
                    ))
                }
            }
            Button("Not Now", role: .cancel) {}
        } message: {
            if let decision = store.pendingDuplicateDecisions.first {
                Text("\(decision.sourceFilename) matches an image already saved in your Library.")
            }
        }
        .task {
            if loadsOnAppear {
                await store.send(.task).finish()
            }
        }
    }

    private var pickerBinding: Binding<Bool> {
        Binding(
            get: { store.isPickerPresented },
            set: { isPresented in
                if !isPresented {
                    store.send(.pickerCancelled)
                }
            },
        )
    }

    private var duplicateDecisionBinding: Binding<Bool> {
        let decisionID = store.pendingDuplicateDecisions.first?.id
        let generation = store.duplicateDecisionGeneration
        return Binding(
            get: { store.isDuplicatePromptPresented },
            set: { isPresented in
                if !isPresented, let decisionID, let generation {
                    store.send(.duplicatePromptDismissed(id: decisionID, generation: generation))
                }
            },
        )
    }

    private var canStartImport: Bool {
        !store.isLoading
            && !store.isImporting
            && !store.entitlementStatus.blocksImportSelection
    }

    private var importButton: some View {
        Button("Import", systemImage: "plus") {
            store.send(.importTapped)
        }
        .buttonStyle(.borderedProminent)
        .disabled(!canStartImport)
        .accessibilityHint("Choose one still image from Files")
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Library", systemImage: "photo.on.rectangle.angled")
        } description: {
            Text("Import a still image from Files to add it to the authenticated Library.")
        } actions: {
            Button("Import from Files", systemImage: "folder") {
                store.send(.importTapped)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canStartImport)
        }
    }

    private func assetRow(_ asset: MediaAsset) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let resource = asset.resources.first,
               let data = store.resourceData[resource.id],
               let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: 360)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .accessibilityLabel(resource.sourceFilename)
            } else {
                ContentUnavailableView("Preview unavailable", systemImage: "photo")
                    .frame(maxWidth: .infinity, minHeight: 180)
            }

            if let resource = asset.resources.first {
                Text(resource.sourceFilename)
                    .font(.subheadline)
                    .lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 16))
    }

    private func errorPanel(_ error: MediaLibraryFeatureError) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title(for: error))
                .font(.headline)
                .foregroundStyle(.red)
            Text(Self.message(for: error))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if error == .assetLimitReached {
                entitlementControls
            } else if error == .resourceUnavailable
                || error == .entitlementUnavailable
                || error == .libraryUnavailable {
                Button("Retry") {
                    store.send(.retryTapped)
                }
                .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
    }

    @ViewBuilder
    private var entitlementControls: some View {
        switch store.entitlementStatus {
        case .available:
            entitlementActionButtons
        case .purchasing:
            ProgressView("Purchasing Pro")
        case .restoring:
            ProgressView("Restoring Purchases")
        case .refreshing:
            ProgressView("Verifying Pro")
        case .pending:
            Text("The purchase is pending. Wait for the App Store to finish, then check the purchase status.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button("Check Purchase Status") {
                store.send(.purchaseStatusCheckTapped)
            }
            .buttonStyle(.borderedProminent)
            Button("Restore Purchases") {
                store.send(.restoreTapped)
            }
            .buttonStyle(.bordered)
        case .cancelled:
            Text("The purchase or restore was cancelled. Pro status did not change.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            entitlementActionButtons
        case .activated:
            Text("Pro is active. The staged copy was not retried automatically.")
                .font(.subheadline)
        case .notVerified:
            Text(
                "Pro is not active or could not be verified for this Apple Account. " +
                    "Restore purchases to change the admission result.",
            )
            .font(.subheadline)
            entitlementActionButtons
        case let .failed(error):
            Text(Self.entitlementFailureMessage(for: error))
                .font(.subheadline)
                .foregroundStyle(.red)
            entitlementActionButtons
        }
    }

    private var entitlementActionButtons: some View {
        HStack {
            Button("Purchase Pro") {
                store.send(.purchaseTapped)
            }
            .buttonStyle(.borderedProminent)

            Button("Restore Purchases") {
                store.send(.restoreTapped)
            }
            .buttonStyle(.bordered)
        }
    }

    private func title(for error: MediaLibraryFeatureError) -> String {
        switch error {
        case .assetLimitReached:
            "Free limit reached"
        case .entitlementUnavailable:
            "Could not verify Pro"
        case .libraryUnavailable:
            "Could not check Library"
        case .unsupportedMedia:
            "Image not supported"
        case .importFailed:
            "Import failed"
        case .resourceUnavailable:
            "Library unavailable"
        }
    }

    static func message(for error: MediaLibraryFeatureError) -> String {
        switch error {
        case .assetLimitReached:
            "Free includes \(MediaLibraryQuota.freeLogicalAssetLimit) Library items. " +
                "This accepted copy remains staged and was not added. Purchase or restore Pro to use Library imports."
        case .entitlementUnavailable:
            "Pro could not be verified. Retry Library recovery to continue any accepted imports."
        case .libraryUnavailable:
            "Library could not check the saved asset count. Retry Library recovery when the store is available."
        case .unsupportedMedia:
            "Choose one ordinary, renderable still image. Videos, animated images, RAW, and compound media are not supported here."
        case .importFailed:
            "No Library item was added. If the source bytes were accepted, they remain staged for recovery."
        case .resourceUnavailable:
            "The saved image could not be read from protected storage."
        }
    }

    static func entitlementFailureMessage(for error: EntitlementError) -> String {
        switch error {
        case .productUnavailable,
             .incompatibleProduct:
            "The Pro purchase is not available right now. Restore purchases or try again later."
        case .noEntitlementFound:
            "No active Pro purchase was found for this Apple Account."
        case .verificationFailed:
            "StoreKit could not verify the purchase, so Pro was not granted."
        case .storeFailure:
            "The App Store could not complete the request. Try again."
        }
    }
}
