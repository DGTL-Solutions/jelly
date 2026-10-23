import Foundation
import StoreKit

/// The App Store version's yearly subscription (9,99 € a year, auto-renewing) with two free weeks as its introductory
/// offer, through StoreKit 2. It belongs to the Apple ID: one subscription unlocks every Apple TV of the household,
/// reinstalling doesn't restart the trial, and cancelling happens in the Apple TV's own settings.
@MainActor
final class Purchases: ObservableObject {
    @Published private(set) var access: Access
    @Published private(set) var product: Product?
    /// The Apple ID hasn't used the subscription's free trial yet.
    @Published private(set) var trialAvailable = true
    @Published private(set) var busy = false
    @Published var message: String?

    /// Only the App Store build sells; a build from source plays without limits.
    static let isEnforced: Bool = {
        #if APPSTORE
        return true
        #else
        return false
        #endif
    }()

    let productID: String
    private var updates: Task<Void, Never>?
    private var forcedForTesting = false

    var isActive: Bool { Self.isEnforced || forcedForTesting }

    /// Shown until the App Store answers with the local price.
    var price: String { product?.displayPrice ?? "9,99 €" }

    init(bundleID: String = Bundle.main.bundleIdentifier ?? "net.dgtl24.jelly") {
        productID = "\(bundleID).yearly"
        access = Self.isEnforced ? .checking : .unlocked
        #if DEBUG
        // Screens and review screenshots of every state, without App Store products: none, trial, active, expired.
        if let forced = ProcessInfo.processInfo.environment["JELLY_ACCESS"] {
            forcedForTesting = true
            access = ["none": .notSubscribed, "trial": .trial(daysLeft: 9), "active": .subscribed, "expired": .expired][forced] ?? .unlocked
            trialAvailable = forced == "none"
            return
        }
        #endif
        guard Self.isEnforced else { return }
        updates = Task { [weak self] in
            // Renewals, cancellations, refunds and purchases from other devices or Ask to Buy arrive here.
            for await update in Transaction.updates {
                if case .verified(let transaction) = update { await transaction.finish() }
                await self?.refresh()
            }
        }
        Task { await load() }
    }

    func load() async {
        if let products = try? await Product.products(for: [productID]) { product = products.first }
        await refresh()
    }

    /// Reads what Apple has verified for this Apple ID: an active subscription (refunded or revoked ones don't count),
    /// whether its current period is the free trial, and whether the trial is still available.
    func refresh() async {
        guard isActive, !forcedForTesting else { return }
        var entitled = false
        var trialEnds: Date?
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result, transaction.productID == productID, transaction.revocationDate == nil
            else { continue }
            entitled = true
            if transaction.offer?.type == .introductory { trialEnds = transaction.expirationDate }
        }
        var eligible = true
        if let subscription = product?.subscription {
            eligible = await subscription.isEligibleForIntroOffer
        } else {
            // Without the product (App Store unreachable), any earlier transaction means the trial is used up.
            for await result in Transaction.all {
                if case .verified(let transaction) = result, transaction.productID == productID { eligible = false; break }
            }
        }
        // The free weeks are offered as long as Apple says this Apple ID may still take them.
        trialAvailable = eligible && (product == nil || product?.subscription?.introductoryOffer?.paymentMode == .freeTrial)
        access = Access.state(entitled: entitled, trialEnds: trialEnds, everSubscribed: !eligible)
    }

    func subscribe() async {
        message = nil
        guard let product else {
            message = "Der App Store ist gerade nicht erreichbar. Bitte versuch es gleich noch einmal."
            if isActive, !forcedForTesting { await load() }
            return
        }
        busy = true
        defer { busy = false }
        do {
            switch try await product.purchase() {
            case .success(let result):
                if case .verified(let transaction) = result { await transaction.finish() }
                await refresh()
            case .pending:
                message = "Das Abo wartet noch auf eine Bestätigung, zum Beispiel aus der Familienfreigabe."
            case .userCancelled:
                break
            @unknown default:
                break
            }
        } catch {
            message = error.localizedDescription
        }
    }

    /// Asks the App Store for this Apple ID's purchases again, e.g. on a new Apple TV.
    func restore() async {
        message = nil
        busy = true
        defer { busy = false }
        try? await AppStore.sync()
        await refresh()
        if !access.isActive { message = "Für diese Apple-ID ist kein aktives Abo gespeichert." }
    }
}
