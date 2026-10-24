import SwiftUI
import CoreImage.CIFilterBuiltins

/// The App Store version's offer: the yearly subscription with its free weeks. Before anything is bought it states
/// what App Review asks for subscriptions (Guideline 3.1.2): name, length and price per period, the trial and what
/// follows it, automatic renewal and how to cancel, plus the terms of use and the privacy policy.
struct PaywallView: View {
    @EnvironmentObject private var purchases: Purchases
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Choice?
    @State private var document: LegalDocument?

    private enum Choice: Hashable { case subscribe, restore, later, terms, privacy }

    var body: some View {
        VStack(spacing: 28) {
            AppMark(size: 150)
            Text(title).font(.system(size: 50, weight: .bold)).multilineTextAlignment(.center)
            // The whole offer has to be readable before subscribing: never truncated.
            Text(explanation)
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 1250)
            VStack(spacing: 16) {
                if !purchases.access.isActive && purchases.access != .unlocked {
                    Button { Task { await purchases.subscribe() } } label: {
                        Label(subscribeTitle, systemImage: purchases.trialAvailable ? "gift" : "star").frame(width: 720)
                    }
                    .focused($focused, equals: .subscribe)
                    Button { Task { await purchases.restore() } } label: {
                        Label("Käufe wiederherstellen", systemImage: "arrow.clockwise").frame(width: 720)
                    }
                    .focused($focused, equals: .restore)
                }
                Button { dismiss() } label: {
                    Text(purchases.access.canPlay ? "Fertig" : "Später").frame(width: 720)
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
                    Text("Jelly Jahresabo · 1 Jahr · \(purchases.price) pro Jahr. Bezahlt wird über deine Apple-ID; das Abo gilt auf allen Apple TVs mit dieser Apple-ID. Kündigen: Apple-TV-Einstellungen › Benutzer und Accounts › Abonnements.")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.caption)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 1250)
            HStack(spacing: 30) {
                Button("Nutzungsbedingungen") { document = .terms }.focused($focused, equals: .terms)
                Button("Datenschutz") { document = .privacy }.focused($focused, equals: .privacy)
            }
            .font(.caption)
        }
        .padding(60)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            ZStack {
                Theme.background
                RadialGradient(colors: [Color(red: 0.36, green: 0.22, blue: 0.62).opacity(0.45), .clear], center: .top, startRadius: 20, endRadius: 1200)
            }
            .ignoresSafeArea()
        }
        .defaultFocus($focused, purchases.access.isActive || purchases.access == .unlocked ? .later : .subscribe)
        .onChange(of: purchases.access) { _, access in
            // Subscribed (trial included): straight back to where the viewer was.
            if access.isActive { dismiss() }
        }
        .sheet(item: $document) { LegalDocumentView(document: $0) }
    }

    private var subscribeTitle: String {
        purchases.trialAvailable
            ? String(localized: "\(Access.trialDays / 7) Wochen gratis, dann \(purchases.price) pro Jahr")
            : String(localized: "Jahresabo abschließen – \(purchases.price) pro Jahr")
    }

    private var title: String {
        switch purchases.access {
        case .notSubscribed, .checking:
            return purchases.trialAvailable ? String(localized: "Jelly \(Access.trialDays / 7) Wochen kostenlos testen")
                                            : String(localized: "Jelly Jahresabo", comment: "Name of the yearly subscription")
        case .trial(let days): return days == 1 ? String(localized: "Noch 1 Tag kostenlos") : String(localized: "Noch \(days) Tage kostenlos")
        case .subscribed: return String(localized: "Dein Jahresabo ist aktiv")
        case .expired: return String(localized: "Dein Abo ist abgelaufen")
        case .unlocked: return String(localized: "Jelly ist freigeschaltet")
        }
    }

    private var explanation: String {
        let renewal = String(localized: "Das Abo verlängert sich automatisch um ein Jahr für \(purchases.price), wenn du es nicht spätestens 24 Stunden vor Ablauf kündigst.")
        switch purchases.access {
        case .notSubscribed, .checking, .expired:
            let start = purchases.trialAvailable
                ? String(localized: "Probier alle Funktionen \(Access.trialDays / 7) Wochen lang kostenlos aus. Danach kostet das Jelly Jahresabo \(purchases.price) pro Jahr.")
                : String(localized: "Mit dem Jelly Jahresabo für \(purchases.price) pro Jahr spielst du deine Filme und Serien ab.")
            return [start, renewal, String(localized: "Ohne Abo spielt Jelly nichts ab; deine Bibliothek und die Einstellungen bleiben erreichbar.")]
                .joined(separator: " ")
        case .trial:
            let start = String(localized: "Bis zum Ende des Probezeitraums ist alles kostenlos. Danach kostet das Jelly Jahresabo \(purchases.price) pro Jahr.")
            return [start, renewal].joined(separator: " ")
        case .subscribed:
            return renewal
        case .unlocked:
            return String(localized: "Viel Spaß mit deinen Filmen und Serien.")
        }
    }
}

/// Terms of use and privacy policy on a TV without a browser: the address, a QR code for the phone, and for the
/// privacy policy the full text right here.
enum LegalDocument: String, Identifiable {
    case terms, privacy
    var id: String { rawValue }
}

struct LegalDocumentView: View {
    let document: LegalDocument

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(document == .terms ? "Nutzungsbedingungen" : "Datenschutz").font(.title2.weight(.bold))
                HStack(alignment: .top, spacing: 40) {
                    QRCode(text: url).frame(width: 260, height: 260)
                    ScrollableText(document == .terms
                        ? String(localized: "Für Jelly und das Jelly Jahresabo gilt die Standard-Lizenzvereinbarung von Apple für Apps aus dem App Store (EULA). Zum Lesen auf dem Handy den Code scannen oder die Adresse öffnen:\n\n\(url)")
                        : String(localized: "Die Datenschutzerklärung zum Lesen auf dem Handy: Code scannen oder die Adresse öffnen:\n\n\(url)\n\nDas Wichtigste steht auch hier darunter."),
                                   font: .callout)
                }
                if document == .privacy { ScrollableText(PrivacyNoticeView.text, font: .callout) }
            }
            .frame(maxWidth: 1400, alignment: .leading)
            .padding(60)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.background.ignoresSafeArea())
    }

    private var url: String { document == .terms ? AppInfo.termsURL : AppInfo.privacyURL }
}

/// A sharp QR code for an address, so it can be opened on a phone.
struct QRCode: View {
    let text: String

    var body: some View {
        if let image = Self.image(text) {
            Image(decorative: image, scale: 1).interpolation(.none).resizable().scaledToFit()
                .padding(14).background(.white, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    private static func image(_ text: String) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)) else { return nil }
        return CIContext().createCGImage(output, from: output.extent)
    }
}
