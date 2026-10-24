import SwiftUI
import AetherEngine

// MARK: - Subtitles

/// The engine's subtitle cues, laid out like on Apple TV and scaled to this screen: the Apple TV sizes and margins are
/// for a 1080-point-tall picture, so the overlay is drawn on such a canvas and shrunk to the picture here.
struct PlayerSubtitleLayer: View {
    let engine: AetherEngine
    let delay: Double
    let size: SubtitleSize
    let background: SubtitleBackground
    let color: Color
    let lifted: Bool

    var body: some View {
        GeometryReader { proxy in
            let scale = Self.scale(for: proxy.size)
            SubtitleOverlay(engine: engine, clock: engine.clock, delay: delay, size: size.points, background: background,
                            color: color, lifted: lifted)
                .frame(width: proxy.size.width / scale, height: proxy.size.height / scale)
                .scaleEffect(scale, anchor: .topLeading)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// The height a 16:9 picture takes on this screen, relative to 1080.
    static func scale(for size: CGSize) -> CGFloat {
        guard size.width > 0, size.height > 0 else { return 1 }
        return max(0.3, min(size.height, size.width * 9 / 16) / 1080)
    }
}

/// ASS/SSA subtitles from libass, moved and scaled onto the picture as it is shown now – after a rotation or with
/// aspect fill the picture's rectangle differs from the one the renderer started with.
struct PlayerASSLayer: View {
    @ObservedObject var model: ASSOverlayModel
    let fills: Bool

    var body: some View {
        GeometryReader { proxy in
            if let image = model.image, model.videoRect.width > 0, model.videoRect.height > 0 {
                let target = Self.pictureRect(aspect: model.videoRect.width / model.videoRect.height, in: proxy.size, fills: fills)
                let scale = target.width / model.videoRect.width
                Image(decorative: image, scale: 1)
                    .resizable()
                    .frame(width: model.rect.width * scale, height: model.rect.height * scale)
                    .position(x: target.minX + model.rect.midX * scale, y: target.minY + model.rect.midY * scale)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    static func pictureRect(aspect: CGFloat, in size: CGSize, fills: Bool) -> CGRect {
        guard size.width > 0, size.height > 0 else { return .zero }
        let wider = aspect > size.width / size.height
        let fitted = wider != fills ? CGSize(width: size.width, height: size.width / aspect)
                                    : CGSize(width: size.height * aspect, height: size.height)
        return CGRect(x: (size.width - fitted.width) / 2, y: (size.height - fitted.height) / 2, width: fitted.width, height: fitted.height)
    }
}

// MARK: - Buttons over the picture

/// "Intro überspringen" and the credits buttons: a white capsule at the bottom right.
struct PlayerSkipButton: View {
    let title: String
    let systemImage: String
    let lifted: Bool
    let action: () -> Void

    var body: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                Button(action: action) {
                    Label(title, systemImage: systemImage)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 20).padding(.vertical, 12)
                        .background(.white, in: Capsule())
                        .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
                }
                .buttonStyle(PlayerPressStyle())
            }
        }
        .padding(.trailing, 20)
        .padding(.bottom, lifted ? 136 : 28)
        .animation(.easeInOut(duration: 0.25), value: lifted)
    }
}

/// The next episode with a countdown ring; tap to start it now.
struct PlayerUpNextCard: View {
    let episode: BaseItem
    let countdown: Int
    let lifted: Bool
    let play: () -> Void
    let close: () -> Void

