import CryptoKit
import Foundation

/// Kids profile: a profile on this device can be limited to an age rating and locked behind a PIN. Settings, other
/// profiles, "Erkunden" and signing out then need the PIN. The server's own age limit for the user applies on top.
struct ParentalRating: Decodable, Hashable, Identifiable {
    let name: String
    var value: Int?
    var id: String { name }
}

enum KidsPIN {
    private static let account = "kids-pin"

    static var isSet: Bool { SecureStore.data(for: account) != nil }

    static func set(_ pin: String) {
        SecureStore.setData(Data(hash(pin)), for: account)
    }

    static func clear() { SecureStore.setData(nil, for: account) }

    static func matches(_ pin: String) -> Bool {
        guard let stored = SecureStore.data(for: account) else { return false }
        return stored == Data(hash(pin))
    }

    /// The rating limit lives in the keychain, so the Top Shelf extension applies it too.
    static func rating(for session: Session?) -> String? {
        session.flatMap { SecureStore.data(for: "kids-rating:\($0.key)") }.flatMap { String(data: $0, encoding: .utf8) }
    }

    static func setRating(_ rating: String?, for session: Session) {
        SecureStore.setData(rating.map { Data($0.utf8) }, for: "kids-rating:\(session.key)")
        // Without any kids profile left the PIN is not needed any more.
        if rating == nil, !hasKidsProfile(except: session) { clear() }
    }

    private static func hasKidsProfile(except session: Session) -> Bool {
        SecureStore.load(fallbackDeviceID: "").accounts.contains { $0.key != session.key && rating(for: $0) != nil }
    }

    private static func hash(_ pin: String) -> SHA256.Digest {
        SHA256.hash(data: Data(("jelly-kids:" + pin).utf8))
    }
}
