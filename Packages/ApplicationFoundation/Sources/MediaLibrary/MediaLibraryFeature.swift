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
    private enum CancelID {
        case resourceLoads
    }

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

        /// Whether user-initiated Library operations are blocked by a vault lock.
        public var isSessionLocked: Bool

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
            isSessionLocked = false
            error = nil
            hasLoaded = !assets.isEmpty
        }

        /// Clears cached preview bytes and marks durable resources for reload after authentication.
        public mutating func commitSessionLock() -> Effect<Action> {
            isSessionLocked = true
            isLoading = false
            isPickerPresented = false
            resourceData.removeAll()
            hasLoaded = false
            return .cancel(id: MediaLibraryFeature.CancelID.resourceLoads)
        }

        /// Compares the rendered Library state while ignoring the private load cache.
        public static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.assets == rhs.assets
                && lhs.resourceData == rhs.resourceData
                && lhs.isLoading == rhs.isLoading
                && lhs.isPickerPresented == rhs.isPickerPresented
                && lhs.isImporting == rhs.isImporting
                && lhs.isSessionLocked == rhs.isSessionLocked
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

        /// Delivers a durable asset result correlated with the authenticated load generation.
        case assetsLoadCompleted(
            generation: UInt64,
            result: Result<[MediaAsset], MediaLibraryStoreError>,
        )

        /// Delivers an import result after canonical commit.
        case importCompleted(Result<MediaAsset, MediaImportError>)

        /// Delivers a resource result correlated with the authenticated read generation.
        case resourceLoadCompleted(
            resourceID: UUID,
            generation: UInt64,
            result: Result<Data, MediaLibraryStoreError>,
        )

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
        if state.isSessionLocked {
            switch action {
            case let .assetsLoadCompleted(_, .success(assets)):
                _ = handleAssetsLoaded(.success(assets), state: &state)
                state.resourceData.removeAll()
                state.hasLoaded = false
                return .none
            case let .importCompleted(result):
                _ = handleImportCompleted(result, state: &state)
                state.resourceData.removeAll()
                state.hasLoaded = false
                return .none
            default:
                return .none
            }
        }

        switch action {
        case .task:
            return handleTask(state: &state)
        case .importTapped:
            return handleImportTapped(state: &state)
        case let .fileSelected(url):
            return handleFileSelected(url: url, state: &state)
        case .pickerCancelled:
            return handlePickerCancelled(state: &state)
        case let .assetsLoadCompleted(generation, result):
            guard mediaLibrary.currentResourceLoadGeneration == generation else {
                return .none
            }

            return handleAssetsLoaded(result, state: &state)
        case let .importCompleted(result):
            return handleImportCompleted(result, state: &state)
        case let .resourceLoadCompleted(resourceID, generation, result):
            guard mediaLibrary.currentResourceLoadGeneration == generation else {
                return .none
            }

            return handleResourceLoaded(resourceID: resourceID, result: result, state: &state)
        case .retryTapped:
            return handleRetry(state: &state)
        }
    }

    private func handleTask(state: inout State) -> Effect<Action> {
        guard !state.hasLoaded, !state.isLoading else {
            return .none
        }

        state.isLoading = true
        let loadGeneration = mediaLibrary.currentResourceLoadGeneration
        let loadAssets = mediaLibrary.loadAssets
        return .run { send in
            do {
                let assets = try await loadAssets()
                await send(.assetsLoadCompleted(generation: loadGeneration, result: .success(assets)))
            } catch let error as MediaLibraryStoreError {
                await send(.assetsLoadCompleted(generation: loadGeneration, result: .failure(error)))
            } catch {
                await send(.assetsLoadCompleted(generation: loadGeneration, result: .failure(.unavailable)))
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
            // Keep a pending full snapshot eligible when an import finishes after authentication.
            state.error = nil
            if let existingIndex = state.assets.firstIndex(where: { $0.id == asset.id }) {
                state.assets[existingIndex] = asset
            } else {
                state.assets.append(asset)
            }
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
        let resourceReadGeneration = mediaLibrary.currentResourceLoadGeneration
        let mediaLibraryClient = mediaLibrary
        let resources = assets.flatMap(\.resources)
        return .merge(
            resources.map { resource in
                .run { send in
                    guard !Task.isCancelled else {
                        return
                    }

                    do {
                        guard let data = try await mediaLibraryClient.resourceDataIfCurrent(
                            resource,
                            generation: resourceReadGeneration,
                        ) else {
                            return
                        }
                        guard !Task.isCancelled else {
                            return
                        }

                        await send(.resourceLoadCompleted(
                            resourceID: resource.id,
                            generation: resourceReadGeneration,
                            result: .success(data),
                        ))
                    } catch let error as MediaLibraryStoreError {
                        guard !Task.isCancelled else {
                            return
                        }

                        await send(.resourceLoadCompleted(
                            resourceID: resource.id,
                            generation: resourceReadGeneration,
                            result: .failure(error),
                        ))
                    } catch {
                        guard !Task.isCancelled else {
                            return
                        }

                        await send(.resourceLoadCompleted(
                            resourceID: resource.id,
                            generation: resourceReadGeneration,
                            result: .failure(.unavailable),
                        ))
                    }
                }
            },
        )
        .cancellable(id: CancelID.resourceLoads)
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
