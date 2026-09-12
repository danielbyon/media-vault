import Foundation
import Testing

@testable import Entitlement

@Suite("StoreKit entitlement adapter")
struct StoreKitEntitlementClientTests {
  private let productIdentifier = "fixture.pro"

  @Test("A verified absence is reported as not entitled")
  func verifiedAbsenceIsNotEntitled() async throws {
    let store = FakeEntitlementStore(product: .nonConsumable(identifier: productIdentifier))
    let client = makeClient(store: store)

    let state = try await client.currentState()

    #expect(state == .notEntitled)
    let snapshot = await store.snapshot()
    #expect(snapshot.currentEntitlementsCalls == 1)
    #expect(snapshot.latestTransactionCalls == 1)
    #expect(snapshot.finishCalls.isEmpty)
  }

  @Test("A verified active transaction is reported as entitled")
  func verifiedActiveTransactionIsEntitled() async throws {
    let transaction = EntitlementStoreTransaction.active(productIdentifier: productIdentifier)
    let store = FakeEntitlementStore(
      product: .nonConsumable(identifier: productIdentifier),
      currentEntitlements: [.verified(transaction)]
    )
    let client = makeClient(store: store)

    #expect(try await client.currentState() == .entitled)
    let snapshot = await store.snapshot()
    #expect(snapshot.latestTransactionCalls == 0)
    #expect(snapshot.finishCalls.isEmpty)
  }

  @Test("An active entitlement does not require product metadata")
  func activeEntitlementDoesNotLoadProductMetadata() async throws {
    let transaction = EntitlementStoreTransaction.active(productIdentifier: productIdentifier)
    let store = FakeEntitlementStore(
      product: nil,
      currentEntitlements: [.verified(transaction)]
    )
    let client = makeClient(store: store)

    #expect(try await client.currentState() == .entitled)
    #expect((await store.snapshot()).loadedProductIdentifiers.isEmpty)
  }

  @Test("A verified revoked transaction is reported as revoked")
  func verifiedRevokedTransactionIsRevoked() async throws {
    let transaction = EntitlementStoreTransaction(
      productIdentifier: productIdentifier,
      revocationDate: Date(timeIntervalSince1970: 1_725_000_001)
    )
    let store = FakeEntitlementStore(
      product: .nonConsumable(identifier: productIdentifier),
      latestTransaction: .verified(transaction)
    )
    let client = makeClient(store: store)

    #expect(try await client.currentState() == .revoked)
    let snapshot = await store.snapshot()
    #expect(snapshot.currentEntitlementsCalls == 1)
    #expect(snapshot.latestTransactionCalls == 1)
    #expect(snapshot.finishCalls.isEmpty)
  }

  @Test("An unverified current transaction fails closed")
  func unverifiedCurrentTransactionFailsClosed() async {
    let store = FakeEntitlementStore(
      product: .nonConsumable(identifier: productIdentifier),
      currentEntitlements: [.unverified(productIdentifier: productIdentifier)]
    )
    let client = makeClient(store: store)

    await expectStateError(.verificationFailed, from: client)
    #expect((await store.snapshot()).finishCalls.isEmpty)
  }

  @Test("An unverified transaction for another product is ignored")
  func unverifiedOtherProductIsIgnored() async throws {
    let store = FakeEntitlementStore(
      product: .nonConsumable(identifier: productIdentifier),
      currentEntitlements: [.unverified(productIdentifier: "fixture.other")]
    )
    let client = makeClient(store: store)

    #expect(try await client.currentState() == .notEntitled)
  }

  @Test("An unverified latest transaction fails closed")
  func unverifiedLatestTransactionFailsClosed() async {
    let store = FakeEntitlementStore(
      product: .nonConsumable(identifier: productIdentifier),
      latestTransaction: .unverified(productIdentifier: productIdentifier)
    )
    let client = makeClient(store: store)

    await expectStateError(.verificationFailed, from: client)
  }

  @Test("An unverified latest transaction for another product is ignored")
  func unverifiedLatestOtherProductIsIgnored() async throws {
    let store = FakeEntitlementStore(
      product: .nonConsumable(identifier: productIdentifier),
      latestTransaction: .unverified(productIdentifier: "fixture.other")
    )
    let client = makeClient(store: store)

    #expect(try await client.currentState() == .notEntitled)
  }

