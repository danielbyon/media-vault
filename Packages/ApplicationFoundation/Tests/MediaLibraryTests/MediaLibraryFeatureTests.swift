//
//  MediaLibraryFeatureTests.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import ComposableArchitecture
import Foundation
import MediaLibrary
import Testing

@Suite("Media library feature")
struct MediaLibraryFeatureTests {
    @Test("Import selection appends only after commit and then loads exact resource bytes")
    @MainActor
    func importsAfterCommitAndLoadsResource() async {
        let sourceURL = URL(fileURLWithPath: "/provider/holiday-photo.png")
        let asset = FeatureFixtures.asset
        let store = TestStore(initialState: MediaLibraryFeature.State()) {
            MediaLibraryFeature()
        } withDependencies: {
            $0.mediaLibrary = MediaLibraryClient(
                loadAssets: { [] },
                importFile: { _ in asset },
                resourceData: { _ in FeatureFixtures.imageData },
            )
        }

        await store.send(.importTapped) {
            $0.isPickerPresented = true
        }
        await store.send(.fileSelected(sourceURL)) {
            $0.isPickerPresented = false
            $0.isImporting = true
        }
        await store.receive(.importCompleted(.success(asset))) {
            $0.isImporting = false
            $0.assets = [asset]
        }
        await store.receive(.resourceLoadCompleted(
            resourceID: FeatureFixtures.resourceID,
            generation: 0,
            result: .success(FeatureFixtures.imageData),
        )) {
            $0.resourceData[FeatureFixtures.resourceID] = FeatureFixtures.imageData
        }
    }

    @Test("Import completion does not duplicate an asset already present in a fresh snapshot")
    @MainActor
    func importCompletionReconcilesWithFreshAssetSnapshot() async {
        let asset = FeatureFixtures.importedAsset
        let (importStream, importContinuation) = AsyncStream.makeStream(of: MediaAsset.self)
        let store = TestStore(initialState: MediaLibraryFeature.State()) {
            MediaLibraryFeature()
        } withDependencies: {
            $0.mediaLibrary = MediaLibraryClient(
                loadAssets: { [asset] },
                importFile: { _ in
                    for await committedAsset in importStream {
                        return committedAsset
                    }
                    throw MediaImportError.persistenceFailed
                },
                resourceData: { _ in FeatureFixtures.imageData },
            )
        }

        await store.send(.fileSelected(URL(fileURLWithPath: "/provider/imported.jpg"))) {
            $0.isImporting = true
        }
        await store.send(.task) {
            $0.isLoading = true
        }
        await store.receive(.assetsLoadCompleted(generation: 0, result: .success([asset]))) {
            $0.isLoading = false
            $0.assets = [asset]
        }
        await store.receive(.resourceLoadCompleted(
            resourceID: FeatureFixtures.importedResourceID,
            generation: 0,
            result: .success(FeatureFixtures.imageData),
        )) {
            $0.resourceData[FeatureFixtures.importedResourceID] = FeatureFixtures.imageData
        }

        importContinuation.yield(asset)
        importContinuation.finish()
        await store.receive(.importCompleted(.success(asset))) {
            $0.isImporting = false
        }
        await store.receive(.resourceLoadCompleted(
            resourceID: FeatureFixtures.importedResourceID,
            generation: 0,
            result: .success(FeatureFixtures.imageData),
        ))

        #expect(store.state.assets == [asset])
        #expect(!store.state.isImporting)
        #expect(store.state.resourceData[FeatureFixtures.importedResourceID] == FeatureFixtures.imageData)
    }

    @Test("Unsupported selection reports an error without adding an asset")
    @MainActor
    func unsupportedSelectionDoesNotAddAsset() async {
        let store = TestStore(initialState: MediaLibraryFeature.State()) {
            MediaLibraryFeature()
        } withDependencies: {
            $0.mediaLibrary.importFile = { _ in
                throw MediaImportError.unsupportedMedia
            }
        }

        await store.send(.fileSelected(URL(fileURLWithPath: "/provider/animated.gif"))) {
            $0.isImporting = true
        }
        await store.receive(.importCompleted(.failure(.unsupportedMedia))) {
            $0.isImporting = false
            $0.error = .unsupportedMedia
        }
        #expect(store.state.assets.isEmpty)
    }

