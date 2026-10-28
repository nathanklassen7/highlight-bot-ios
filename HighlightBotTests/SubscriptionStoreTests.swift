import StoreKit
import StoreKitTest
import Testing
@testable import HighlightBot

@MainActor
@Suite(.serialized)
struct SubscriptionStoreTests {
    let session: SKTestSession

    init() async throws {
        session = try SKTestSession(configurationFileNamed: "HighlightBot")
        session.resetToDefaultState()
        session.disableDialogs = true
        session.clearTransactions()
        // `clearTransactions` returns before `currentEntitlements` catches
        // up, so a subscription bought by the previous test can still show.
        for _ in 0..<40 where await Self.hasEntitlements() {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(await !Self.hasEntitlements(), "StoreKit Testing still reports an entitlement from a previous test")
    }

    @Test("Buying Pro unlocks montage and slow-mo")
    func purchaseUnlocks() async throws {
        let store = SubscriptionStore(defaults: Self.freshDefaults())
        store.isTestingOverrideEnabled = false
        #expect(!store.allows(.montage))
        await store.loadProduct()
        let product = try #require(store.product)

        let result = try await product.purchase()
        let outcome = try await store.complete(result)

        #expect(outcome == .purchased)
        #expect(store.isSubscribed)
        #expect(store.allows(.montage))
        #expect(store.allows(.slowMotion))
    }

    @Test("The testing override is on by default and unlocks Pro without a purchase")
    func testingOverrideDefaultsOn() async throws {
        let store = SubscriptionStore(defaults: Self.freshDefaults())
        await store.refreshEntitlement()

        #expect(store.isTestingOverrideEnabled)
        #expect(!store.isSubscribed)
        #expect(store.allows(.montage))
        #expect(store.allows(.slowMotion))
    }

    @Test("Turning the override off persists and locks Pro")
    func testingOverridePersists() async throws {
        let defaults = Self.freshDefaults()
        let store = SubscriptionStore(defaults: defaults)
        store.isTestingOverrideEnabled = false
        #expect(!store.allows(.slowMotion))

        let reloaded = SubscriptionStore(defaults: defaults)
        #expect(!reloaded.isTestingOverrideEnabled)
        #expect(!reloaded.allows(.slowMotion))
    }

    /// An empty, throwaway suite so override state can't leak between tests.
    private static func freshDefaults() -> UserDefaults {
        let name = "SubscriptionStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test("A fresh store picks up an existing subscription")
    func existingSubscriptionIsRead() async throws {
        try await session.buyProduct(identifier: SubscriptionStore.productID)

        let store = SubscriptionStore()
        await store.refreshEntitlement()

        #expect(store.isSubscribed)
    }

    @Test("An expired subscription locks Pro again")
    func expiryLocks() async throws {
        try await session.buyProduct(identifier: SubscriptionStore.productID)
        try session.expireSubscription(productIdentifier: SubscriptionStore.productID)

        let store = SubscriptionStore()
        await store.refreshEntitlement()

        #expect(!store.isSubscribed)
    }

    @Test("A refunded subscription locks Pro again")
    func refundLocks() async throws {
        let transaction = try await session.buyProduct(identifier: SubscriptionStore.productID)
        try session.refundTransaction(identifier: UInt(transaction.id))

        let store = SubscriptionStore()
        await store.refreshEntitlement()

        #expect(!store.isSubscribed)
    }

    private static func hasEntitlements() async -> Bool {
        for await _ in Transaction.currentEntitlements {
            return true
        }
        return false
    }
}
