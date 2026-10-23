import Foundation

/// What the App Store version lets the viewer do: two weeks to try everything, then a one-time purchase. Builds from
/// source (without the `APPSTORE` flag) are always unlocked.
enum Access: Equatable {
    /// The App Store's answer is still on its way; playback isn't held up for it.
    case checking
    /// No trial yet: browsing works, playback asks to start the trial or buy.
    case notStarted
    case trial(daysLeft: Int)
    case expired
    case unlocked

    static let trialDays = 14

    /// `trialStart` is when the free "14-Tage-Test" was taken, as Apple recorded it; `purchased` the full version.
    static func state(trialStart: Date?, purchased: Bool, now: Date = Date()) -> Access {
        if purchased { return .unlocked }
        guard let trialStart else { return .notStarted }
        let end = trialStart.addingTimeInterval(Double(trialDays) * 86_400)
        guard now < end else { return .expired }
        return .trial(daysLeft: max(1, Int((end.timeIntervalSince(now) / 86_400).rounded(.up))))
    }

    var canPlay: Bool {
        switch self {
        case .checking, .trial, .unlocked: return true
        case .notStarted, .expired: return false
        }
    }
}
