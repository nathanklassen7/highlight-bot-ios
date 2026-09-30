import StoreKit
import SwiftUI

/// Sales page for Highlight Bot Pro. Present as a sheet; it dismisses itself
/// once the subscription is active, so presenters can pick up the action
/// that was blocked in their `onDismiss`.
struct PaywallScreen: View {
    @Environment(AppContainer.self) private var container
    @Environment(\.dismiss) private var dismiss
    @Environment(\.purchase) private var purchase

    @State private var isPurchasing = false
    @State private var isRestoring = false
    @State private var message: String?

    private enum Links {
        static let termsOfUse = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!
        /// App Review requires a privacy policy link on subscription screens.
        static let privacyPolicy: URL? = nil
    }

    var body: some View {
        let store = container.subscriptions
        ZStack {
            background

            ScrollView {
                VStack(spacing: 32) {
                    hero
                    features
                }
                .padding(.horizontal, 24)
                .padding(.top, 64)
                .padding(.bottom, 24)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            footer(store)
        }
        .overlay(alignment: .topTrailing) {
            closeButton
        }
        .preferredColorScheme(.dark)
        .task {
            if store.product == nil {
                await store.loadProduct()
            }
        }
        .onChange(of: store.isSubscribed) { _, subscribed in
            if subscribed { dismiss() }
        }
    }

    // MARK: - Sections

    private var background: some View {
        ZStack {
            Color.black
            RadialGradient(
                colors: [AppPalette.accent.opacity(0.55), .clear],
                center: .top,
                startRadius: 0,
                endRadius: 420
            )
            LinearGradient(
                colors: [.clear, .black],
                startPoint: .center,
                endPoint: .bottom
            )
        }
        .ignoresSafeArea()
    }

    private var hero: some View {
        VStack(spacing: 16) {
            Image("LaunchLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 96, height: 96)
                .shadow(color: .black.opacity(0.4), radius: 24, y: 8)
                .accessibilityHidden(true)

            VStack(spacing: 8) {
                Text("Highlight Bot Pro")
                    .font(.largeTitle.weight(.bold))
                Text("Turn the moments you saved into a highlight reel.")
                    .font(.body)
                    .foregroundStyle(.white.opacity(0.7))
                    .multilineTextAlignment(.center)
            }
        }
        .foregroundStyle(.white)
    }

    private var features: some View {
        VStack(alignment: .leading, spacing: 20) {
            PaywallFeatureRow(
                systemImage: "film.stack",
                tint: .yellow,
                title: "Montage editor",
                detail: "Stitch clips into one video. Drag to reorder and trim each clip."
            )
            PaywallFeatureRow(
                systemImage: "tortoise.fill",
                tint: .green,
                title: "Slow-mo",
                detail: "Slow the big moment to 50%, 25%, or 15% speed, or replay it in slow motion after the clip."
            )
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(.white.opacity(0.08))
        }
    }

    private func footer(_ store: SubscriptionStore) -> some View {
        VStack(spacing: 12) {
            if let message {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.85))
                    .multilineTextAlignment(.center)
                    .transition(.opacity)
            }

            subscribeButton(store)

            Text(termsText(for: store.product))
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.5))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 16) {
                Button(isRestoring ? "Restoring…" : "Restore Purchases") {
                    Task { await restore(store) }
                }
                .disabled(isRestoring || isPurchasing)
                Link("Terms of Use", destination: Links.termsOfUse)
                if let privacyPolicy = Links.privacyPolicy {
                    Link("Privacy Policy", destination: privacyPolicy)
                }
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white.opacity(0.7))
        }
        .padding(.horizontal, 24)
        .padding(.top, 16)
        .padding(.bottom, 8)
        .background(.black.opacity(0.85))
        .animation(.easeInOut(duration: 0.2), value: message)
    }

    @ViewBuilder
    private func subscribeButton(_ store: SubscriptionStore) -> some View {
        let isBusy = isPurchasing || store.loadState == .loading
        Button {
            if store.loadState == .failed {
                Task { await store.loadProduct() }
            } else if let product = store.product {
                Task { await buy(product, store: store) }
            }
        } label: {
            ZStack {
                if isBusy {
                    ProgressView()
                        .tint(.white)
                } else {
                    Text(buttonTitle(for: store))
                        .font(.headline)
                }
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 56)
            .background(
                LinearGradient(
                    colors: [AppPalette.accent, Color(red: 0.45, green: 0.30, blue: 0.95)],
                    startPoint: .leading,
                    endPoint: .trailing
                ),
                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .disabled(isBusy || isRestoring || (store.product == nil && store.loadState != .failed))
    }

    private var closeButton: some View {
        Button {
            dismiss()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.white.opacity(0.8))
                .frame(width: 32, height: 32)
                .background(.white.opacity(0.12), in: Circle())
        }
        .buttonStyle(.plain)
        .padding(16)
        .disabled(isPurchasing)
        .accessibilityLabel("Close")
    }

    // MARK: - Text

    private func buttonTitle(for store: SubscriptionStore) -> String {
        if store.loadState == .failed { return "Try Again" }
        guard let product = store.product else { return "Subscribe" }
        return "Subscribe for \(Self.priceText(for: product))"
    }

    private func termsText(for product: Product?) -> String {
        if product == nil, container.subscriptions.loadState == .failed {
            return "Couldn't reach the App Store. Check your connection and try again."
        }
        let price = product.map { Self.priceText(for: $0) } ?? "the listed price"
        return "\(price), billed to your Apple Account. Renews automatically unless cancelled at least 24 hours before the end of the period. Cancel anytime in Settings."
    }

    /// "$4.99/month", or "$12.99 every 3 months" for multi-unit periods.
    private static func priceText(for product: Product) -> String {
        guard let period = product.subscription?.subscriptionPeriod else { return product.displayPrice }
        let unit: String = switch period.unit {
        case .day: "day"
        case .week: "week"
        case .month: "month"
        case .year: "year"
        @unknown default: "period"
        }
        return period.value == 1
            ? "\(product.displayPrice)/\(unit)"
            : "\(product.displayPrice) every \(period.value) \(unit)s"
    }

    // MARK: - Actions

    private func buy(_ product: Product, store: SubscriptionStore) async {
        isPurchasing = true
        message = nil
        defer { isPurchasing = false }
        do {
            let result = try await purchase(product)
            switch try await store.complete(result) {
            case .purchased:
                if !store.isSubscribed {
                    message = "Your purchase went through, but Pro didn't unlock. Tap Restore Purchases to try again."
                }
            case .cancelled:
                break
            case .pending:
                message = "Your purchase is waiting for approval. Pro unlocks as soon as it goes through."
            }
        } catch {
            message = error.localizedDescription
        }
    }

    private func restore(_ store: SubscriptionStore) async {
        isRestoring = true
        message = nil
        defer { isRestoring = false }
        do {
            if try await !store.restore() {
                message = "No active Highlight Bot Pro subscription was found for this Apple Account."
            }
        } catch {
            if case StoreKitError.userCancelled = error { return }
            message = error.localizedDescription
        }
    }
}

private struct PaywallFeatureRow: View {
    let systemImage: String
    let tint: Color
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: systemImage)
                .font(.title3.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 44, height: 44)
                .background(tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.white)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.65))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Marks a control that opens the paywall instead of acting.
struct ProBadge: View {
    var body: some View {
        Text("PRO")
            .font(.system(size: 10, weight: .heavy))
            .kerning(0.5)
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(AppPalette.accent, in: Capsule())
            .accessibilityLabel("Requires Highlight Bot Pro")
    }
}
