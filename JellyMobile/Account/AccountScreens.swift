import SwiftUI

// The account package: onboarding (OnboardingFlow.swift), "Wer schaut gerade?" (here), settings (SettingsScreen.swift,
// AboutScreens.swift) and the subscription offer (MobilePaywall.swift). This file holds what they share.

// MARK: - Profile picker

/// "Wer schaut gerade?" – switches between the profiles saved on this device without signing in again.
struct ProfilePickerScreen: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var chosen: String?

    private var avatarSize: CGFloat { sizeClass == .regular ? 132 : 88 }

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(spacing: sizeClass == .regular ? 48 : 32) {
                    MobileAppMark(size: sizeClass == .regular ? 84 : 64)
                    Text("Wer schaut gerade?")
                        .font(.largeTitle.bold())
                        .multilineTextAlignment(.center)
                    AccountTileGrid(count: model.accounts.count + 1, tileWidth: avatarSize + 16, maxColumns: sizeClass == .regular ? 4 : 3) {
                        ForEach(model.accounts, id: \.key) { account in
                            Button {
                                chosen = account.key
                                model.switchTo(account)
                            } label: {
                                AccountProfileTile(user: UserDto(id: account.userID, name: account.name, primaryImageTag: account.imageTag),
                                            server: account.server, size: avatarSize,
                                            caption: model.servers.count > 1 ? account.serverName ?? account.server.host() : nil)
                            }
                            .buttonStyle(AccountPressStyle())
                        }
                        Button { model.addProfile() } label: { AddProfileTile(size: avatarSize) }
                            .buttonStyle(AccountPressStyle())
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 40)
                .frame(maxWidth: .infinity, minHeight: proxy.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .background(AccountBackground())
        .overlay(alignment: .topTrailing) {
            // Opened from the settings: back to the profile that was active.
            if model.session != nil {
                Button("Abbrechen") { withAnimation { model.choosingProfile = false } }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .padding()
            }
        }
        .sensoryFeedback(.selection, trigger: chosen)
        #if DEBUG
        .task {
            switch AccountDebug.take("JELLY_ACCOUNT_ADD") {
            case "profile": model.addProfile()
            case "server": model.addServer()
            default: break
            }
            // JELLY_TAB opens a tab (see MainTabs): continue with the first profile to get there.
            if ProcessInfo.processInfo.environment["JELLY_TAB"] != nil, let first = model.accounts.first {
                model.switchTo(first)
            }
        }
        #endif
    }
}

/// One profile: round avatar with the name below.
struct AccountProfileTile: View {
    let user: UserDto
    let server: URL
    var size: CGFloat = 96
    var caption: String?
    var busy = false

    var body: some View {
        VStack(spacing: 10) {
            AccountAvatar(user: user, server: server, size: size)
                .overlay {
                    if busy {
                        ProgressView().controlSize(.large).frame(width: size, height: size).background(.black.opacity(0.45), in: Circle())
                    }
                }
                .shadow(color: .black.opacity(0.35), radius: 12, y: 6)
            VStack(spacing: 2) {
                Text(user.name).font(.headline).lineLimit(1)
                if let caption { Text(caption).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([user.name, caption].compactMap { $0 }.joined(separator: ", "))
        .accessibilityAddTraits(.isButton)
    }
}

private struct AddProfileTile: View {
    let size: CGFloat

    var body: some View {
        VStack(spacing: 10) {
            Circle()
                .strokeBorder(.white.opacity(0.35), style: StrokeStyle(lineWidth: 2.5, dash: [8, 6]))
                .frame(width: size, height: size)
                .overlay { Image(systemName: "plus").font(.system(size: size * 0.32, weight: .medium)).foregroundStyle(.secondary) }
            Text("Profil hinzufügen").font(.headline).foregroundStyle(.secondary).lineLimit(2).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }
}

/// Profile tiles in centred rows: one profile sits in the middle instead of at the left edge.
struct AccountTileGrid<Content: View>: View {
    let count: Int
    let tileWidth: CGFloat
    var maxColumns = 3
    @ViewBuilder let content: Content

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(tileWidth), spacing: 16, alignment: .top),
                                 count: max(1, min(count, maxColumns))),
                  spacing: 24) {
            content
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Shared pieces

/// Jelly's logo as in the app icon: a flat play button in the brand gradient. `size` is its width.
struct MobileAppMark: View {
    var size: CGFloat = 96

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.2, style: .continuous)
            .fill(Theme.brand)
            .frame(width: size, height: size / 1.42)
            .overlay {
                Image(systemName: "play.fill")
                    .font(.system(size: size * 0.24, weight: .bold))
                    .foregroundStyle(.white)
                    .offset(x: size * 0.012)
            }
            .shadow(color: Color(red: 0.4, green: 0.3, blue: 0.9).opacity(0.4), radius: size * 0.16, y: size * 0.05)
            .accessibilityHidden(true)
    }
}

/// A profile picture from the server, or the initial on a colour that stays the same for each user.
struct AccountAvatar: View {
    let user: UserDto
    let server: URL
    var size: CGFloat = 96
    @EnvironmentObject private var model: AppModel

    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Circle().fill(gradient)
            if let image {
                // Pictures may be transparent (the demo server's logo): the initial stays hidden behind them.
                Image(uiImage: image).resizable().scaledToFill().clipShape(Circle()).transition(.opacity)
            } else {
                Text(user.name.prefix(1).uppercased())
                    .font(.system(size: size * 0.42, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
        .task(id: imageURL) {
            guard let imageURL else { image = nil; return }
            if let cached = ImagePipeline.shared.cached(imageURL) { image = cached; return }
            let loaded = await ImagePipeline.shared.image(imageURL)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.25)) { image = loaded }
        }
    }

