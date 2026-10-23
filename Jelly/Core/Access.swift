import Foundation

/// What the App Store version lets the viewer do: a yearly subscription that starts with two free weeks. Builds from
/// source (without the `APPSTORE` flag) are always unlocked.
enum Access: Equatable {
    /// The App Store's answer is still on its way; playback isn't held up for it.
    case checking
    /// Never subscribed: browsing works, playback offers the free trial.
    case notSubscribed
    /// The free trial of the subscription is running.
    case trial(daysLeft: Int)
    case subscribed
    /// The subscription (or its trial) ended without renewal.
    case expired
    case unlocked

    static let trialDays = 14

    /// `entitled`: StoreKit lists an active subscription (including a billing grace period); `trialEnds`: when that
    /// period ends, if it is the free introductory offer; `everSubscribed`: the Apple ID has used this subscription before.
    static func state(entitled: Bool, trialEnds: Date?, everSubscribed: Bool, now: Date = Date()) -> Access {
        if entitled {
            guard let trialEnds, trialEnds > now else { return .subscribed }
            return .trial(daysLeft: max(1, Int((trialEnds.timeIntervalSince(now) / 86_400).rounded(.up))))
        }
        return everSubscribed ? .expired : .notSubscribed
    }

    var canPlay: Bool {
        switch self {
        case .checking, .trial, .subscribed, .unlocked: return true
        case .notSubscribed, .expired: return false
        }
    }

    var isActive: Bool {
        switch self {
        case .trial, .subscribed: return true
        default: return false
        }
    }
}
