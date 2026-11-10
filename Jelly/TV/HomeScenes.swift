import HomeKit
import SwiftUI

/// Optional home-cinema scenes: when a film starts, pauses or ends, a HomeKit scene runs – lights down, lights up.
/// Scenes are made in Apple's Home app; Jelly only runs them.
@MainActor
final class HomeScenes: NSObject, ObservableObject, HMHomeManagerDelegate {
    static let shared = HomeScenes()
    static let settingKey = "homeScenes"

    enum Moment: String, CaseIterable, Identifiable {
        case play, pause, end
        var id: String { rawValue }
        var key: String { "homeScene.\(rawValue)" }
        var title: String {
            switch self {
            case .play: return String(localized: "Wenn der Film läuft")
            case .pause: return String(localized: "Bei Pause")
            case .end: return String(localized: "Nach dem Film")
            }
        }
    }

    struct Scene: Identifiable, Hashable {
        let id: String
        let name: String
    }

    /// All scenes of all homes; empty until HomeKit answered (or was refused).
    @Published private(set) var scenes: [Scene] = []
    @Published private(set) var denied = false
    private var manager: HMHomeManager?
    private var last: Moment?

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: settingKey) }

    /// Asks HomeKit for the homes; the first time, tvOS asks the viewer for permission.
    func load() {
        guard manager == nil else { return }
        let manager = HMHomeManager()
        manager.delegate = self
        self.manager = manager
    }

    nonisolated func homeManagerDidUpdateHomes(_ manager: HMHomeManager) {
        Task { @MainActor in
            let several = manager.homes.count > 1
            scenes = manager.homes.flatMap { home in
                home.actionSets.filter { !$0.actions.isEmpty }.map {
                    Scene(id: $0.uniqueIdentifier.uuidString, name: several ? "\(home.name) · \($0.name)" : $0.name)
                }
            }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            denied = manager.authorizationStatus.contains(.determined) && !manager.authorizationStatus.contains(.authorized)
        }
    }

    func name(of id: String) -> String {
        id.isEmpty ? String(localized: "Keine Szene") : scenes.first { $0.id == id }?.name ?? String(localized: "Szene nicht gefunden")
    }

    /// Runs the scene chosen for this moment, once per change.
    func run(_ moment: Moment) {
        guard Self.isEnabled, moment != last else { return }
        last = moment
        guard let id = UserDefaults.standard.string(forKey: moment.key), !id.isEmpty else { return }
        load()
        guard let manager else { return }
        for home in manager.homes {
            guard let scene = home.actionSets.first(where: { $0.uniqueIdentifier.uuidString == id }) else { continue }
            home.executeActionSet(scene) { error in
                Diagnostics.log("home scene \(moment.rawValue): \(error.map { "\($0)" } ?? "ok")")
            }
            return
        }
    }

    /// A new film may run the "play" scene again.
    func reset() { last = nil }
}

/// Settings: which scene runs when.
struct HomeScenesSettings: View {
    @AppStorage(HomeScenes.settingKey) private var enabled = false
    @AppStorage(HomeScenes.Moment.play.key) private var play = ""
    @AppStorage(HomeScenes.Moment.pause.key) private var pause = ""
    @AppStorage(HomeScenes.Moment.end.key) private var end = ""
    @ObservedObject private var scenes = HomeScenes.shared

    var body: some View {
        SettingsSection(String(localized: "Heimkino-Szenen"), footer: footer) {
            SettingsToggle(String(localized: "HomeKit-Szenen bei der Wiedergabe"), isOn: $enabled)
            if enabled, !scenes.scenes.isEmpty {
                choice(.play, $play)
                choice(.pause, $pause)
                choice(.end, $end)
            }
        }
        .onChange(of: enabled, initial: true) { _, on in if on { scenes.load() } }
    }

    private var footer: String {
        if enabled, scenes.denied { return String(localized: "Jelly darf nicht auf dein Zuhause zugreifen. Erlaube es in den Apple-TV-Einstellungen unter Datenschutz › HomeKit.") }
        if enabled, scenes.scenes.isEmpty { return String(localized: "Noch keine Szenen gefunden. Lege in der Home-App auf dem iPhone Szenen an, zum Beispiel „Filmabend“.") }
        return String(localized: "Dimmt das Licht, wenn der Film läuft, und macht es bei Pause wieder heller. Die Szenen legst du in Apples Home-App an.")
    }

    private func choice(_ moment: HomeScenes.Moment, _ selection: Binding<String>) -> some View {
        SettingsChoice(moment.title, selection: selection, options: [""] + scenes.scenes.map(\.id)) { scenes.name(of: $0) }
    }
}
