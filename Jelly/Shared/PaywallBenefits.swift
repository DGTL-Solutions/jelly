import SwiftUI

/// What the subscription brings, shown above the offer's button: the reasons to start the trial come before the fine
/// print, which stays complete below the buttons.
struct PaywallBenefits: View {
    var font: Font = .body
    var iconWidth: CGFloat = 30
    var spacing: CGFloat = 14

    private struct Benefit: Identifiable {
        let icon: String
        let text: String
        var id: String { icon }
    }

    private var benefits: [Benefit] {
        var list = [Benefit(icon: "sparkles.tv", text: String(localized: "Originalqualität mit Dolby Vision, HDR10+ und Atmos – ohne Umrechnen"))]
        #if os(iOS)
        list.append(Benefit(icon: "arrow.down.circle", text: String(localized: "Downloads für unterwegs – auch ohne Verbindung")))
        #endif
        list.append(Benefit(icon: "forward.end", text: String(localized: "Intros überspringen, nächste Folge automatisch")))
        list.append(Benefit(icon: "captions.bubble", text: String(localized: "Untertitel wie gestaltet, Jellyseerr eingebaut")))
        list.append(Benefit(icon: "rectangle.on.rectangle", text: String(localized: "Ein Abo für Apple TV, iPhone und iPad")))
        return list
    }

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            ForEach(benefits) { benefit in
                HStack(spacing: 14) {
                    Image(systemName: benefit.icon)
                        .foregroundStyle(Theme.accent)
                        .frame(width: iconWidth)
                        .accessibilityHidden(true)
                    Text(benefit.text).fixedSize(horizontal: false, vertical: true)
                }
                .font(font)
            }
        }
    }
}

extension Purchases {
    /// One line under the title of the offer: price after the trial, and that cancelling is always possible.
    var offerSummary: String {
        trialAvailable
            ? String(localized: "Danach \(price) pro Jahr. Jederzeit kündbar.")
            : String(localized: "Alle Funktionen für \(price) pro Jahr. Jederzeit kündbar.")
    }

    /// The renewal terms App Review asks for, below the buttons.
    var renewalTerms: String {
        String(localized: "Das Abo verlängert sich automatisch um ein Jahr für \(price), wenn du es nicht spätestens 24 Stunden vor Ablauf kündigst.")
            + " " + String(localized: "Ohne Abo spielt Jelly nichts ab; deine Bibliothek und die Einstellungen bleiben erreichbar.")
    }
}
