import Foundation

/// Asks for an App Store rating right after the first film or episode that ran (almost) to the end – the moment someone
/// has seen Jelly work with their own server –, at most once per app version; the system itself shows the request at
/// most three times a year.
enum ReviewPrompt {
    private static let watchedKey = "watchedToEnd"
    private static let askedVersionKey = "reviewAskedVersion"
    /// The player that just closed ran to the end; reset by every playback.
    nonisolated(unsafe) private static var lastFinished = false

    static func notePlayback(fraction: Double, ended: Bool) {
        lastFinished = ended || fraction >= 0.85
        guard lastFinished else { return }
        UserDefaults.standard.set(UserDefaults.standard.integer(forKey: watchedKey) + 1, forKey: watchedKey)
    }

    /// Whether to ask now; remembers the version it asked in. The Apple TV has no system request, so Jelly shows its own
    /// page there – only once ever, not with every update.
    static func shouldAsk() -> Bool {
        let defaults = UserDefaults.standard
        #if os(tvOS)
        let asked = defaults.string(forKey: askedVersionKey) != nil
        #else
        let asked = defaults.string(forKey: askedVersionKey) == JellyfinClient.version
        #endif
        guard lastFinished, defaults.integer(forKey: watchedKey) >= 1, !asked else { return false }
        defaults.set(JellyfinClient.version, forKey: askedVersionKey)
        return true
    }
}
