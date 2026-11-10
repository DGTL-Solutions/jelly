#if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
import ActivityKit
import Foundation

/// The download Live Activity: what is being saved and how far it is, on the lock screen and in the Dynamic Island.
struct DownloadActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// The title being saved, or the first of several.
        var title: String
        /// How many titles are still on their way.
        var remaining: Int
        var progress: Double
        var finished: Bool
    }
}
#endif
