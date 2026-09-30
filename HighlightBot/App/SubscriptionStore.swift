import Foundation
import Observation
import StoreKit
import os

/// Features that need Highlight Bot Pro.
enum ProFeature {
    case montage
    case slowMotion
}

enum SubscriptionError: Error, LocalizedError {
    case unverified

    var errorDescription: String? {
        switch self {
        case .unverified: "The App Store couldn't verify this purchase."
        }
    }
}

/// Highlight Bot Pro, the app's single auto-renewing subscription.
///
/// Access is read from StoreKit's verified entitlements at launch, on every
/// return to the foreground, and whenever a transaction arrives. Nothing is
/// cached in `UserDefaults`, so expiry, refunds, and Family Sharing changes
/// take effect without extra bookkeeping.
@MainActor
@Observable
final class SubscriptionStore {
    nonisolated static let productID = "com.nathanklassen.highlightbot.pro.monthly"

    enum LoadState: Equatable {
        case idle, loading, loaded, failed
    }

    enum PurchaseOutcome {
        case purchased
        /// Ask to Buy or a payment that needs action outside the app.
        case pending
        case cancelled
    }

    private(set) var product: Product?
    private(set) var loadState: LoadState = .idle
    private(set) var isSubscribed = false

    @ObservationIgnored private var updatesTask: Task<Void, Never>?
    /// Newest verified Pro transaction this process has been handed directly,
    /// by a purchase or `Transaction.updates`. `currentEntitlements` can lag
    /// behind a purchase that just finished, so this counts too. Memory only;
    /// the next launch reads StoreKit afresh.
    @ObservationIgnored private var latestTransaction: Transaction?

    func allows(_ feature: ProFeature) -> Bool {
        isSubscribed
    }

    /// Starts listening for transactions and loads the product. Idempotent.
    func start() {
        guard updatesTask == nil else { return }
        // Renewals, Ask to Buy approvals, refunds, and purchases made on
        // another device arrive here, including ones that landed while the
        // app was not running.
        updatesTask = Task { @MainActor [weak self] in
            for await result in Transaction.updates {
                guard let self else { return }
                if case .verified(let transaction) = result {
                    self.record(transaction)
                    await transaction.finish()
                } else {
                    Log.store.error("Unverified transaction update for \(result.unsafePayloadValue.productID, privacy: .public)")
                }
                await self.refreshEntitlement()
            }
        }
        Task {
            await refreshEntitlement()
            await loadProduct()
        }
    }

    func refreshEntitlement() async {
        var active = latestTransaction.map { Self.grantsPro($0) } ?? false
        for await result in Transaction.currentEntitlements {
            if case .verified(let transaction) = result, Self.grantsPro(transaction) {
                active = true
            }
        }
        if !active,
           case .verified(let transaction)? = await Transaction.latest(for: Self.productID),
           Self.grantsPro(transaction) {
            active = true
        }
        if active != isSubscribed {
            Log.store.info("Pro entitlement changed: \(active, privacy: .public)")
        }
        isSubscribed = active
    }

    /// Whether `transaction` is an unrevoked, unexpired Pro subscription.
    /// `currentEntitlements` can still return a subscription after it has
    /// expired, so the date is checked here rather than trusted.
    nonisolated static func grantsPro(_ transaction: Transaction) -> Bool {
        guard transaction.productID == productID, transaction.revocationDate == nil else { return false }
        if let expiration = transaction.expirationDate, expiration <= .now { return false }
        return true
    }

    private func record(_ transaction: Transaction) {
        guard transaction.productID == Self.productID else { return }
        if let latest = latestTransaction, latest.id != transaction.id,
           latest.purchaseDate > transaction.purchaseDate {
            return
        }
        latestTransaction = transaction
    }

    func loadProduct() async {
        guard loadState != .loading else { return }
        loadState = .loading
        do {
            product = try await Product.products(for: [Self.productID]).first
            if product == nil {
                Log.store.error("App Store returned no product for \(Self.productID, privacy: .public)")
            }
            loadState = product == nil ? .failed : .loaded
        } catch {
            Log.store.error("Loading products failed: \(error.localizedDescription, privacy: .public)")
            loadState = .failed
        }
    }

    /// Finishes a purchase started with SwiftUI's `purchase` environment
    /// action, which ties the payment sheet to the right scene.
    func complete(_ result: Product.PurchaseResult) async throws -> PurchaseOutcome {
        switch result {
        case .success(let verification):
            guard case .verified(let transaction) = verification else {
                Log.store.error("Purchase returned an unverified transaction for \(verification.unsafePayloadValue.productID, privacy: .public)")
                throw SubscriptionError.unverified
            }
            record(transaction)
            await transaction.finish()
            await refreshEntitlement()
            return .purchased
        case .pending:
            return .pending
        case .userCancelled:
            return .cancelled
        @unknown default:
            return .cancelled
        }
    }

    /// Asks the App Store for this Apple Account's purchases. May prompt the
    /// user to sign in. Returns whether Pro is active afterwards.
    func restore() async throws -> Bool {
        try await AppStore.sync()
        await refreshEntitlement()
        return isSubscribed
    }
}