    var body: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                HStack(spacing: 12) {
                    Button(action: play) {
                        HStack(spacing: 12) {
                            ArtworkImage(item: episode, style: .landscape, pixelWidth: 480)
                                .frame(width: 128, height: 72)
                                .overlay {
                                    ZStack {
                                        Color.black.opacity(0.3)
                                        Circle().stroke(.white.opacity(0.3), lineWidth: 3).frame(width: 34, height: 34)
                                        Circle().trim(from: 0, to: Double(10 - countdown) / 10)
                                            .stroke(.white, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                                            .rotationEffect(.degrees(-90))
                                            .frame(width: 34, height: 34)
                                            .animation(.linear(duration: 1), value: countdown)
                                        Image(systemName: "play.fill").font(.footnote.weight(.bold))
                                    }
                                }
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            VStack(alignment: .leading, spacing: 4) {
                                Text("NÄCHSTE FOLGE IN \(countdown) S")
                                    .font(.caption2.weight(.bold)).tracking(0.8).foregroundStyle(.secondary)
                                    .contentTransition(.numericText(countsDown: true))
                                Text([episode.episodeLabel, episode.name].compactMap { $0 }.joined(separator: " – "))
                                    .font(.subheadline.weight(.semibold)).lineLimit(2).multilineTextAlignment(.leading)
                            }
                            .frame(maxWidth: 220, alignment: .leading)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PlayerPressStyle())
                    Button(action: close) {
                        Image(systemName: "xmark")
                            .font(.footnote.weight(.bold))
                            .frame(width: 30, height: 30)
                            .background(.white.opacity(0.14), in: Circle())
                    }
                    .buttonStyle(PlayerPressStyle())
                    .accessibilityLabel(String(localized: "Schließen"))
                }
                .padding(10)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .shadow(color: .black.opacity(0.35), radius: 20, y: 8)
            }
        }
        .foregroundStyle(.white)
        .padding(.trailing, 16)
        .padding(.bottom, lifted ? 136 : 20)
        .animation(.easeInOut(duration: 0.25), value: lifted)
    }
}

/// A short message at the top. The Apple TV texts point to "↓" (swipe down) for the panel; here that's the options
/// button, so its symbol takes the arrow's place.
struct PlayerNotice: View {
    let text: String
    /// Below the top bar while the controls show.
    var lifted = false

    var body: some View {
        VStack {
            Label { message } icon: { Image(systemName: "info.circle.fill") }
                .font(.footnote.weight(.semibold))
                .multilineTextAlignment(.leading)
                // As wide as the text, at most about two thirds of a phone in landscape; longer messages wrap.
                .frame(maxWidth: 520)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 16).padding(.vertical, 10)
                .playerGlass(RoundedRectangle(cornerRadius: 20, style: .continuous), interactive: false)
                .padding(.horizontal, 20)
                .padding(.top, lifted ? 64 : 10)
            Spacer()
        }
        .animation(.easeInOut(duration: 0.25), value: lifted)
        .allowsHitTesting(false)
    }

    private var message: Text {
        let parts = text.components(separatedBy: "↓")
        return parts.dropFirst().reduce(Text(parts[0])) { result, part in
            result + Text(Image(systemName: "slider.horizontal.3")) + Text(part)
        }
    }
}

/// The ±10 s feedback of a double tap, on the side that was tapped.
struct PlayerSkipFeedback: View {
    let feedback: PlaybackUI.SkipFeedback

    var body: some View {
        GeometryReader { proxy in
            VStack(spacing: 6) {
                Image(systemName: feedback.forward ? "goforward" : "gobackward")
                    .font(.system(size: 30, weight: .semibold))
                    .symbolEffect(.bounce, value: feedback.seconds)
                Text(verbatim: "\(feedback.forward ? "+" : "−")\(feedback.seconds) s")
                    .font(.subheadline.weight(.bold).monospacedDigit())
                    .contentTransition(.numericText(value: Double(feedback.seconds)))
            }
            .foregroundStyle(.white)
            .frame(width: 104, height: 104)
            .playerGlass(Circle(), interactive: false)
            .position(x: proxy.size.width * (feedback.forward ? 0.78 : 0.22), y: proxy.size.height / 2)
            .transition(.opacity.combined(with: .scale(scale: 0.8)))
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// In place of the picture while it plays in the Picture in Picture window.
struct PlayerPictureInPicturePlaceholder: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "pip").font(.system(size: 54, weight: .light))
            Text("Wird als Bild-in-Bild wiedergegeben").font(.subheadline).foregroundStyle(.secondary)
        }
        .foregroundStyle(.white.opacity(0.8))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

/// In place of the picture while an AirPlay receiver shows it.
struct PlayerExternalPlaybackPlaceholder: View {
    let route: String

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "airplayvideo").font(.system(size: 54, weight: .light))
            Text(route).font(.headline)
        }
        .foregroundStyle(.white.opacity(0.85))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

