import AVFoundation
import SwiftUI

/// Optional: a series' or film's theme song plays quietly while its page is open (Jellyfin's "theme songs").
@MainActor
final class ThemeMusic {
    static let shared = ThemeMusic()
    static let settingKey = "themeMusic"

    private var player: AVPlayer?
    private var owner: String?
    private var fade: Task<Void, Never>?
    private static let volume: Float = 0.25

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: settingKey) }

    func start(for item: BaseItem, client: JellyfinClient, user: String) async {
        guard Self.isEnabled, owner != item.id else { return }
        // An episode's page plays its series' song.
        let id = item.seriesId ?? item.id
        guard let song = try? await client.themeSongs(user: user, itemID: id).first, !Task.isCancelled else { return }
        stop(fading: false)
        owner = item.id
        #if os(iOS)
        // Quiet background music: follows the silent switch and doesn't stop the viewer's own music app for good.
        try? AVAudioSession.sharedInstance().setCategory(.ambient)
        #endif
        let asset = AVURLAsset(url: client.themeSongURL(id: song.id, user: user), options: ["AVURLAssetHTTPHeaderFieldsKey": ["Authorization": client.authorization]])
        let player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
        player.volume = 0
        player.play()
        self.player = player
        ramp(to: Self.volume, over: 2)
    }

    /// Leaving the page, or starting the film.
    func stop(for item: BaseItem? = nil, fading: Bool = true) {
        if let item, owner != item.id { return }
        owner = nil
        guard let player else { return }
        self.player = nil
        fade?.cancel()
        guard fading else { player.pause(); return }
        Task {
            for step in stride(from: player.volume, through: 0, by: -0.025) {
                player.volume = step
                try? await Task.sleep(for: .milliseconds(40))
            }
            player.pause()
        }
    }

    private func ramp(to target: Float, over seconds: Double) {
        fade?.cancel()
        fade = Task { [weak player] in
            let steps = 20
            for step in 1...steps {
                try? await Task.sleep(for: .seconds(seconds / Double(steps)))
                guard !Task.isCancelled else { return }
                player?.volume = target * Float(step) / Float(steps)
            }
        }
    }
}

extension JellyfinClient {
    func themeSongs(user: String, itemID: String) async throws -> [BaseItem] {
        let page: ItemsResponse = try await get("Items/\(itemID)/ThemeSongs", query: ["userId": user, "InheritFromParent": "true"])
        return page.items
    }

    /// The song as it is where Apple's player can read it, otherwise as AAC from the server.
    func themeSongURL(id: String, user: String) -> URL {
        url("Audio/\(id)/universal", query: [
            "UserId": user, "DeviceId": deviceID, "Container": "mp3,aac,m4a|aac,m4a|alac,flac,wav", "TranscodingContainer": "ts",
            "TranscodingProtocol": "hls", "AudioCodec": "aac", "MaxStreamingBitrate": "320000"
        ])
    }
}

private struct ThemeMusicModifier: ViewModifier {
    let item: BaseItem
    @EnvironmentObject private var model: AppModel

    func body(content: Content) -> some View {
        content
            .task(id: model.playback == nil) {
                guard model.playback == nil, let client = model.client, let session = model.session else { return }
                await ThemeMusic.shared.start(for: item, client: client, user: session.userID)
            }
            .onChange(of: model.playback?.id) { _, id in if id != nil { ThemeMusic.shared.stop() } }
            .onDisappear { ThemeMusic.shared.stop(for: item) }
    }
}

extension View {
    /// Plays the title's theme song while this page is open, if the viewer switched that on.
    func themeMusic(for item: BaseItem) -> some View { modifier(ThemeMusicModifier(item: item)) }
}
