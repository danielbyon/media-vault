//
//  StoreKitEntitlementClient.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import StoreKit

struct StoreKitEntitlementClient: Sendable {
    let productIdentifier: String
    let store: any EntitlementStore

    var dependency: EntitlementClient {
        let client = self
        return EntitlementClient(
            currentState: { try await client.currentState() },
            purchase: { await client.purchase() },
            restore: { await client.restore() },
        )
    }

    func currentState() async throws -> ProEntitlementState {
        do {
            return try await establishedState()
        } catch let error as EntitlementError {
            throw error
        } catch {
            throw EntitlementError.storeFailure
        }
    }

    func purchase() async -> EntitlementOperationResult {
        do {
            if try await establishedState() == .entitled {
                return .alreadyEntitled
            }

            let product = try await validatedProduct()

            switch try await store.purchase(product: product) {
            case let .success(.verified(transaction)):
                guard transaction.productIdentifier == productIdentifier else {
                    return .failed(.verificationFailed)
                }

                await store.finish(transaction)
                return transaction.isRevoked ? .failed(.verificationFailed) : .purchased

            case .success(.unverified(productIdentifier: _)):
                return .failed(.verificationFailed)

            case .pending:
                return .pending

            case .cancelled:
                return .cancelled
            }
        } catch let error as EntitlementError {
            return .failed(error)
        } catch {
            return .failed(.storeFailure)
        }
    }

    func restore() async -> EntitlementOperationResult {
        do {
            if try await establishedState() == .entitled {
                return .alreadyEntitled
            }

            try await store.synchronize()

            switch try await establishedState() {
            case .entitled:
                return .restored
            case .notEntitled,
                 .revoked:
                return .failed(.noEntitlementFound)
            }
        } catch let error as EntitlementError {
            return .failed(error)
        } catch {
            return .failed(.storeFailure)
        }
    }

    private func validatedProduct() async throws -> EntitlementStoreProduct {
        guard !productIdentifier.isEmpty else {
            throw EntitlementError.productUnavailable
        }
        guard let product = try await store.loadProduct(identifier: productIdentifier) else {
            throw EntitlementError.productUnavailable
        }
        guard product.identifier == productIdentifier else {
            throw EntitlementError.productUnavailable
        }
        guard product.type == .nonConsumable else {
            throw EntitlementError.incompatibleProduct
        }

        return product
    }

    private func establishedState() async throws -> ProEntitlementState {
        let currentEntitlements = try await store.currentEntitlements(for: productIdentifier)
        for result in currentEntitlements {
            switch result {
            case let .verified(transaction):
                guard transaction.productIdentifier == productIdentifier else {
                    continue
                }

                return transaction.isRevoked ? .revoked : .entitled
            case .unverified(productIdentifier: _):
                throw EntitlementError.verificationFailed
            }
        }

        guard let latestTransaction = try await store.latestTransaction(for: productIdentifier) else {
            return .notEntitled
        }

        switch latestTransaction {
        case let .verified(transaction):
            return transaction.isRevoked ? .revoked : .notEntitled
        case .unverified(productIdentifier: _):
            throw EntitlementError.verificationFailed
        }
    }
}

struct StoreKitEntitlementStore: EntitlementStore {
    func loadProduct(identifier: String) async throws -> EntitlementStoreProduct? {
        let products = try await Product.products(for: [identifier])
        guard let product = products.first(where: { $0.id == identifier }) else {
            return nil
        }

        return EntitlementStoreProduct(
            identifier: product.id,
            type: product.type == .nonConsumable ? .nonConsumable : .other,
        )
    }

    func purchase(product: EntitlementStoreProduct) async throws -> EntitlementStorePurchaseResult {
        let products = try await Product.products(for: [product.identifier])
        guard let storeProduct = products.first(where: { $0.id == product.identifier }) else {
            throw EntitlementError.productUnavailable
        }
        guard storeProduct.type == .nonConsumable else {
            throw EntitlementError.incompatibleProduct
        }

        switch try await storeProduct.purchase() {
        case let .success(.verified(transaction)):
            let appTransaction = EntitlementStoreTransaction(
                productIdentifier: transaction.productID,
                revocationDate: transaction.revocationDate,
                finishAction: { await transaction.finish() },
            )
            return .success(.verified(appTransaction))

        case let .success(.unverified(transaction, _)):
            return .success(.unverified(productIdentifier: transaction.productID))

        case .pending:
            return .pending

        case .userCancelled:
            return .cancelled

        @unknown default:
            throw EntitlementError.storeFailure
        }
    }

    func synchronize() async throws {
        try await AppStore.sync()
    }

    func currentEntitlements(for identifier: String) async throws -> [EntitlementStoreVerification] {
        var entitlements: [EntitlementStoreVerification] = []
        for await result in Transaction.currentEntitlements {
            if let entitlement = map(result, matching: identifier) {
                entitlements.append(entitlement)
            }
        }
        return entitlements
    }

    func latestTransaction(for identifier: String) async throws -> EntitlementStoreVerification? {
        guard let result = await Transaction.latest(for: identifier) else {
            return nil
        }

        return map(result)
    }

    func finish(_ transaction: EntitlementStoreTransaction) async {
        await transaction.finish()
    }

    private func map(
        _ result: VerificationResult<Transaction>,
        matching identifier: String? = nil,
    ) -> EntitlementStoreVerification? {
        switch result {
        case let .verified(transaction):
            guard identifier == nil || transaction.productID == identifier else {
                return nil
            }

            return .some(.verified(
                EntitlementStoreTransaction(
                    productIdentifier: transaction.productID,
                    revocationDate: transaction.revocationDate,
                ),
            ))
        case let .unverified(transaction, _):
            guard identifier == nil || transaction.productID == identifier else {
                return nil
            }

            return .some(.unverified(productIdentifier: transaction.productID))
        }
    }
}
