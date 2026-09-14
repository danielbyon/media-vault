//
//  MediaLibraryFeature.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import ComposableArchitecture
import Dependencies
import Foundation

/// The user-visible import and loading errors for the minimal Library surface.
public enum MediaLibraryFeatureError: Equatable, Sendable {
    /// The selected source is not a supported ordinary still image.
    case unsupportedMedia

    /// The selected source could not be rendered or copied.
    case importFailed

    /// The canonical resource could not be read for presentation.
    case resourceUnavailable
}

/// The TCA feature that owns committed Library state and the Files import flow.
@Reducer
public struct MediaLibraryFeature {
    /// State rendered by the authenticated Library destination.
    @ObservableState
    public struct State: Equatable, Sendable {
        /// Assets whose metadata has been committed to the canonical store.
        public var assets: [MediaAsset]

        /// Resource bytes already loaded for presentation, keyed by opaque resource ID.
        public var resourceData: [UUID: Data]

        /// Whether the initial durable Library load is running.
        public var isLoading: Bool

        /// Whether the native document importer should be presented.
        public var isPickerPresented: Bool

        /// Whether a selected source is being imported.
        public var isImporting: Bool

        /// The latest user-visible media error.
        public var error: MediaLibraryFeatureError?

        fileprivate var hasLoaded: Bool

        /// Creates an empty or preloaded Library state.
        public init(assets: [MediaAsset] = []) {
            self.assets = assets
            resourceData = [:]
            isLoading = false
            isPickerPresented = false
            isImporting = false
            error = nil
            hasLoaded = !assets.isEmpty
        }

        /// Compares the rendered Library state while ignoring the private load cache.
        public static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.assets == rhs.assets
                && lhs.resourceData == rhs.resourceData
                && lhs.isLoading == rhs.isLoading
                && lhs.isPickerPresented == rhs.isPickerPresented
                && lhs.isImporting == rhs.isImporting
                && lhs.error == rhs.error
        }
    }

    /// User and lifecycle actions handled by the Library feature.
    public enum Action: Equatable, Sendable {
        /// Starts the durable Library load.
        case task

        /// Requests presentation of the Files picker.
        case importTapped

        /// Receives a URL selected by the native document importer.
        case fileSelected(URL)

        /// Reports that the native picker was cancelled.
        case pickerCancelled

        /// Delivers a durable Library load result.
        case assetsLoaded(Result<[MediaAsset], MediaLibraryStoreError>)

        /// Delivers an import result after canonical commit.
        case importCompleted(Result<MediaAsset, MediaImportError>)

        /// Delivers bytes for one committed resource.
        case resourceLoaded(UUID, Result<Data, MediaLibraryStoreError>)

        /// Clears the visible error and retries durable loading.
        case retryTapped
    }

    @Dependency(\.mediaLibrary)
    private var mediaLibrary

    /// Creates the Library reducer.
    public init() {}

    /// Handles loading, importing, and committed-resource presentation.
    public var body: some ReducerOf<Self> {
        Reduce { state, action in
            reduceLibrary(into: &state, action: action)
        }
    }

    private func reduceLibrary(into state: inout State, action: Action) -> Effect<Action> {
        switch action {
        case .task:
            handleTask(state: &state)
        case .importTapped:
            handleImportTapped(state: &state)
        case let .fileSelected(url):
            handleFileSelected(url: url, state: &state)
        case .pickerCancelled:
            handlePickerCancelled(state: &state)
        case let .assetsLoaded(result):
            handleAssetsLoaded(result, state: &state)
        case let .importCompleted(result):
            handleImportCompleted(result, state: &state)
        case let .resourceLoaded(resourceID, result):
            handleResourceLoaded(resourceID: resourceID, result: result, state: &state)
        case .retryTapped:
            handleRetry(state: &state)
        }
    }

    private func handleTask(state: inout State) -> Effect<Action> {
        guard !state.hasLoaded, !state.isLoading else {
            return .none
        }

        state.isLoading = true
        let loadAssets = mediaLibrary.loadAssets
        return .run { send in
            do {
                try await send(.assetsLoaded(.success(loadAssets())))
            } catch let error as MediaLibraryStoreError {
                await send(.assetsLoaded(.failure(error)))
            } catch {
                await send(.assetsLoaded(.failure(.unavailable)))
            }
        }
    }

    private func handleImportTapped(state: inout State) -> Effect<Action> {
        guard !state.isImporting else {
            return .none
        }

        state.error = nil
        state.isPickerPresented = true
        return .none
    }

    private func handleFileSelected(url: URL, state: inout State) -> Effect<Action> {
        state.isPickerPresented = false
        state.isImporting = true
        state.error = nil
        let importFile = mediaLibrary.importFile
        return .run { send in
            do {
                try await send(.importCompleted(.success(importFile(url))))
            } catch let error as MediaImportError {
                await send(.importCompleted(.failure(error)))
            } catch {
                await send(.importCompleted(.failure(.persistenceFailed)))
            }
        }
    }

    private func handlePickerCancelled(state: inout State) -> Effect<Action> {
        state.isPickerPresented = false
        return .none
    }

    private func handleAssetsLoaded(
        _ result: Result<[MediaAsset], MediaLibraryStoreError>,
        state: inout State,
    ) -> Effect<Action> {
        switch result {
        case let .success(assets):
            state.isLoading = false
            state.hasLoaded = true
            state.error = nil
            state.assets = assets
            return loadResourceEffects(for: assets)
        case .failure:
            state.isLoading = false
            state.error = .resourceUnavailable
            return .none
        }
    }

    private func handleImportCompleted(
        _ result: Result<MediaAsset, MediaImportError>,
        state: inout State,
    ) -> Effect<Action> {
        switch result {
        case let .success(asset):
            state.isImporting = false
            state.hasLoaded = true
            state.error = nil
            state.assets.append(asset)
            return loadResourceEffects(for: [asset])
        case let .failure(error):
            state.isImporting = false
            state.error = featureError(for: error)
            return .none
        }
    }

    private func handleResourceLoaded(
        resourceID: UUID,
        result: Result<Data, MediaLibraryStoreError>,
        state: inout State,
    ) -> Effect<Action> {
        switch result {
        case let .success(data):
            state.resourceData[resourceID] = data
        case .failure:
            state.error = .resourceUnavailable
        }
        return .none
    }

    private func handleRetry(state: inout State) -> Effect<Action> {
        state.error = nil
        state.hasLoaded = false
        return .send(.task)
    }

    private func loadResourceEffects(for assets: [MediaAsset]) -> Effect<Action> {
        let resourceData = mediaLibrary.resourceData
        let resources = assets.flatMap(\.resources)
        return .merge(
            resources.map { resource in
                .run { send in
                    do {
                        try await send(.resourceLoaded(resource.id, .success(resourceData(resource))))
                    } catch let error as MediaLibraryStoreError {
                        await send(.resourceLoaded(resource.id, .failure(error)))
                    } catch {
                        await send(.resourceLoaded(resource.id, .failure(.unavailable)))
                    }
                }
            },
        )
    }

    private func featureError(for error: MediaImportError) -> MediaLibraryFeatureError {
        switch error {
        case .unsupportedMedia,
             .unrenderableMedia:
            .unsupportedMedia
        case .sourceAccessFailed,
             .finalizationFailed,
             .persistenceFailed:
            .importFailed
        }
    }
}