  @Test("A StoreKit lookup failure is not reported as absence")
  func lookupFailureIsNotAbsence() async {
    let store = FakeEntitlementStore(
      product: .nonConsumable(identifier: productIdentifier),
      currentEntitlementsError: .storeUnavailable
    )
    let client = makeClient(store: store)

    await expectStateError(.storeFailure, from: client)
  }

  @Test("A missing product does not prevent state lookup")
  func missingProductDoesNotPreventStateLookup() async throws {
    let store = FakeEntitlementStore(product: nil)
    let client = makeClient(store: store)

    #expect(try await client.currentState() == .notEntitled)
    #expect((await store.snapshot()).loadedProductIdentifiers.isEmpty)
  }

  @Test("An incompatible product does not prevent state lookup")
  func incompatibleProductDoesNotPreventStateLookup() async throws {
    let store = FakeEntitlementStore(product: .subscription(identifier: productIdentifier))
    let client = makeClient(store: store)

    #expect(try await client.currentState() == .notEntitled)
    #expect((await store.snapshot()).loadedProductIdentifiers.isEmpty)
  }

  @Test("A verified purchase is accepted and finished exactly once")
  func verifiedPurchaseIsAcceptedAndFinished() async {
    let transaction = EntitlementStoreTransaction.active(productIdentifier: productIdentifier)
    let store = FakeEntitlementStore(
      product: .nonConsumable(identifier: productIdentifier),
      purchaseResult: .success(.verified(transaction))
    )
    let client = makeClient(store: store)

    #expect(await client.purchase() == .purchased)
    let snapshot = await store.snapshot()
    #expect(snapshot.purchaseCalls == 1)
    #expect(snapshot.finishCalls == [transaction])
  }

  @Test("A verified revoked purchase is finished before it fails")
  func verifiedRevokedPurchaseIsFinished() async {
    let transaction = EntitlementStoreTransaction(
      productIdentifier: productIdentifier,
      revocationDate: Date(timeIntervalSince1970: 1_725_000_002)
    )
    let store = FakeEntitlementStore(
      product: .nonConsumable(identifier: productIdentifier),
      purchaseResult: .success(.verified(transaction))
    )
    let client = makeClient(store: store)

    #expect(await client.purchase() == .failed(.verificationFailed))
    #expect((await store.snapshot()).finishCalls == [transaction])
  }

  @Test("An active entitlement avoids a duplicate purchase")
  func activeEntitlementAvoidsDuplicatePurchase() async {
    let transaction = EntitlementStoreTransaction.active(productIdentifier: productIdentifier)
    let store = FakeEntitlementStore(
      product: nil,
      currentEntitlements: [.verified(transaction)]
    )
    let client = makeClient(store: store)

    #expect(await client.purchase() == .alreadyEntitled)
    let snapshot = await store.snapshot()
    #expect(snapshot.purchaseCalls == 0)
    #expect(snapshot.loadedProductIdentifiers.isEmpty)
    #expect(snapshot.finishCalls.isEmpty)
  }

  @Test("An unverified purchase fails without finishing the transaction")
  func unverifiedPurchaseFailsWithoutFinishing() async {
    let store = FakeEntitlementStore(
      product: .nonConsumable(identifier: productIdentifier),
      purchaseResult: .success(.unverified(productIdentifier: productIdentifier))
    )
    let client = makeClient(store: store)

    #expect(await client.purchase() == .failed(.verificationFailed))
    let snapshot = await store.snapshot()
    #expect(snapshot.finishCalls.isEmpty)
  }

  @Test("A pending purchase remains pending")
  func pendingPurchaseRemainsPending() async {
    let store = FakeEntitlementStore(
      product: .nonConsumable(identifier: productIdentifier),
      purchaseResult: .pending
    )
    let client = makeClient(store: store)

    #expect(await client.purchase() == .pending)
    #expect((await store.snapshot()).finishCalls.isEmpty)
  }

  @Test("A cancelled purchase remains cancelled")
  func cancelledPurchaseRemainsCancelled() async {
    let store = FakeEntitlementStore(
      product: .nonConsumable(identifier: productIdentifier),
      purchaseResult: .cancelled
    )
    let client = makeClient(store: store)

    #expect(await client.purchase() == .cancelled)
    #expect((await store.snapshot()).finishCalls.isEmpty)
  }

  @Test("A missing product prevents a purchase attempt")
  func missingProductPreventsPurchaseAttempt() async {
    let store = FakeEntitlementStore(product: nil)
    let client = makeClient(store: store)

    #expect(await client.purchase() == .failed(.productUnavailable))
    #expect((await store.snapshot()).purchaseCalls == 0)
  }

