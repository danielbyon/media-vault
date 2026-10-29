//
//  MediaLibraryFeatureTests.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import ComposableArchitecture
import Entitlement
import Foundation
import Testing
@testable import MediaLibrary

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

    @Test("Launch does not read or change entitlement")
    @MainActor
    func launchHasNoPaywallBehavior() async {
        let probe = EntitlementCallProbe()
        let store = TestStore(initialState: MediaLibraryFeature.State()) {
            MediaLibraryFeature()
        } withDependencies: {
            $0.entitlement.currentState = {
                await probe.recordStateRead()
                return .notEntitled
            }
            $0.entitlement.purchase = {
                await probe.recordPurchase()
                return .cancelled
            }
            $0.entitlement.restore = {
                await probe.recordRestore()
                return .cancelled
            }
        }

        await store.send(.task) {
            $0.isLoading = true
        }
        await store.receive(.assetsLoaded(.success([]))) {
            $0.isLoading = false
        }

        #expect(await probe.totalOperationCount() == 0)
    }

    @Test("Quota denial refreshes recovered commits and keeps the quota notice")
    @MainActor
    func quotaDenialRefreshesRecoveredCommittedAssets() async {
        let existingAsset = FeatureFixtures.asset
        let recoveredAsset = FeatureFixtures.recoveredAsset
        let store = TestStore(
            initialState: MediaLibraryFeature.State(assets: [existingAsset]),
        ) {
            MediaLibraryFeature()
        } withDependencies: {
            $0.mediaLibrary.loadAssets = { [existingAsset, recoveredAsset] }
            $0.mediaLibrary.importFile = { _ in throw MediaImportError.assetLimitReached }
            $0.mediaLibrary.resourceData = { _ in FeatureFixtures.imageData }
        }

        await store.send(.fileSelected(URL(fileURLWithPath: "/provider/new-photo.png"))) {
            $0.isImporting = true
        }
        await store.receive(.importCompleted(.failure(.assetLimitReached))) {
            $0.isImporting = false
            $0.error = .assetLimitReached
            $0.entitlementStatus = .available
        }
        await store.receive(
            .assetsRefreshedAfterQuotaDenial(.success([existingAsset, recoveredAsset])),
        ) {
            $0.assets.append(recoveredAsset)
        }
        await store.receive(.resourceLoaded(
            FeatureFixtures.recoveredResourceID,
            .success(FeatureFixtures.imageData),
        )) {
            $0.resourceData[FeatureFixtures.recoveredResourceID] = FeatureFixtures.imageData
        }

        #expect(store.state.assets == [existingAsset, recoveredAsset])
        #expect(store.state.error == .assetLimitReached)
    }

    @Test("Import taps preserve pending entitlement flow state", arguments: [
        MediaLibraryEntitlementStatus.purchasing,
        MediaLibraryEntitlementStatus.restoring,
        MediaLibraryEntitlementStatus.refreshing,
        MediaLibraryEntitlementStatus.pending,
    ])
    @MainActor
    func importTapDuringEntitlementOperationIsIgnored(_ status: MediaLibraryEntitlementStatus) async {
        var state = FeatureFixtures.quotaLimitedState
        state.entitlementStatus = status
        let store = TestStore(initialState: state) {
            MediaLibraryFeature()
        }

        await store.send(.importTapped)

        #expect(store.state.error == .assetLimitReached)
        #expect(store.state.entitlementStatus == status)
        #expect(!store.state.isPickerPresented)
    }

    @Test("Purchase action calls only the purchase entitlement operation")
    @MainActor
    func purchaseUsesPurchaseOperation() async {
        let probe = EntitlementCallProbe()
        let store = TestStore(initialState: FeatureFixtures.quotaLimitedState) {
            MediaLibraryFeature()
        } withDependencies: {
            $0.entitlement.purchase = {
                await probe.recordPurchase()
                return .cancelled
            }
        }

        await store.send(.purchaseTapped) {
            $0.entitlementStatus = .purchasing
        }
        await store.receive(.purchaseResult(.cancelled)) {
            $0.entitlementStatus = .cancelled
        }

        #expect(await probe.purchaseCount() == 1)
        #expect(await probe.restoreCount() == 0)
    }

    @Test("Restore action calls only the restore entitlement operation")
    @MainActor
    func restoreUsesRestoreOperation() async {
        let probe = EntitlementCallProbe()
        let store = TestStore(initialState: FeatureFixtures.quotaLimitedState) {
            MediaLibraryFeature()
        } withDependencies: {
            $0.entitlement.restore = {
                await probe.recordRestore()
                return .cancelled
            }
        }

        await store.send(.restoreTapped) {
            $0.entitlementStatus = .restoring
        }
        await store.receive(.restoreResult(.cancelled)) {
            $0.entitlementStatus = .cancelled
        }

        #expect(await probe.restoreCount() == 1)
        #expect(await probe.purchaseCount() == 0)
    }

    @Test("A purchase tap is ignored while purchase is already running")
    @MainActor
    func purchaseWhilePurchasingDoesNothing() async {
        let probe = EntitlementCallProbe()
        var state = FeatureFixtures.quotaLimitedState
        state.entitlementStatus = .purchasing
        let store = TestStore(initialState: state) {
            MediaLibraryFeature()
        } withDependencies: {
            $0.entitlement.purchase = {
                await probe.recordPurchase()
                return .cancelled
            }
        }

        await store.send(.purchaseTapped)

        #expect(store.state.entitlementStatus == .purchasing)
        #expect(await probe.totalOperationCount() == 0)
    }

    @Test("A restore tap is ignored while restore is already running")
    @MainActor
    func restoreWhileRestoringDoesNothing() async {
        let probe = EntitlementCallProbe()
        var state = FeatureFixtures.quotaLimitedState
        state.entitlementStatus = .restoring
        let store = TestStore(initialState: state) {
            MediaLibraryFeature()
        } withDependencies: {
            $0.entitlement.restore = {
                await probe.recordRestore()
                return .cancelled
            }
        }

        await store.send(.restoreTapped)

        #expect(store.state.entitlementStatus == .restoring)
        #expect(await probe.totalOperationCount() == 0)
    }

    @Test("A failed or unverified entitlement operation can be retried", arguments: [
        MediaLibraryEntitlementStatus.cancelled,
        MediaLibraryEntitlementStatus.failed(.storeFailure),
        MediaLibraryEntitlementStatus.notVerified,
    ])
    @MainActor
    func retriesEntitlementOperation(_ status: MediaLibraryEntitlementStatus) async {
        var state = FeatureFixtures.quotaLimitedState
        state.entitlementStatus = status
        let store = TestStore(initialState: state) {
            MediaLibraryFeature()
        } withDependencies: {
            $0.entitlement.purchase = { .cancelled }
        }

        await store.send(.purchaseTapped) {
            $0.entitlementStatus = .purchasing
        }
        await store.receive(.purchaseResult(.cancelled)) {
            $0.entitlementStatus = .cancelled
        }
    }

    @Test("A pending purchase offers an explicit restore and verification path")
    @MainActor
    func pendingPurchaseCanRestore() async {
        var state = FeatureFixtures.quotaLimitedState
        state.entitlementStatus = .pending
        let store = TestStore(initialState: state) {
            MediaLibraryFeature()
        } withDependencies: {
            $0.entitlement.restore = { .restored }
            $0.entitlement.currentState = { .entitled }
        }

        await store.send(.restoreTapped) {
            $0.entitlementStatus = .restoring
        }
        await store.receive(.restoreResult(.restored)) {
            $0.entitlementStatus = .refreshing
        }
        await store.receive(.entitlementStateLoaded(.success(.entitled))) {
            $0.entitlementStatus = .activated
        }
    }

    @Test("A pending purchase can verify current Pro status")
    @MainActor
    func pendingPurchaseCanVerifyCurrentStatus() async {
        var state = FeatureFixtures.quotaLimitedState
        state.entitlementStatus = .pending
        let store = TestStore(initialState: state) {
            MediaLibraryFeature()
        } withDependencies: {
            $0.entitlement.currentState = { .entitled }
        }

        await store.send(.purchaseStatusCheckTapped) {
            $0.entitlementStatus = .refreshing
        }
        await store.receive(.entitlementStateLoaded(.success(.entitled))) {
            $0.entitlementStatus = .activated
        }
    }

    @Test("Purchase status checks are ignored outside pending state", arguments: nonPendingEntitlementStatuses)
    @MainActor
    func purchaseStatusCheckOutsidePendingDoesNothing(_ status: MediaLibraryEntitlementStatus) async {
        let probe = EntitlementCallProbe()
        var state = FeatureFixtures.quotaLimitedState
        state.entitlementStatus = status
        let store = TestStore(initialState: state) {
            MediaLibraryFeature()
        } withDependencies: {
            $0.entitlement.currentState = {
                await probe.recordStateRead()
                return .entitled
            }
        }

        await store.send(.purchaseStatusCheckTapped)

        #expect(store.state.entitlementStatus == status)
        #expect(await probe.totalOperationCount() == 0)
    }

    @Test("Every purchase result maps to an explicit state", arguments: purchaseResultCases)
    @MainActor
    func handlesEveryPurchaseResult(_ testCase: PurchaseResultCase) async {
        let stateReads = CallCounter()
        let store = TestStore(initialState: FeatureFixtures.quotaLimitedState) {
            MediaLibraryFeature()
        } withDependencies: {
            $0.entitlement.currentState = {
                await stateReads.increment()
                return .entitled
            }
        }

        if testCase.intermediateStatus == .available {
            await store.send(.purchaseResult(testCase.result))
        } else {
            await store.send(.purchaseResult(testCase.result)) {
                $0.entitlementStatus = testCase.intermediateStatus
            }
        }
        if testCase.refreshesState {
            await store.receive(.entitlementStateLoaded(.success(.entitled))) {
                $0.entitlementStatus = .activated
            }
        }

        #expect(await stateReads.value == (testCase.refreshesState ? 1 : 0))
    }

    @Test("A successful result activates only after authoritative Pro state")
    @MainActor
    func activationRequiresAuthoritativeState() async {
        let store = TestStore(initialState: FeatureFixtures.quotaLimitedState) {
            MediaLibraryFeature()
        } withDependencies: {
            $0.entitlement.currentState = { .notEntitled }
        }

        await store.send(.restoreResult(.restored)) {
            $0.entitlementStatus = .refreshing
        }
        await store.receive(.entitlementStateLoaded(.success(.notEntitled))) {
            $0.entitlementStatus = .notVerified
        }
    }

    @Test("Every entitlement failure maps to user-facing copy", arguments: entitlementErrorCopyCases)
    @MainActor
    func entitlementFailureUsesSpecificCopy(_ testCase: EntitlementErrorCopyCase) {
        #expect(MediaLibraryView.entitlementFailureMessage(for: testCase.error) == testCase.message)
    }

    @Test("Free limit copy uses the configured logical asset quota")
    @MainActor
    func freeLimitCopyUsesConfiguredQuota() {
        let copy = MediaLibraryView.message(for: .assetLimitReached)

        #expect(copy.contains("\(MediaLibraryQuota.freeLogicalAssetLimit)"))
        #expect(copy.contains("logical asset"))
    }

    @Test("An entitlement refresh failure remains retryable")
    @MainActor
    func entitlementRefreshFailureRemainsRetryable() async {
        let store = TestStore(initialState: FeatureFixtures.quotaLimitedState) {
            MediaLibraryFeature()
        } withDependencies: {
            $0.entitlement.currentState = { throw EntitlementError.verificationFailed }
        }

        await store.send(.purchaseResult(.purchased)) {
            $0.entitlementStatus = .refreshing
        }
        await store.receive(.entitlementStateLoaded(.failure(.verificationFailed))) {
            $0.entitlementStatus = .failed(.verificationFailed)
        }
        await store.send(.retryTapped) {
            $0.error = nil
            $0.isPickerPresented = true
        }
    }

    @Test("Retry after a temporary check failure opens a fresh picker", arguments: [
        MediaLibraryFeatureError.entitlementUnavailable,
        MediaLibraryFeatureError.libraryUnavailable,
    ])
    @MainActor
    func retryAfterTemporaryFailureOpensPicker(_ error: MediaLibraryFeatureError) async {
        let urls = ImportURLRecorder()
        var state = MediaLibraryFeature.State(assets: [FeatureFixtures.asset])
        state.error = error
        let store = TestStore(initialState: state) {
            MediaLibraryFeature()
        } withDependencies: {
            $0.mediaLibrary.loadAssets = { [] }
            $0.mediaLibrary.importFile = { url in
                await urls.append(url)
                throw MediaImportError.sourceAccessFailed
            }
        }

        await store.send(.retryTapped) {
            $0.error = nil
            $0.isPickerPresented = true
        }

        #expect(await urls.value.isEmpty)
        #expect(store.state.assets == [FeatureFixtures.asset])

        let freshURL = URL(fileURLWithPath: "/provider/fresh-selection.png")
        await store.send(.fileSelected(freshURL)) {
            $0.isPickerPresented = false
            $0.isImporting = true
        }
        await store.receive(.importCompleted(.failure(.sourceAccessFailed))) {
            $0.isImporting = false
            $0.error = .importFailed
        }
        #expect(await urls.value == [freshURL])
    }

    @Test("Retry after confirmed activation imports the newly selected URL")
    @MainActor
    func activatedRetryUsesFreshSelection() async {
        let urls = ImportURLRecorder()
        let originalURL = URL(fileURLWithPath: "/provider/original-selection.png")
        let store = TestStore(initialState: FeatureFixtures.quotaLimitedState) {
            MediaLibraryFeature()
        } withDependencies: {
            $0.mediaLibrary.loadAssets = { [] }
            $0.mediaLibrary.importFile = { url in
                await urls.append(url)
                if url == originalURL {
                    throw MediaImportError.assetLimitReached
                }
                return FeatureFixtures.asset
            }
            $0.mediaLibrary.resourceData = { _ in FeatureFixtures.imageData }
            $0.entitlement.currentState = { .entitled }
        }

        await store.send(.fileSelected(originalURL)) {
            $0.isPickerPresented = false
            $0.isImporting = true
            $0.error = nil
        }
        await store.receive(.importCompleted(.failure(.assetLimitReached))) {
            $0.isImporting = false
            $0.error = .assetLimitReached
        }
        await store.receive(.assetsRefreshedAfterQuotaDenial(.success([])))
        await store.send(.purchaseResult(.alreadyEntitled)) {
            $0.entitlementStatus = .refreshing
        }
        await store.receive(.entitlementStateLoaded(.success(.entitled))) {
            $0.entitlementStatus = .activated
        }
        await store.send(.retryTapped) {
            $0.error = nil
            $0.isPickerPresented = true
        }
        #expect(await urls.value == [originalURL])

        let freshURL = URL(fileURLWithPath: "/provider/fresh-selection.png")
        await store.send(.fileSelected(freshURL)) {
            $0.isPickerPresented = false
            $0.isImporting = true
            $0.entitlementStatus = .available
        }
        await store.receive(.importCompleted(.success(FeatureFixtures.asset))) {
            $0.isImporting = false
            $0.entitlementStatus = .available
            $0.assets.append(FeatureFixtures.asset)
        }
        await store.receive(.resourceLoaded(
            FeatureFixtures.resourceID,
            .success(FeatureFixtures.imageData),
        )) {
            $0.resourceData[FeatureFixtures.resourceID] = FeatureFixtures.imageData
        }

        #expect(await urls.value == [originalURL, freshURL])
    }
}

