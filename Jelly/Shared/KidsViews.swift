import SwiftUI

/// A four-digit PIN pad that works with touch and with the Apple TV remote.
struct PINPad: View {
    let title: String
    var subtitle: String?
    /// Returns whether the PIN was accepted; a refusal shakes the dots and starts over.
    let onComplete: (String) -> Bool
    var onCancel: (() -> Void)?
    @State private var digits = ""
    @State private var shake = 0

    #if os(tvOS)
    private let keySize: CGFloat = 110, spacing: CGFloat = 24
    #else
    private let keySize: CGFloat = 78, spacing: CGFloat = 16
    #endif

    var body: some View {
        VStack(spacing: 28) {
            Text(title).font(.title2.bold()).multilineTextAlignment(.center)
            if let subtitle { Text(subtitle).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center) }
            HStack(spacing: 18) {
                ForEach(0..<4, id: \.self) { index in
                    Circle().fill(index < digits.count ? Color.primary : Color.primary.opacity(0.2)).frame(width: 22, height: 22)
                }
            }
            .modifier(Shake(amount: CGFloat(shake)))
            VStack(spacing: spacing) {
                ForEach([[1, 2, 3], [4, 5, 6], [7, 8, 9]], id: \.self) { row in
                    HStack(spacing: spacing) { ForEach(row, id: \.self) { key(String($0)) } }
                }
                HStack(spacing: spacing) {
                    if let onCancel {
                        Button(action: onCancel) { label("xmark") }.accessibilityLabel(Text("Abbrechen"))
                    } else {
                        Color.clear.frame(width: keySize, height: keySize)
                    }
                    key("0")
                    Button { digits = String(digits.dropLast()) } label: { label("delete.left") }
                        .accessibilityLabel(Text("Löschen"))
                }
            }
            #if !os(tvOS)
            .buttonStyle(.plain)
            #endif
        }
        .padding(30)
    }

    private func label(_ symbol: String) -> some View {
        Image(systemName: symbol).font(.title2).frame(width: keySize, height: keySize)
            .background(.white.opacity(0.08), in: Circle())
    }

    private func key(_ digit: String) -> some View {
        Button { press(digit) } label: {
            Text(digit).font(.system(size: keySize * 0.4, weight: .medium, design: .rounded))
                .frame(width: keySize, height: keySize).background(.white.opacity(0.08), in: Circle())
        }
    }

    private func press(_ digit: String) {
        guard digits.count < 4 else { return }
        digits += digit
        guard digits.count == 4 else { return }
        let entered = digits
        Task {
            try? await Task.sleep(for: .milliseconds(120))
            if !onComplete(entered) {
                withAnimation(.linear(duration: 0.4)) { shake += 1 }
                digits = ""
            }
        }
    }
}

private struct Shake: GeometryEffect {
    var amount: CGFloat
    var animatableData: CGFloat { get { amount } set { amount = newValue } }
    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: 12 * sin(amount * .pi * 4), y: 0))
    }
}

/// Asks for the PIN whenever something on a kids profile needs a parent.
struct ParentGate: ViewModifier {
    @EnvironmentObject private var model: AppModel

    func body(content: Content) -> some View {
        content.fullScreenCover(isPresented: Binding(get: { model.parentAction != nil }, set: { if !$0 { model.parentCancelled() } })) {
            ZStack {
                Theme.background.ignoresSafeArea()
                PINPad(title: String(localized: "PIN der Eltern"), subtitle: String(localized: "Für diese Aktion braucht es den PIN."),
                       onComplete: { pin in
                    guard KidsPIN.matches(pin) else { return false }
                    model.parentApproved()
                    return true
                }, onCancel: { model.parentCancelled() })
            }
        }
    }
}

extension View {
    func parentGate() -> some View { modifier(ParentGate()) }
}

/// Setting up a kids profile: the age limit from the server's own rating list, then the parents' PIN (twice).
struct KidsSetupView: View {
    let onClose: () -> Void
    @EnvironmentObject private var model: AppModel
    @State private var ratings: [ParentalRating] = []
    @State private var rating: String?
    @State private var firstPIN: String?
    @State private var loaded = false

    var body: some View {
        NavigationStack {
            Group {
                if let rating {
                    if KidsPIN.isSet {
                        // A PIN from another kids profile is reused after one confirmation.
                        PINPad(title: String(localized: "Bestehenden PIN eingeben"), subtitle: String(localized: "Dieselbe PIN gilt für alle Kinderprofile auf diesem Gerät."),
                               onComplete: { pin in
                            guard KidsPIN.matches(pin) else { return false }
                            finish(rating, pin)
                            return true
                        }, onCancel: { self.rating = nil })
                    } else if let firstPIN {
                        PINPad(title: String(localized: "PIN wiederholen"), onComplete: { pin in
                            guard pin == firstPIN else { self.firstPIN = nil; return false }
                            finish(rating, pin)
                            return true
                        }, onCancel: { self.firstPIN = nil })
                    } else {
                        PINPad(title: String(localized: "PIN für Eltern wählen"), subtitle: String(localized: "Mit diesem PIN lassen sich Einstellungen, andere Profile und Erkunden öffnen."),
                               onComplete: { pin in firstPIN = pin; return true }, onCancel: { self.rating = nil })
                    }
                } else if !loaded {
                    ProgressView()
                } else {
                    List {
                        Section {
                            ForEach(ratings) { item in
                                Button(item.name) { rating = item.name }
                            }
                        } header: { Text("Höchste Altersfreigabe") } footer: {
                            Text("Das Kinderprofil zeigt nur Filme und Serien bis zu dieser Freigabe.")
                        }
                    }
                }
            }
            .navigationTitle("Kinderprofil")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Abbrechen", action: onClose) } }
        }
        .task {
            ratings = Self.usable(((try? await model.client?.parentalRatings()) ?? []))
            loaded = true
        }
    }

    /// One entry per level, from the lowest up – the server lists ratings of many countries.
    private static func usable(_ all: [ParentalRating]) -> [ParentalRating] {
        let rated = all.filter { ($0.value ?? -1) >= 0 }.sorted { ($0.value ?? 0, $0.name) < ($1.value ?? 0, $1.name) }
        return rated
    }

    private func finish(_ rating: String, _ pin: String) {
        model.enableKids(rating: rating, pin: pin)
        onClose()
    }
}

/// On a kids profile, content that needs a parent: asks for the PIN first and closes again when the tab is left.
struct ParentLocked<Content: View>: View {
    @EnvironmentObject private var model: AppModel
    @State private var unlocked = false
    @ViewBuilder let content: Content

    var body: some View {
        if !model.isKids || unlocked {
            content.onDisappear { unlocked = false }
        } else {
            VStack(spacing: 30) {
                Image(systemName: "lock.fill").font(.system(size: 64)).foregroundStyle(.secondary)
                Text("Nur für Eltern").font(.title2.bold())
                Button("Mit PIN öffnen") { model.requireParent { unlocked = true } }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
