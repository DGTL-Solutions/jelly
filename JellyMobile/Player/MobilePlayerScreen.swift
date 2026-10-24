import SwiftUI

// Placeholder – replaced by the player work package.
struct MobilePlayerScreen: View {
    let request: PlaybackRequest
    let client: JellyfinClient
    let userID: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Button("Schließen") { dismiss() }
    }
}