    @Test("Task reloads committed assets and their resources once")
    @MainActor
    func taskReloadsCommittedAssets() async {
        let loadCalls = CallCounter()
        let asset = FeatureFixtures.asset
        let store = TestStore(initialState: MediaLibraryFeature.State()) {
            MediaLibraryFeature()
        } withDependencies: {
            $0.mediaLibrary.loadAssets = {
                await loadCalls.increment()
                return [asset]
            }
            $0.mediaLibrary.resourceData = { _ in FeatureFixtures.imageData }
        }

        await store.send(.task) {
            $0.isLoading = true
        }
        await store.receive(.assetsLoadCompleted(generation: 0, result: .success([asset]))) {
            $0.isLoading = false
            $0.assets = [asset]
        }
        await store.receive(.resourceLoadCompleted(
            resourceID: FeatureFixtures.resourceID,
            generation: 0,
            result: .success(FeatureFixtures.imageData),
        )) {
            $0.resourceData[FeatureFixtures.resourceID] = FeatureFixtures.imageData
        }
        await store.send(.task)
        #expect(await loadCalls.value == 1)
    }

    @Test("Assets loaded while locked reload their resources after unlock")
    @MainActor
    func lockedAssetCompletionReloadsResourcesAfterUnlock() async throws {
        let mediaLibrary = MediaLibraryClient(
            loadAssets: { [] },
            importFile: { _ in throw MediaImportError.persistenceFailed },
            resourceData: { _ in FeatureFixtures.imageData },
        )
        let staleGeneration = mediaLibrary.currentResourceLoadGeneration
        mediaLibrary.advanceResourceLoadGeneration()
        var lockedState = MediaLibraryFeature.State()
        lockedState.isSessionLocked = true
        let lockedStore = TestStore(initialState: lockedState) {
            MediaLibraryFeature()
        } withDependencies: {
            $0.mediaLibrary = mediaLibrary
        }
        lockedStore.exhaustivity = .off

        await lockedStore.send(.assetsLoadCompleted(
            generation: staleGeneration,
            result: .success([FeatureFixtures.asset]),
        ))
        await lockedStore.send(.resourceLoadCompleted(
            resourceID: FeatureFixtures.resourceID,
            generation: staleGeneration,
            result: .success(FeatureFixtures.imageData),
        ))
        #expect(lockedStore.state.assets == [FeatureFixtures.asset])
        #expect(lockedStore.state.resourceData.isEmpty)

        var unlockedState = lockedStore.state
        unlockedState.isSessionLocked = false
        let loadCalls = CallCounter()
        let resourceCalls = CallCounter()
        var resumedMediaLibrary = mediaLibrary
        resumedMediaLibrary.loadAssets = {
            await loadCalls.increment()
            return [FeatureFixtures.asset]
        }
        resumedMediaLibrary.resourceData = { _ in
            await resourceCalls.increment()
            return FeatureFixtures.imageData
        }
        let resumedStore = TestStore(initialState: unlockedState) {
            MediaLibraryFeature()
        } withDependencies: {
            $0.mediaLibrary = resumedMediaLibrary
        }
        resumedStore.exhaustivity = .off

        await resumedStore.send(.resourceLoadCompleted(
            resourceID: FeatureFixtures.resourceID,
            generation: staleGeneration,
            result: .success(FeatureFixtures.imageData),
        ))
        await resumedStore.send(.resourceLoadCompleted(
            resourceID: FeatureFixtures.resourceID,
            generation: staleGeneration,
            result: .failure(.unavailable),
        ))
        #expect(resumedStore.state.resourceData.isEmpty)
        #expect(resumedStore.state.error == nil)

        await resumedStore.send(.task)
        #expect(resumedStore.state.isLoading)
        try #require(resumedStore.state.isLoading)

        await resumedStore.receive(.assetsLoadCompleted(
            generation: mediaLibrary.currentResourceLoadGeneration,
            result: .success([FeatureFixtures.asset]),
        )) {
            $0.isLoading = false
            $0.assets = [FeatureFixtures.asset]
        }
        await resumedStore.receive(.resourceLoadCompleted(
            resourceID: FeatureFixtures.resourceID,
            generation: mediaLibrary.currentResourceLoadGeneration,
            result: .success(FeatureFixtures.imageData),
        )) {
            $0.resourceData[FeatureFixtures.resourceID] = FeatureFixtures.imageData
        }
        await resumedStore.finish()

        #expect(await loadCalls.value == 1)
        #expect(await resourceCalls.value == 1)
        #expect(resumedStore.state.resourceData[FeatureFixtures.resourceID] == FeatureFixtures.imageData)
    }

