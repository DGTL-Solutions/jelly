import SwiftUI
import StoreKit

/// The App Store version's offer: the yearly subscription with its free weeks. Before anything is bought it states
/// what App Review asks for subscriptions (Guideline 3.1.2): name, length and price per period, the trial and what
/// follows it, automatic renewal and how to cancel, plus links to the terms of use and the privacy policy.
struct MobilePaywall: View {
    @EnvironmentObject private var purchases: Purchases
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var managingSubscription = false

    private var offersPurchase: Bool { !purchases.access.isActive && purchases.access != .unlocked }

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    VStack(spacing: 18) {
                        MobileAppMark(size: sizeClass == .regular ? 132 : 104)
                            .padding(.bottom, 8)
                        Text(title)
                            .font(.largeTitle.bold())
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                        // The whole offer has to be readable before subscribing: never truncated.
                        Text(explanation)
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 32)
                    actions
                    Spacer(minLength: 24)
                    footer
                }
                .frame(maxWidth: 480)
                .padding(.horizontal, 24)
                .padding(.top, 48)
                .padding(.bottom, 20)
                .frame(maxWidth: .infinity, minHeight: proxy.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .background(AccountBackground())
        .onChange(of: purchases.access) { _, access in
            // Subscribed (trial included): straight back to where the viewer was.
            if access.isActive { dismiss() }
        }
        .sensoryFeedback(.success, trigger: purchases.access.isActive) { _, active in active }
        .manageSubscriptionsSheet(isPresented: $managingSubscription)
    }

    private var actions: some View {
        VStack(spacing: 12) {
            if offersPurchase {
                Button { Task { await purchases.subscribe() } } label: {
                    Label(subscribeTitle, systemImage: purchases.trialAvailable ? "gift.fill" : "star.fill")
                        .font(.headline)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity, minHeight: 30)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                Button { Task { await purchases.restore() } } label: {
                    Label("Käufe wiederherstellen", systemImage: "arrow.clockwise").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            } else if purchases.access.isActive {
                Button { managingSubscription = true } label: {
                    Label("Abo verwalten", systemImage: "creditcard").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
            if offersPurchase {
                Button(action: { dismiss() }, label: closeLabel).buttonStyle(.borderless).controlSize(.large)
            } else {
                Button(action: { dismiss() }, label: closeLabel).buttonStyle(.borderedProminent).controlSize(.large)
            }
        }
        .disabled(purchases.busy)
    }

    private func closeLabel() -> some View {
        Text(purchases.access.canPlay ? "Fertig" : "Später").frame(maxWidth: .infinity)
    }

    private var footer: some View {
        VStack(spacing: 14) {
            Group {
                if purchases.busy {
                    ProgressView()
                } else if let message = purchases.message {
                    Label(message, systemImage: "exclamationmark.circle").foregroundStyle(.orange)
                } else {
                    Text("Jelly Jahresabo · 1 Jahr · \(purchases.price) pro Jahr. Bezahlt wird über deine Apple-ID; das Abo gilt auf iPhone, iPad und Apple TV mit dieser Apple-ID. Kündigen: Einstellungen › dein Name › Abonnements.")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.footnote)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 24) {
                if let terms = URL(string: AppInfo.termsURL) { Link("Nutzungsbedingungen", destination: terms) }
                if let privacy = URL(string: AppInfo.localizedPrivacyURL) { Link("Datenschutz", destination: privacy) }
            }
            .font(.footnote.weight(.semibold))
        }
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
