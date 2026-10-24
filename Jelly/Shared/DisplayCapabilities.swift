import SwiftUI
import AVFoundation

/// What the connected display can show and whether the system switches its mode to match the content.
struct DisplayCapabilities {
    var matchingEnabled: Bool
    var hdrFormats: [String]

    @MainActor
    static func current() -> DisplayCapabilities {
        let window = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first
        let modes = AVPlayer.availableHDRModes
        var formats: [String] = []
        if modes.contains(.dolbyVision) { formats.append("Dolby Vision") }
        if modes.contains(.hdr10) { formats.append("HDR10") }
        if modes.contains(.hlg) { formats.append("HLG") }
        #if os(tvOS)
        let matching = window?.avDisplayManager.isDisplayCriteriaMatchingEnabled ?? false
        #else
        // iPhone and iPad switch the panel's mode themselves; there is no "Match Content" to ask for.
        let matching = false
        _ = window
        #endif
        return DisplayCapabilities(matchingEnabled: matching, hdrFormats: formats)
    }
}
