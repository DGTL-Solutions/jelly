import Foundation

/// Watching together: someone else decides when the film runs – a SyncPlay group on the server or a SharePlay session.
/// The player asks before it acts on the viewer's presses and reports when it is ready or has to buffer.
@MainActor
protocol PlaybackCoordinator: AnyObject {
    /// `true`: the coordinator passes the wish on to everyone, and the player waits for what comes back.
    func viewerWantsPlay(_ player: PlayerController) -> Bool
    func viewerWantsPause(_ player: PlayerController) -> Bool
    func viewerWantsSeek(_ player: PlayerController, to seconds: Double) -> Bool
    /// The stream is loaded and could play from `player.position`.
    func playerIsReady(_ player: PlayerController)
    /// The line can't keep up.
    func playerIsBuffering(_ player: PlayerController)
    func playerClosed(_ player: PlayerController)
}

/// What is playing on this device right now, for remote control and watching together.
@MainActor
final class PlaybackHub {
    static let shared = PlaybackHub()
    weak var player: PlayerController?
    /// SharePlay wins over a SyncPlay group while a FaceTime session runs.
    var coordinators: [() -> PlaybackCoordinator?] = []
    var coordinator: PlaybackCoordinator? { coordinators.lazy.compactMap { $0() }.first }
}
