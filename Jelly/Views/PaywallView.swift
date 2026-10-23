import SwiftUI

/// The App Store version's offer. Before the trial starts it says how long it lasts, what stops working afterwards and
/// what the full version costs, as App Review asks (Guideline 3.1.1); later it explains the remaining days or the end.
struct PaywallView: View {
    @EnvironmentObject private var purchases: Purchases
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Choice?

    private enum Choice: Hashable { case trial, buy, restore, later }

    var body: some View {
        VStack(spacing: 26) {
            AppMark(size: 100)
            Text(title).font(.system(size: 50, weight: .bold)).multilineTextAlignment(.center)
            // The whole offer has to be readable before the trial starts: never truncated.
            Text(explanation)
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 1150)
            VStack(spacing: 18) {
                if purchases.access == .notStarted {
                    action("\(Access.trialDays) Tage kostenlos testen", icon: "gift", choice: .trial) {
                        await purchases.startTrial()
                    }
                }
                if purchases.access != .unlocked {
                    action("Vollversion kaufen – \(purchases.price)", icon: "lock.open", choice: .buy) {
                        await purchases.buyFullVersion()
                    }
                    action("Käufe wiederherstellen", icon: "arrow.clockwise", choice: .restore) {
                        await purchases.restore()
                    }
                }
                Button { dismiss() } label: {
                    Text(purchases.access.canPlay ? "Fertig" : "Später").frame(width: 640)
                }
                .focused($focused, equals: .later)
            }
            .disabled(purchases.busy)
            Group {
                if purchases.busy {
                    ProgressView()
                } else if let message = purchases.message {
                    Label(message, systemImage: "exclamationmark.circle").foregroundStyle(.orange)
                } else {
                    Text("Einmalig, kein Abo. Bezahlt wird über deine Apple-ID; der Kauf gilt auf allen Apple TVs mit dieser Apple-ID.")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.caption)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(50)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            ZStack {
                Theme.background
                RadialGradient(colors: [Color(red: 0.36, green: 0.22, blue: 0.62).opacity(0.45), .clear], center: .top, startRadius: 20, endRadius: 1200)
            }
            .ignoresSafeArea()
        }
        .defaultFocus($focused, purchases.access == .notStarted ? .trial : purchases.access == .unlocked ? .later : .buy)
        .onChange(of: purchases.access) { _, access in
            // Started the trial or bought: straight back to where the viewer was.
            if access == .unlocked || (access.canPlay && access != .checking) { dismiss() }
        }
    }

    private func action(_ title: String, icon: String, choice: Choice, perform: @escaping () async -> Void) -> some View {
        Button { Task { await perform() } } label: {
            Label(title, systemImage: icon).frame(width: 640)
        }
        .focused($focused, equals: choice)
    }

    private var title: String {
        switch purchases.access {
        case .notStarted, .checking: return "Jelly \(Access.trialDays) Tage kostenlos testen"
        case .trial(let days): return days == 1 ? "Noch 1 Tag Testzeitraum" : "Noch \(days) Tage Testzeitraum"
        case .expired: return "Dein Testzeitraum ist abgelaufen"
        case .unlocked: return "Danke! Jelly ist freigeschaltet"
        }
    }

    private var explanation: String {
        switch purchases.access {
        case .notStarted, .checking:
            return "Probier alle Funktionen \(Access.trialDays) Tage lang kostenlos aus. Danach schaltest du die Vollversion mit einem einmaligen Kauf für \(purchases.price) frei – kein Abo. Ohne Vollversion spielt Jelly nach dem Test keine Filme und Serien mehr ab; deine Bibliothek und die Einstellungen bleiben erreichbar."
        case .trial:
            return "Bis zum Ende des Tests kannst du alles nutzen. Mit der Vollversion für einmalig \(purchases.price) läuft Jelly danach ohne Unterbrechung weiter – kein Abo."
        case .expired:
            return "Deine Bibliothek bleibt erreichbar, abspielen kannst du mit der Vollversion: einmalig \(purchases.price), kein Abo, für alle Apple TVs mit deiner Apple-ID."
        case .unlocked:
            return "Viel Spaß mit deinen Filmen und Serien."
        }
    }
}