  @Test("An incompatible product prevents a purchase attempt")
  func incompatibleProductPreventsPurchaseAttempt() async {
    let store = FakeEntitlementStore(product: .subscription(identifier: productIdentifier))
    let client = makeClient(store: store)

    #expect(await client.purchase() == .failed(.incompatibleProduct))
    #expect((await store.snapshot()).purchaseCalls == 0)
  }

  @Test("A purchase store failure is app-owned")
  func purchaseStoreFailureIsAppOwned() async {
    let store = FakeEntitlementStore(
      product: .nonConsumable(identifier: productIdentifier),
      purchaseError: .storeUnavailable
    )
    let client = makeClient(store: store)

    #expect(await client.purchase() == .failed(.storeFailure))
    #expect((await store.snapshot()).finishCalls.isEmpty)
  }

  @Test("Restore returns already entitled without synchronization")
  func restoreAlreadyEntitledDoesNotSynchronize() async {
    let transaction = EntitlementStoreTransaction.active(productIdentifier: productIdentifier)
    let store = FakeEntitlementStore(
      product: nil,
      currentEntitlements: [.verified(transaction)]
    )
    let client = makeClient(store: store)

    #expect(await client.restore() == .alreadyEntitled)
    let snapshot = await store.snapshot()
    #expect(snapshot.synchronizeCalls == 0)
    #expect(snapshot.loadedProductIdentifiers.isEmpty)
    #expect(snapshot.finishCalls.isEmpty)
  }

  @Test("Restore synchronizes only when no active entitlement exists")
  func restoreSynchronizesExplicitly() async {
    let transaction = EntitlementStoreTransaction.active(productIdentifier: productIdentifier)
    let store = FakeEntitlementStore(
      product: nil,
      currentEntitlementsAfterSynchronize: [.verified(transaction)]
    )
    let client = makeClient(store: store)

    #expect(await client.restore() == .restored)
    let snapshot = await store.snapshot()
    #expect(snapshot.synchronizeCalls == 1)
    #expect(snapshot.loadedProductIdentifiers.isEmpty)
    #expect(snapshot.finishCalls.isEmpty)
  }

  @Test("A restore with no entitlement reports no entitlement")
  func restoreWithNoEntitlementReportsNoEntitlement() async {
    let store = FakeEntitlementStore(product: nil)
    let client = makeClient(store: store)

    #expect(await client.restore() == .failed(.noEntitlementFound))
    let snapshot = await store.snapshot()
    #expect(snapshot.synchronizeCalls == 1)
    #expect(snapshot.loadedProductIdentifiers.isEmpty)
    #expect(snapshot.finishCalls.isEmpty)
  }

  @Test("A restore failure is app-owned")
  func restoreFailureIsAppOwned() async {
    let store = FakeEntitlementStore(
      product: nil,
      synchronizeError: .storeUnavailable
    )
    let client = makeClient(store: store)

    #expect(await client.restore() == .failed(.storeFailure))
    #expect((await store.snapshot()).synchronizeCalls == 1)
    #expect((await store.snapshot()).loadedProductIdentifiers.isEmpty)
  }

  @Test("Current state never synchronizes or finishes transactions")
  func currentStateHasNoRestoreOrFinishSideEffects() async throws {
    let store = FakeEntitlementStore(
      product: .nonConsumable(identifier: productIdentifier),
      currentEntitlements: [
        .verified(EntitlementStoreTransaction.active(productIdentifier: productIdentifier))
      ]
    )
    let client = makeClient(store: store)

    _ = try await client.currentState()
    let snapshot = await store.snapshot()
    #expect(snapshot.synchronizeCalls == 0)
    #expect(snapshot.finishCalls.isEmpty)
  }

  private func makeClient(store: FakeEntitlementStore) -> StoreKitEntitlementClient {
    StoreKitEntitlementClient(productIdentifier: productIdentifier, store: store)
  }

  private func expectStateError(
    _ expected: EntitlementError,
    from client: StoreKitEntitlementClient
  ) async {
    do {
      _ = try await client.currentState()
      Issue.record("Expected current state to fail with \(expected)")
    } catch let error as EntitlementError {
      #expect(error == expected)
    } catch {
      Issue.record("Expected EntitlementError, received \(error)")
    }
  }
}

