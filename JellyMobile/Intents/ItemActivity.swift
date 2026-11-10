import CoreSpotlight
import Foundation

/// The title whose page is open, as the system knows it: for Handoff to another device and for Spotlight.
enum ItemActivity {
    static let type = "de.jelly.item"

    static func fill(_ activity: NSUserActivity, item: BaseItem, serverID: String?) {
        activity.title = item.isEpisode ? [item.seriesName, item.name].compactMap { $0 }.joined(separator: " – ") : item.name
        activity.userInfo = ["id": item.id, "server": serverID ?? ""]
        activity.requiredUserInfoKeys = ["id"]
        activity.isEligibleForHandoff = true
        activity.isEligibleForSearch = true
        activity.targetContentIdentifier = item.id
        let attributes = CSSearchableItemAttributeSet(contentType: .movie)
        attributes.contentDescription = item.overview
        activity.contentAttributeSet = attributes
    }

    static func url(_ activity: NSUserActivity) -> URL? {
        (activity.userInfo?["id"] as? String).flatMap { URL(string: "jelly://item/\($0)") }
    }
}
