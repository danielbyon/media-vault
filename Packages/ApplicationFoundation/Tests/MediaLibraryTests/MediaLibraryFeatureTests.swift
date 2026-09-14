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
        await store.receive(.resourceLoaded(
            FeatureFixtures.resourceID,
            .success(FeatureFixtures.imageData),
        )) {
            $0.resourceData[FeatureFixtures.resourceID] = FeatureFixtures.imageData
        }
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
        await store.receive(.assetsLoaded(.success([asset]))) {
            $0.isLoading = false
            $0.assets = [asset]
        }
        await store.receive(.resourceLoaded(
            FeatureFixtures.resourceID,
            .success(FeatureFixtures.imageData),
        )) {
            $0.resourceData[FeatureFixtures.resourceID] = FeatureFixtures.imageData
        }
        await store.send(.task)
        #expect(await loadCalls.value == 1)
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