private enum FeatureFixtures {
    static let assetID = requiredUUID("00000000-0000-0000-0000-000000000020")
    static let resourceID = requiredUUID("00000000-0000-0000-0000-000000000021")
    static let recoveredAssetID = requiredUUID("00000000-0000-0000-0000-000000000022")
    static let recoveredResourceID = requiredUUID("00000000-0000-0000-0000-000000000023")
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
    static let recoveredAsset = MediaAsset(
        id: recoveredAssetID,
        kind: .stillImage,
        importedAt: Date(timeIntervalSince1970: 1_725_000_001),
        resources: [
            MediaResource(
                id: recoveredResourceID,
                role: .original,
                relativePath: recoveredResourceID.uuidString.lowercased(),
                sourceFilename: "recovered-photo.png",
                sourceUTI: "public.png",
                byteCount: Int64(imageData.count),
                sha256: "0000000000000000000000000000000000000000000000000000000000000000",
            ),
        ],
    )

    static var quotaLimitedState: MediaLibraryFeature.State {
        var state = MediaLibraryFeature.State(assets: [asset])
        state.error = .assetLimitReached
        state.entitlementStatus = .available
        return state
    }
}

struct PurchaseResultCase: Sendable {
    let result: EntitlementOperationResult
    let intermediateStatus: MediaLibraryEntitlementStatus
    let refreshesState: Bool
}

