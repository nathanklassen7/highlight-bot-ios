import Foundation
import Observation
import StoreKit

/// Features that need HighlightBot Pro.
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

/// HighlightBot Pro, the app's single auto-renewing subscription.
///
/// Access is read from StoreKit's verified entitlements at launch, on every
/// return to the foreground, and whenever a transaction arrives. The
/// entitlement itself is never cached in `UserDefaults`, so expiry, refunds,
/// and Family Sharing changes take effect without extra bookkeeping.
///
/// Debug and Beta builds (see `isTestBuild`) also honour
/// `isTestingOverrideEnabled`, which grants Pro without a purchase so testers
/// aren't bound to the sandbox's accelerated renewal cycle. Production builds
/// ignore it: `isTestBuild` is a compile-time constant false there.
///
/// Everything above only applies while `isPaywallActive`. When it is false the
/// store is inert: nothing is locked and StoreKit is never touched.
@MainActor
@Observable
final class SubscriptionStore {
    nonisolated static let productID = "com.nathanklassen.highlightbot.pro.monthly"
    private static let testingOverrideKey = "proTestingOverrideEnabled"
    private static let paywallPreviewKey = "paywallPreviewEnabled"

    /// Master switch for all paywall behavior. v1 ships with it off: no feature
    /// is locked, no Pro or upgrade UI appears, and StoreKit is never touched.
    /// A later release sets it to `true` to turn payments on for everyone. It is
    /// a plain constant rather than a compile flag so tests can cover both
    /// states through `init(isPaywallEnabled:)`.
    nonisolated static let isPaywallEnabled = false

    /// True for Debug builds and for Release builds archived with
    /// `BETA_FLAG=BETA` (the TestFlight build). Decided at compile time, not
    /// from the receipt: App Review also runs against a sandbox receipt, and
    /// the submitted build must not contain any developer controls.
    nonisolated static let isTestBuild: Bool = {
        #if DEBUG || BETA
        return true
        #else
        return false
        #endif
    }()

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
    /// Whether the App Store reports an active Pro subscription. Does not
    /// include the testing override; use `allows(_:)` to gate features.
    private(set) var isSubscribed = false

    /// Unlocks Pro features without a purchase. On by default, persisted in
    /// `UserDefaults`, and only consulted when `isTestBuild` is true.
    var isTestingOverrideEnabled: Bool {
        didSet {
            guard isTestingOverrideEnabled != oldValue else { return }
            defaults.set(isTestingOverrideEnabled, forKey: Self.testingOverrideKey)
        }
    }

    /// Previews the paywall while `isPaywallEnabled` is false, so TestFlight
    /// testers can exercise purchases before launch. Off by default, persisted
    /// in `UserDefaults`, and only consulted when `isTestBuild` is true.
    var isPaywallPreviewEnabled: Bool {
        didSet {
            guard isPaywallPreviewEnabled != oldValue else { return }
            defaults.set(isPaywallPreviewEnabled, forKey: Self.paywallPreviewKey)
            if isPaywallActive {
                start()
            } else {
                stop()
            }
        }
    }

    /// Whether paywall behavior exists right now: the master switch, or the
    /// preview in a test build. Production builds can only get here through
    /// `isPaywallEnabled`.
    var isPaywallActive: Bool {
        paywallEnabled || (Self.isTestBuild && isPaywallPreviewEnabled)
    }

    @ObservationIgnored private let paywallEnabled: Bool
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var updatesTask: Task<Void, Never>?
    /// Newest verified Pro transaction this process has been handed directly,
    /// by a purchase or `Transaction.updates`. `currentEntitlements` can lag
    /// behind a purchase that just finished, so this counts too. Memory only;
    /// the next launch reads StoreKit afresh.
    @ObservationIgnored private var latestTransaction: Transaction?

    init(defaults: UserDefaults = .standard, isPaywallEnabled: Bool = SubscriptionStore.isPaywallEnabled) {
        self.defaults = defaults
        paywallEnabled = isPaywallEnabled
        isPaywallPreviewEnabled = defaults.bool(forKey: Self.paywallPreviewKey)
        // Absent means never touched: default on.
        isTestingOverrideEnabled = defaults.object(forKey: Self.testingOverrideKey) as? Bool ?? true
    }

    func allows(_ feature: ProFeature) -> Bool {
        guard isPaywallActive else { return true }
        return isSubscribed || (Self.isTestBuild && isTestingOverrideEnabled)
    }

    /// Starts listening for transactions and loads the product. Idempotent.
    func start() {
        guard isPaywallActive, updatesTask == nil else { return }
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

    /// Stops listening and drops everything read from StoreKit, so turning
    /// the preview off leaves the store as if `start()` had never run.
    private func stop() {
        updatesTask?.cancel()
        updatesTask = nil
        latestTransaction = nil
        product = nil
        loadState = .idle
        isSubscribed = false
    }

    func refreshEntitlement() async {
        guard isPaywallActive else { return }
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
        guard isPaywallActive else { return }
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
        guard isPaywallActive, loadState != .loading else { return }
        loadState = .loading
        do {
            let loaded = try await Product.products(for: [Self.productID]).first
            guard isPaywallActive else { return }
            product = loaded
            if product == nil {
                Log.store.error("App Store returned no product for \(Self.productID, privacy: .public)")
            }
            loadState = product == nil ? .failed : .loaded
        } catch {
            guard isPaywallActive else { return }
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
        guard isPaywallActive else { return false }
        try await AppStore.sync()
        await refreshEntitlement()
        return isSubscribed
    }
}