/// The next episode's backdrop behind the up-next card once the film has ended.
struct PlayerBackdrop: View {
    let item: BaseItem
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ZStack {
            Theme.background
            RemoteImage(url: model.client?.artworkURL(item, .backdrop, width: 1600))
            LinearGradient(colors: [.black.opacity(0.2), .black.opacity(0.75)], startPoint: .top, endPoint: .bottom)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

// MARK: - Loading and failure

/// While the stream opens: backdrop, logo or title, spinner, and a way out.
struct PlayerPreparingView: View {
    let item: BaseItem
    let source: MediaSource?
    var status: String?
    let close: () -> Void
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            RemoteImage(url: model.client?.artworkURL(item, .backdrop, width: 1600))
                .ignoresSafeArea()
            LinearGradient(colors: [.black.opacity(0.45), .black.opacity(0.8)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
            VStack(spacing: 18) {
                PlayerTitleLogo(item: item)
                if item.isEpisode {
                    Text([item.episodeLabel, item.name].compactMap { $0 }.joined(separator: " – "))
                        .font(.headline).multilineTextAlignment(.center)
                }
                ProgressView().controlSize(.large).tint(.white).padding(.top, 6)
                if let status { Text(status).font(.footnote).foregroundStyle(.secondary) }
                let badges = TechInfo.badges(source).filter { $0 != TechInfo.subtitlesBadge }
                if !badges.isEmpty { PlayerBadges(badges: badges) }
            }
            .padding(.horizontal, 40)
            VStack {
                HStack {
                    PlayerGlassButton(systemImage: "xmark", label: String(localized: "Schließen"), action: close)
                    Spacer()
                }
                Spacer()
            }
            .padding(16)
        }
    }
}

/// The logo artwork when there is one, otherwise the title in large type.
struct PlayerTitleLogo: View {
    let item: BaseItem
    @EnvironmentObject private var model: AppModel
    @State private var logo: UIImage?

    var body: some View {
        Group {
            if let logo {
                Image(uiImage: logo).resizable().scaledToFit()
                    .frame(maxWidth: 340, maxHeight: 110)
                    .shadow(color: .black.opacity(0.5), radius: 16)
                    .accessibilityLabel(item.isEpisode ? item.seriesName ?? item.name : item.name)
            } else {
                Text(item.isEpisode ? item.seriesName ?? item.name : item.name)
                    .font(.largeTitle.weight(.bold)).multilineTextAlignment(.center).lineLimit(2).minimumScaleFactor(0.6)
                    .shadow(color: .black.opacity(0.5), radius: 10)
            }
        }
        .task(id: item.id) {
            guard let url = model.client?.logoURL(item) else { logo = nil; return }
            let image = await ImagePipeline.shared.image(url)
            withAnimation(.easeOut(duration: 0.25)) { logo = image }
        }
    }
}

struct PlayerFailureView: View {
    let message: String
    let retry: () -> Void
    let close: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.7).ignoresSafeArea()
            VStack(spacing: 14) {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 44)).foregroundStyle(.orange)
                Text("Wiedergabe nicht möglich").font(.title3.weight(.bold))
                Text(message).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                HStack(spacing: 12) {
                    Button("Zurück", action: close)
                        .buttonStyle(.bordered)
                    Button("Erneut versuchen", action: retry)
                        .buttonStyle(.borderedProminent)
                }
                .controlSize(.large)
                .padding(.top, 6)
            }
            .padding(28)
            .frame(maxWidth: 440)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
            .padding(24)
        }
    }
}