private actor FakeEntitlementStore: EntitlementStore {
  struct Snapshot: Sendable {
    let loadedProductIdentifiers: [String]
    let purchaseCalls: Int
    let synchronizeCalls: Int
    let currentEntitlementsCalls: Int
    let latestTransactionCalls: Int
    let finishCalls: [EntitlementStoreTransaction]
  }

  private let product: EntitlementStoreProduct?
  private var currentEntitlements: [EntitlementStoreVerification]
  private let currentEntitlementsAfterSynchronize: [EntitlementStoreVerification]?
  private let latestTransaction: EntitlementStoreVerification?
  private let purchaseResult: EntitlementStorePurchaseResult
  private let loadProductError: FakeStoreError?
  private let purchaseError: FakeStoreError?
  private let synchronizeError: FakeStoreError?
  private let currentEntitlementsError: FakeStoreError?
  private let latestTransactionError: FakeStoreError?

  private var loadedProductIdentifiers: [String] = []
  private var purchaseCallCount = 0
  private var synchronizeCallCount = 0
  private var currentEntitlementsCallCount = 0
  private var latestTransactionCallCount = 0
  private var finishedTransactions: [EntitlementStoreTransaction] = []

  init(
    product: EntitlementStoreProduct?,
    currentEntitlements: [EntitlementStoreVerification] = [],
    currentEntitlementsAfterSynchronize: [EntitlementStoreVerification]? = nil,
    latestTransaction: EntitlementStoreVerification? = nil,
    purchaseResult: EntitlementStorePurchaseResult = .cancelled,
    loadProductError: FakeStoreError? = nil,
    purchaseError: FakeStoreError? = nil,
    synchronizeError: FakeStoreError? = nil,
    currentEntitlementsError: FakeStoreError? = nil,
    latestTransactionError: FakeStoreError? = nil
  ) {
    self.product = product
    self.currentEntitlements = currentEntitlements
    self.currentEntitlementsAfterSynchronize = currentEntitlementsAfterSynchronize
    self.latestTransaction = latestTransaction
    self.purchaseResult = purchaseResult
    self.loadProductError = loadProductError
    self.purchaseError = purchaseError
    self.synchronizeError = synchronizeError
    self.currentEntitlementsError = currentEntitlementsError
    self.latestTransactionError = latestTransactionError
  }

  func loadProduct(identifier: String) async throws -> EntitlementStoreProduct? {
    loadedProductIdentifiers.append(identifier)
    if let loadProductError {
      throw loadProductError
    }
    return product
  }

  func purchase(product: EntitlementStoreProduct) async throws -> EntitlementStorePurchaseResult {
    purchaseCallCount += 1
    if let purchaseError {
      throw purchaseError
    }
    return purchaseResult
  }

  func synchronize() async throws {
    synchronizeCallCount += 1
    if let synchronizeError {
      throw synchronizeError
    }
    if let currentEntitlementsAfterSynchronize {
      currentEntitlements = currentEntitlementsAfterSynchronize
    }
  }

  func currentEntitlements(for identifier: String) async throws -> [EntitlementStoreVerification] {
    currentEntitlementsCallCount += 1
    if let currentEntitlementsError {
      throw currentEntitlementsError
    }
    return currentEntitlements.filter { $0.productIdentifier == identifier }
  }

  func latestTransaction(for identifier: String) async throws -> EntitlementStoreVerification? {
    latestTransactionCallCount += 1
    if let latestTransactionError {
      throw latestTransactionError
    }
    guard let latestTransaction, latestTransaction.productIdentifier == identifier else {
      return nil
    }
    return latestTransaction
  }

  func finish(_ transaction: EntitlementStoreTransaction) async {
    finishedTransactions.append(transaction)
  }

  func snapshot() -> Snapshot {
    Snapshot(
      loadedProductIdentifiers: loadedProductIdentifiers,
      purchaseCalls: purchaseCallCount,
      synchronizeCalls: synchronizeCallCount,
      currentEntitlementsCalls: currentEntitlementsCallCount,
      latestTransactionCalls: latestTransactionCallCount,
      finishCalls: finishedTransactions
    )
  }
}

private enum FakeStoreError: Error, Sendable {
  case storeUnavailable
}

private extension EntitlementStoreProduct {
  static func nonConsumable(identifier: String) -> Self {
    Self(identifier: identifier, type: .nonConsumable)
  }

  static func subscription(identifier: String) -> Self {
    Self(identifier: identifier, type: .other)
  }
}

private extension EntitlementStoreTransaction {
  static func active(productIdentifier: String) -> Self {
    Self(productIdentifier: productIdentifier, revocationDate: nil)
  }
}