    @Test("An import completed while locked remains committed and reloads its resource after unlock")
    @MainActor
    func lockedImportCompletionPreservesAssetAndReloadsResourceAfterUnlock() async throws {
        let mediaLibrary = MediaLibraryClient(
            loadAssets: { [] },
            importFile: { _ in throw MediaImportError.persistenceFailed },
            resourceData: { _ in FeatureFixtures.imageData },
        )
        let staleGeneration = mediaLibrary.currentResourceLoadGeneration
        mediaLibrary.advanceResourceLoadGeneration()
        var lockedState = MediaLibraryFeature.State()
        lockedState.isSessionLocked = true
        lockedState.isImporting = true
        let lockedStore = TestStore(initialState: lockedState) {
            MediaLibraryFeature()
        } withDependencies: {
            $0.mediaLibrary = mediaLibrary
        }
        lockedStore.exhaustivity = .off

        await lockedStore.send(.importCompleted(.success(FeatureFixtures.importedAsset)))
        await lockedStore.send(.resourceLoadCompleted(
            resourceID: FeatureFixtures.importedResourceID,
            generation: staleGeneration,
            result: .success(FeatureFixtures.imageData),
        ))
        #expect(!lockedStore.state.isImporting)
        #expect(lockedStore.state.assets == [FeatureFixtures.importedAsset])
        #expect(lockedStore.state.resourceData.isEmpty)

        var unlockedState = lockedStore.state
        unlockedState.isSessionLocked = false
        let loadCalls = CallCounter()
        let resourceCalls = CallCounter()
        var resumedMediaLibrary = mediaLibrary
        resumedMediaLibrary.loadAssets = {
            await loadCalls.increment()
            return [FeatureFixtures.importedAsset]
        }
        resumedMediaLibrary.resourceData = { _ in
            await resourceCalls.increment()
            return FeatureFixtures.imageData
        }
        let resumedStore = TestStore(initialState: unlockedState) {
            MediaLibraryFeature()
        } withDependencies: {
            $0.mediaLibrary = resumedMediaLibrary
        }
        resumedStore.exhaustivity = .off

        await resumedStore.send(.task)
        #expect(resumedStore.state.isLoading)
        try #require(resumedStore.state.isLoading)

        await resumedStore.receive(.assetsLoadCompleted(
            generation: mediaLibrary.currentResourceLoadGeneration,
            result: .success([FeatureFixtures.importedAsset]),
        )) {
            $0.isLoading = false
            $0.assets = [FeatureFixtures.importedAsset]
        }
        await resumedStore.receive(.resourceLoadCompleted(
            resourceID: FeatureFixtures.importedResourceID,
            generation: mediaLibrary.currentResourceLoadGeneration,
            result: .success(FeatureFixtures.imageData),
        )) {
            $0.resourceData[FeatureFixtures.importedResourceID] = FeatureFixtures.imageData
        }
        await resumedStore.finish()

        #expect(await loadCalls.value == 1)
        #expect(await resourceCalls.value == 1)
        #expect(resumedStore.state.assets == [FeatureFixtures.importedAsset])
        #expect(resumedStore.state.resourceData[FeatureFixtures.importedResourceID] == FeatureFixtures.imageData)
    }