// MARK: - Diagnostics

/// Live numbers that explain stutter (Einstellungen › Diagnose), compact for a phone screen.
struct PlayerDiagnosticsOverlay: View {
    @ObservedObject var player: PlayerController

    var body: some View {
        let stats = player.stats
        VStack(alignment: .leading, spacing: 3) {
            Label(verdictText(stats), systemImage: verdictIcon(stats.verdict))
                .font(.caption2.weight(.bold))
                .foregroundStyle(verdictColor(stats.verdict))
            row(String(localized: "Weg", comment: "Diagnostics label: playback pipeline"), player.streamTitle)
            row(String(localized: "Bild", comment: "Diagnostics label: video output"), player.outputVideo)
            row(String(localized: "Ton", comment: "Sound (sync setting, diagnostics label)"), player.audioOutput)
            row(String(localized: "Netz", comment: "Diagnostics label: network throughput"),
                rate(stats.throughput).map { String(localized: "\($0) ankommend", comment: "Network rate arriving, e.g. 12.3 Mbit/s") })
            row(String(localized: "Bedarf", comment: "Diagnostics label: required bitrate"),
                rate(stats.required).map { String(localized: "\($0) für diesen Stream") })
            row(String(localized: "Puffer", comment: "Diagnostics label: buffer"),
                stats.bufferAhead.map { String(localized: "\($0, specifier: "%.1f") s voraus", comment: "Seconds buffered ahead") })
            row(String(localized: "Hänger", comment: "Diagnostics label: number of stalls"), "\(stats.stalls)")
            row(String(localized: "Bilder", comment: "Diagnostics label: video frames"),
                [stats.displayFPS.map { String(format: "%.1f fps", $0) },
                 String(localized: "\(stats.droppedFrames) verloren", comment: "Dropped frames")].compactMap { $0 }.joined(separator: " · "))
        }
        .font(.system(size: 10, design: .monospaced))
        .padding(10)
        .frame(maxWidth: 320, alignment: .leading)
        .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.leading, 16)
        .padding(.top, 64)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(false)
    }

    @ViewBuilder private func row(_ title: String, _ value: String?) -> some View {
        if let value, !value.isEmpty {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title).foregroundStyle(.white.opacity(0.55)).frame(width: 56, alignment: .leading)
                Text(PlayerInfoList.forThisDevice(value)).foregroundStyle(.white).lineLimit(1).minimumScaleFactor(0.7)
            }
        }
    }

    private func rate(_ bits: Double?) -> String? {
        guard let bits, bits > 0 else { return nil }
        return String(format: "%.1f Mbit/s", bits / 1_000_000)
    }

    private func verdictText(_ stats: PlaybackStats) -> String {
        switch stats.verdict {
        case .good: return String(localized: "Läuft flüssig")
        case .tight: return String(localized: "Puffer knapp – Leitung am Limit")
        case .network:
            let available = (stats.capacity ?? stats.throughput ?? 0) / 1_000_000, required = stats.required / 1_000_000
            return String(localized: "Netzwerk zu langsam: \(available, specifier: "%.0f") von \(required, specifier: "%.0f") Mbit/s")
        case .decoder: return String(localized: "Decoder kommt nicht hinterher")
        }
    }

    private func verdictIcon(_ verdict: PlaybackStats.Verdict) -> String {
        verdict == .good ? "checkmark.circle.fill" : verdict == .tight ? "exclamationmark.circle.fill" : "xmark.octagon.fill"
    }

    private func verdictColor(_ verdict: PlaybackStats.Verdict) -> Color {
        verdict == .good ? .green : verdict == .tight ? .yellow : Color(red: 1, green: 0.4, blue: 0.35)
    }
}
