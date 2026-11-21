import SwiftUI

/// "Einschlaf-Timer" in the player's panel: playback pauses after a while, or the title in play is the last one.
/// One timer for the whole app, so it keeps running from one episode into the next; nothing is remembered across launches.
@MainActor
final class SleepTimer: ObservableObject {
    static let shared = SleepTimer()

    enum Choice: Hashable, Identifiable {
        case off, minutes(Int), endOfTitle

        var id: String {
            switch self {
            case .off: "off"
            case .minutes(let minutes): "\(minutes)"
            case .endOfTitle: "end"
            }
        }

        func title(isEpisode: Bool) -> String {
            switch self {
            case .off: String(localized: "Aus", comment: "Sleep timer: off")
            case .minutes(let minutes): String(localized: "\(minutes) Min.", comment: "Sleep timer: after N minutes")
            case .endOfTitle:
                isEpisode ? String(localized: "Ende der Folge", comment: "Sleep timer: stop when this episode ends")
                          : String(localized: "Ende des Films", comment: "Sleep timer: stop when this film ends")
            }
        }
    }

    static let choices: [Choice] = [.off, .minutes(15), .minutes(30), .minutes(45), .minutes(60), .endOfTitle]

    @Published private(set) var choice = Choice.off
    /// When a timer in minutes runs out.
    @Published private(set) var deadline: Date?

    private init() {
        #if DEBUG
        // Simulator testing: JELLY_SLEEP=<seconds> starts with a timer that runs out that soon.
        if let seconds = ProcessInfo.processInfo.environment["JELLY_SLEEP"].flatMap(Double.init) {
            choice = .minutes(1)
            deadline = Date().addingTimeInterval(seconds)
        }
        #endif
    }

    /// The title in play is the last one: no next episode afterwards.
    var stopsAtEnd: Bool { choice == .endOfTitle }

    func set(_ choice: Choice, now: Date = Date()) {
        self.choice = choice
        if case .minutes(let minutes) = choice { deadline = now.addingTimeInterval(Double(minutes) * 60) } else { deadline = nil }
    }

    func clear() { set(.off) }

    /// What the timer will do, for the panel: "Pausiert um 23:15".
    func status(isEpisode: Bool) -> String {
        switch choice {
        case .off: String(localized: "Die Wiedergabe läuft, bis du sie anhältst.")
        case .minutes:
            String(localized: "Die Wiedergabe pausiert um \((deadline ?? Date()).formatted(date: .omitted, time: .shortened)).",
                   comment: "Sleep timer status with the time of day")
        case .endOfTitle:
            isEpisode ? String(localized: "Nach dieser Folge geht es nicht automatisch weiter.") : String(localized: "Nach dem Film schließt der Player.")
        }
    }
}

extension View {
    /// Carries out the sleep timer for the player on screen: pauses when the minutes are up. A timer that ran out
    /// while nothing was playing is just forgotten.
    func sleepTimer(_ timer: SleepTimer, player: PlayerController) -> some View {
        task(id: timer.deadline) {
            guard let deadline = timer.deadline else { return }
            let wait = deadline.timeIntervalSinceNow
            guard wait > 0 else { timer.clear(); return }
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled else { return }
            timer.clear()
            if player.isPlaying {
                player.pause()
                player.notice = String(localized: "Einschlaf-Timer: Wiedergabe pausiert")
                Diagnostics.log("sleep timer paused playback")
            }
        }
    }
}