    @Test("Import completion before the resumed task preserves the full Library reload")
    @MainActor
    func importCompletionBeforeResumedTaskPreservesFullReload() async {
        let existingAsset = FeatureFixtures.asset
        let importedAsset = FeatureFixtures.importedAsset
        let loadCalls = CallCounter()
        let (existingResourceRelease, existingResourceReleaseContinuation) =
            AsyncStream.makeStream(of: Void.self)
        let mediaLibrary = MediaLibraryClient(
            loadAssets: {
                await loadCalls.increment()
                return [existingAsset, importedAsset]
            },
            importFile: { _ in throw MediaImportError.persistenceFailed },
            resourceData: { resource in
                if resource.id == FeatureFixtures.resourceID {
                    for await _ in existingResourceRelease {
                        break
                    }
                }
                return FeatureFixtures.imageData
            },
        )
        mediaLibrary.advanceResourceLoadGeneration()

        var lockedState = MediaLibraryFeature.State(assets: [existingAsset])
        lockedState.resourceData[FeatureFixtures.resourceID] = FeatureFixtures.imageData
        lockedState.isImporting = true
        _ = lockedState.commitSessionLock()
        #expect(lockedState.isSessionLocked)
        #expect(lockedState.resourceData.isEmpty)

        var unlockedState = lockedState
        unlockedState.isSessionLocked = false
        let store = TestStore(initialState: unlockedState) {
            MediaLibraryFeature()
        } withDependencies: {
            $0.mediaLibrary = mediaLibrary
        }

        await store.send(.importCompleted(.success(importedAsset))) {
            $0.isImporting = false
            $0.assets = [existingAsset, importedAsset]
        }
        await store.receive(.resourceLoadCompleted(
            resourceID: FeatureFixtures.importedResourceID,
            generation: mediaLibrary.currentResourceLoadGeneration,
            result: .success(FeatureFixtures.imageData),
        )) {
            $0.resourceData[FeatureFixtures.importedResourceID] = FeatureFixtures.imageData
        }

        await store.send(.task) {
            $0.isLoading = true
        }
        await store.receive(.assetsLoadCompleted(
            generation: mediaLibrary.currentResourceLoadGeneration,
            result: .success([existingAsset, importedAsset]),
        )) {
            $0.isLoading = false
            $0.assets = [existingAsset, importedAsset]
        }
        await store.receive(.resourceLoadCompleted(
            resourceID: FeatureFixtures.importedResourceID,
            generation: mediaLibrary.currentResourceLoadGeneration,
            result: .success(FeatureFixtures.imageData),
        ))
        existingResourceReleaseContinuation.yield(())
        existingResourceReleaseContinuation.finish()
        await store.receive(.resourceLoadCompleted(
            resourceID: FeatureFixtures.resourceID,
            generation: mediaLibrary.currentResourceLoadGeneration,
            result: .success(FeatureFixtures.imageData),
        )) {
            $0.resourceData[FeatureFixtures.resourceID] = FeatureFixtures.imageData
        }
        await store.finish()

        #expect(await loadCalls.value == 1)
        #expect(store.state.assets == [existingAsset, importedAsset])
        #expect(store.state.resourceData[FeatureFixtures.resourceID] == FeatureFixtures.imageData)
        #expect(store.state.resourceData[FeatureFixtures.importedResourceID] == FeatureFixtures.imageData)
    }

    @Test("Picker cancellation leaves the Library unchanged")
    @MainActor
    func pickerCancellationDoesNotChangeAssets() async {
        let store = TestStore(
            initialState: MediaLibraryFeature.State(assets: [FeatureFixtures.asset]),
        ) {
            MediaLibraryFeature()
        }

        await store.send(.importTapped) {
            $0.isPickerPresented = true
        }
        await store.send(.pickerCancelled) {
            $0.isPickerPresented = false
        }
        #expect(store.state.assets == [FeatureFixtures.asset])
    }
}

private enum FeatureFixtures {
    static let assetID = requiredUUID("00000000-0000-0000-0000-000000000020")
    static let resourceID = requiredUUID("00000000-0000-0000-0000-000000000021")
    static let imageData = requiredData(
        base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=",
    )
    static let resource = MediaResource(
        id: resourceID,
        role: .original,
        relativePath: resourceID.uuidString.lowercased(),
        sourceFilename: "holiday-photo.png",
        sourceUTI: "public.png",
        byteCount: Int64(imageData.count),
        sha256: "0000000000000000000000000000000000000000000000000000000000000000",
    )
    static let importedAssetID = requiredUUID("00000000-0000-0000-0000-000000000022")
    static let importedResourceID = requiredUUID("00000000-0000-0000-0000-000000000023")
    static let importedResource = MediaResource(
        id: importedResourceID,
        role: .original,
        relativePath: importedResourceID.uuidString.lowercased(),
        sourceFilename: "imported-photo.png",
        sourceUTI: "public.png",
        byteCount: Int64(imageData.count),
        sha256: "0000000000000000000000000000000000000000000000000000000000000000",
    )
    static let importedAsset = MediaAsset(
        id: importedAssetID,
        kind: .stillImage,
        importedAt: Date(timeIntervalSince1970: 1_725_000_001),
        resources: [importedResource],
    )
    static let asset = MediaAsset(
        id: assetID,
        kind: .stillImage,
        importedAt: Date(timeIntervalSince1970: 1_725_000_000),
        resources: [resource],
    )
}

private actor CallCounter {
    private(set) var value = 0

    func increment() {
        value += 1
    }
}

private func requiredUUID(_ string: String) -> UUID {
    guard let uuid = UUID(uuidString: string) else {
        preconditionFailure("Invalid deterministic UUID: \(string)")
    }

    return uuid
}

private func requiredData(base64Encoded string: String) -> Data {
    guard let data = Data(base64Encoded: string) else {
        preconditionFailure("Invalid deterministic base64 fixture")
    }

    return data
}