    private var imageURL: URL? {
        user.primaryImageTag == nil ? nil
            : model.anonymousClient(server).userImageURL(user: user.id, tag: user.primaryImageTag, width: Int(size * 3))
    }

    private var gradient: LinearGradient {
        let palette: [(Color, Color)] = [
            (Color(red: 0.55, green: 0.36, blue: 0.96), Color(red: 0.25, green: 0.18, blue: 0.62)),
            (Color(red: 0.0, green: 0.62, blue: 0.86), Color(red: 0.0, green: 0.3, blue: 0.55)),
            (Color(red: 0.95, green: 0.45, blue: 0.4), Color(red: 0.6, green: 0.16, blue: 0.3)),
            (Color(red: 0.2, green: 0.75, blue: 0.55), Color(red: 0.05, green: 0.38, blue: 0.35)),
            (Color(red: 0.96, green: 0.68, blue: 0.2), Color(red: 0.7, green: 0.32, blue: 0.1))
        ]
        let seed = user.id.unicodeScalars.reduce(0) { $0 + Int($1.value) }
        let pair = palette[seed % palette.count]
        return LinearGradient(colors: [pair.0, pair.1], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

/// The dark background with Jelly's violet and blue glow, behind onboarding, profiles and the offer.
struct AccountBackground: View {
    var body: some View {
        ZStack {
            Theme.background
            RadialGradient(colors: [Color(red: 0.36, green: 0.22, blue: 0.62).opacity(0.55), .clear],
                           center: .topLeading, startRadius: 20, endRadius: 720)
            RadialGradient(colors: [Color(red: 0.0, green: 0.45, blue: 0.7).opacity(0.3), .clear],
                           center: .bottomTrailing, startRadius: 20, endRadius: 640)
        }
        .ignoresSafeArea()
    }
}

/// Shrinks a little while pressed, for tiles and cards.
struct AccountPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

/// A problem in plain words, under the field or button it belongs to.
struct AccountErrorText: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.callout)
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .transition(.opacity.combined(with: .move(edge: .top)))
    }
}

enum AccountFormat {
    /// "192.168.1.20:8096" or "jellyfin.example.com" – a server address as people type it.
    static func host(_ url: URL) -> String {
        guard let host = url.host(percentEncoded: false) else { return url.absoluteString }
        return url.port.map { "\(host):\($0)" } ?? host
    }
}

/// Keeps forms and lists at a comfortable reading width on a wide iPad screen instead of stretching rows edge to edge.
private struct AccountReadableWidth: ViewModifier {
    var maxWidth: CGFloat = 760
    @State private var width: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .contentMargins(.horizontal, max(0, (width - maxWidth) / 2), for: .scrollContent)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }
}

extension View {
    func accountReadableWidth(_ maxWidth: CGFloat = 760) -> some View { modifier(AccountReadableWidth(maxWidth: maxWidth)) }
}
