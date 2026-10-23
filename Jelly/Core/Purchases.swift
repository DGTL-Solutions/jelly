import Foundation
import StoreKit

/// The App Store version's trial and one-time purchase, through StoreKit 2. The trial is a free non-consumable
/// ("14-Tage-Test") whose purchase date starts it – Apple's prescribed way to offer a trial without a subscription
/// (App Review Guideline 3.1.1) –, the full version a non-consumable for 9,99 €. Both belong to the Apple ID, so
/// reinstalling doesn't restart the trial and every Apple TV of the household is unlocked by one purchase.
@MainActor
final class Purchases: ObservableObject {
    @Published private(set) var access: Access
    @Published private(set) var fullProduct: Product?
    @Published private(set) var trialProduct: Product?
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

    private let fullID: String
    private let trialID: String
    private var updates: Task<Void, Never>?

    /// Shown until the App Store answers with the local price.
    var price: String { fullProduct?.displayPrice ?? "9,99 €" }

    var isActive: Bool { Self.isEnforced || forcedForTesting }
    private var forcedForTesting = false

    init(bundleID: String = Bundle.main.bundleIdentifier ?? "net.dgtl24.jelly") {
        fullID = "\(bundleID).full"
        trialID = "\(bundleID).trial14"
        access = Self.isEnforced ? .checking : .unlocked
        #if DEBUG
        // Screens and review screenshots of every state, without App Store products: none, trial, expired, unlocked.
        if let forced = ProcessInfo.processInfo.environment["JELLY_ACCESS"] {
            forcedForTesting = true
            access = ["none": .notStarted, "trial": .trial(daysLeft: 9), "expired": .expired][forced] ?? .unlocked
            return
        }
        #endif
        guard Self.isEnforced else { return }
        updates = Task { [weak self] in
            // Purchases finished elsewhere (another Apple TV, Ask to Buy, a refund) arrive here.
            for await update in Transaction.updates {
                if case .verified(let transaction) = update { await transaction.finish() }
                await self?.refresh()
            }
        }
        Task { await load() }
    }

    func load() async {
        if let products = try? await Product.products(for: [fullID, trialID]) {
            fullProduct = products.first { $0.id == fullID }
            trialProduct = products.first { $0.id == trialID }
        }
        await refresh()
    }

    /// Reads the purchases Apple has verified for this Apple ID; refunded ones no longer count.
    func refresh() async {
        guard isActive, !forcedForTesting else { return }
        var trialStart: Date?
        var purchased = false
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result, transaction.revocationDate == nil else { continue }
            if transaction.productID == fullID { purchased = true }
            if transaction.productID == trialID { trialStart = transaction.originalPurchaseDate }
        }
        access = Access.state(trialStart: trialStart, purchased: purchased)
    }

    func startTrial() async { await buy(trialProduct) }

    func buyFullVersion() async { await buy(fullProduct) }

    private func buy(_ product: Product?) async {
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
                message = "Der Kauf wartet noch auf eine Bestätigung, zum Beispiel aus der Familienfreigabe."
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
        if access != .unlocked { message = "Für diese Apple-ID ist noch keine Vollversion gekauft." }
    }
}