private let purchaseResultCases = [
    PurchaseResultCase(
        result: .purchased,
        intermediateStatus: .refreshing,
        refreshesState: true,
    ),
    PurchaseResultCase(
        result: .restored,
        intermediateStatus: .refreshing,
        refreshesState: true,
    ),
    PurchaseResultCase(
        result: .alreadyEntitled,
        intermediateStatus: .refreshing,
        refreshesState: true,
    ),
    PurchaseResultCase(
        result: .pending,
        intermediateStatus: .pending,
        refreshesState: false,
    ),
    PurchaseResultCase(
        result: .cancelled,
        intermediateStatus: .cancelled,
        refreshesState: false,
    ),
    PurchaseResultCase(
        result: .failed(.storeFailure),
        intermediateStatus: .failed(.storeFailure),
        refreshesState: false,
    ),
]

private let nonPendingEntitlementStatuses: [MediaLibraryEntitlementStatus] = [
    .available,
    .purchasing,
    .restoring,
    .refreshing,
    .cancelled,
    .activated,
    .notVerified,
    .failed(.storeFailure),
]

struct EntitlementErrorCopyCase: Sendable {
    let error: EntitlementError
    let message: String
}

private let entitlementErrorCopyCases = [
    EntitlementErrorCopyCase(
        error: .productUnavailable,
        message: "The Pro purchase is not available right now. Restore purchases or try again later.",
    ),
    EntitlementErrorCopyCase(
        error: .incompatibleProduct,
        message: "The Pro purchase is not available right now. Restore purchases or try again later.",
    ),
    EntitlementErrorCopyCase(
        error: .noEntitlementFound,
        message: "No active Pro purchase was found for this Apple Account.",
    ),
    EntitlementErrorCopyCase(
        error: .verificationFailed,
        message: "StoreKit could not verify the purchase, so Pro was not granted.",
    ),
    EntitlementErrorCopyCase(
        error: .storeFailure,
        message: "The App Store could not complete the request. Try again.",
    ),
]

private actor EntitlementCallProbe {
    private var purchases = 0
    private var restores = 0
    private var stateReads = 0

    func recordPurchase() {
        purchases += 1
    }

    func recordRestore() {
        restores += 1
    }

    func recordStateRead() {
        stateReads += 1
    }

    func purchaseCount() -> Int {
        purchases
    }

    func restoreCount() -> Int {
        restores
    }

    func totalOperationCount() -> Int {
        purchases + restores + stateReads
    }
}

private actor ImportURLRecorder {
    private(set) var value: [URL] = []

    func append(_ url: URL) {
        value.append(url)
    }
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
