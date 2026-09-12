//
//  EntitlementClient.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Dependencies
import DependenciesMacros
import Foundation

/// The durable Pro capability state reported by the entitlement boundary.
public enum ProEntitlementState: Equatable, Sendable {
    /// StoreKit has established that no active Pro entitlement exists.
    case notEntitled

    /// StoreKit has established that the user owns the active Pro entitlement.
    case entitled

    /// StoreKit has established that a prior Pro entitlement was revoked or refunded.
    case revoked
}

/// Failures that prevent the entitlement boundary from making a trustworthy decision.
public enum EntitlementError: Error, Equatable, Sendable {
    /// The configured product identifier did not resolve to a StoreKit product.
    case productUnavailable

    /// The configured product resolved to a product that is not a non-consumable.
    case incompatibleProduct

    /// Restore completed, but no active Pro entitlement was found.
    case noEntitlementFound

    /// StoreKit returned a transaction that could not be verified.
    case verificationFailed

    /// StoreKit could not complete the requested operation.
    case storeFailure
}

/// The result of an explicit purchase or restore operation.
public enum EntitlementOperationResult: Equatable, Sendable {
    /// A verified Pro purchase was accepted and its transaction was finished.
    case purchased

    /// Restore discovered a verified active Pro entitlement.
    case restored

    /// The user already has an active Pro entitlement.
    case alreadyEntitled

    /// StoreKit has not completed the purchase yet.
    case pending

    /// The user cancelled the purchase.
    case cancelled

    /// The operation could not establish or grant the requested capability.
    case failed(EntitlementError)
}

/// Provides the app-owned boundary for reading and changing Pro entitlement state.
///
/// The client reports capability state only. It does not own media access, presentation, quota,
/// backup, authentication, or app-icon behavior. StoreKit types remain inside the live adapter.
@DependencyClient
public struct EntitlementClient: Sendable {
    /// Reads the current entitlement without synchronizing the App Store.
    public var currentState: @Sendable () async throws -> ProEntitlementState = {
        .notEntitled
    }

    /// Starts the explicit Pro purchase operation.
    public var purchase: @Sendable () async -> EntitlementOperationResult = {
        .failed(.storeFailure)
    }

    /// Synchronizes purchases after an explicit user-requested restore action.
    public var restore: @Sendable () async -> EntitlementOperationResult = {
        .failed(.storeFailure)
    }
}

extension EntitlementClient: DependencyKey {
    /// The live entitlement implementation backed by StoreKit.
    public static var liveValue: Self {
        let productIdentifier = EntitlementConfiguration.productIdentifier(from: .main)
        return StoreKitEntitlementClient(
            productIdentifier: productIdentifier,
            store: StoreKitEntitlementStore(),
        ).dependency
    }

    /// The deterministic entitlement implementation used by tests unless overridden.
    public static var testValue: Self {
        Self(
            currentState: { .notEntitled },
            purchase: { .failed(.storeFailure) },
            restore: { .failed(.storeFailure) },
        )
    }
}

extension DependencyValues {
    /// The brand-neutral Pro entitlement dependency.
    public var entitlement: EntitlementClient {
        get { self[EntitlementClient.self] }
        set { self[EntitlementClient.self] = newValue }
    }
}

enum EntitlementConfiguration {
    static let productIdentifierInfoKey = "PRO_PRODUCT_IDENTIFIER"

    static func productIdentifier(from bundle: Bundle) -> String {
        (bundle.object(forInfoDictionaryKey: productIdentifierInfoKey) as? String) ?? ""
    }
}

struct EntitlementStoreProduct: Equatable, Sendable {
    enum ProductType: Equatable, Sendable {
        case nonConsumable
        case other
    }

    let identifier: String
    let type: ProductType
}

struct EntitlementStoreTransaction: Equatable, Sendable {
    let productIdentifier: String
    let revocationDate: Date?
    private let finishAction: (@Sendable () async -> Void)?

    init(
        productIdentifier: String,
        revocationDate: Date? = nil,
        finishAction: (@Sendable () async -> Void)? = nil,
    ) {
        self.productIdentifier = productIdentifier
        self.revocationDate = revocationDate
        self.finishAction = finishAction
    }

    var isRevoked: Bool {
        revocationDate != nil
    }

    func finish() async {
        await finishAction?()
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.productIdentifier == rhs.productIdentifier
            && lhs.revocationDate == rhs.revocationDate
    }
}

enum EntitlementStoreVerification: Equatable, Sendable {
    case verified(EntitlementStoreTransaction)
    case unverified(productIdentifier: String)

    var productIdentifier: String {
        switch self {
        case let .verified(transaction):
            transaction.productIdentifier
        case let .unverified(productIdentifier):
            productIdentifier
        }
    }
}

enum EntitlementStorePurchaseResult: Equatable, Sendable {
    case success(EntitlementStoreVerification)
    case pending
    case cancelled
}

protocol EntitlementStore: Sendable {
    func loadProduct(identifier: String) async throws -> EntitlementStoreProduct?
    func purchase(product: EntitlementStoreProduct) async throws -> EntitlementStorePurchaseResult
    func synchronize() async throws
    func currentEntitlements(for identifier: String) async throws -> [EntitlementStoreVerification]
    func latestTransaction(for identifier: String) async throws -> EntitlementStoreVerification?
    func finish(_ transaction: EntitlementStoreTransaction) async
}
