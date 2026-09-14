//
//  MediaLibraryView.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import ComposableArchitecture
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The minimal authenticated Library presentation for the first still-image tracer.
@MainActor
@preconcurrency
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

    private var importButton: some View {
        Button("Import", systemImage: "plus") {
            store.send(.importTapped)
        }
        .buttonStyle(.borderedProminent)
        .disabled(store.isLoading || store.isImporting)
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
            Text(message(for: error))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if error == .resourceUnavailable {
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

    private func title(for error: MediaLibraryFeatureError) -> String {
        switch error {
        case .unsupportedMedia:
            "Image not supported"
        case .importFailed:
            "Import failed"
        case .resourceUnavailable:
            "Library unavailable"
        }
    }

    private func message(for error: MediaLibraryFeatureError) -> String {
        switch error {
        case .unsupportedMedia:
            "Choose one ordinary, renderable still image. Videos, animated images, RAW, and compound media are not supported here."
        case .importFailed:
            "The image was not added to Library. Check that Files can provide the source and try again."
        case .resourceUnavailable:
            "The saved image could not be read from protected storage."
        }
    }
}
