import SwiftUI
import AetherEngine

/// The controls over the picture: close, title, aspect, Picture in Picture and AirPlay at the top; ±10 s and
/// play/pause in the middle; chapter, track options, scrubber and times at the bottom.
struct PlayerControlsOverlay: View {
    @ObservedObject var ui: PlaybackUI
    @ObservedObject var player: PlayerController
    @ObservedObject var pip: PlayerPictureInPicture
    let close: () -> Void
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    private var regular: Bool { horizontalSizeClass == .regular && verticalSizeClass == .regular }

    var body: some View {
        ZStack {
            transport
                .opacity(ui.scrubbing ? 0 : 1)
                .animation(.easeOut(duration: 0.15), value: ui.scrubbing)
            VStack(spacing: 0) {
                topBar
                Spacer(minLength: 0)
                bottomBar
            }
            .padding(.horizontal, regular ? 28 : 16)
            .padding(.top, regular ? 16 : 8)
            .padding(.bottom, regular ? 16 : 6)
        }
    }

    // MARK: Top

    private var topBar: some View {
        HStack(spacing: 12) {
            PlayerGlassButton(systemImage: UIDevice.current.userInterfaceIdiom == .phone ? "chevron.down" : "xmark",
                              label: String(localized: "Schließen"), action: close)
            VStack(alignment: .leading, spacing: 1) {
                if player.item.isEpisode {
                    Text(player.item.seriesName ?? "").font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.7))
                    Text([player.item.episodeLabel, player.item.name].compactMap { $0 }.joined(separator: " – "))
                        .font(.subheadline.weight(.semibold))
                } else {
                    Text(player.item.name).font(.headline)
                }
            }
            .lineLimit(1)
            .shadow(color: .black.opacity(0.4), radius: 6)
            .accessibilityElement(children: .combine)
            Spacer(minLength: 8)
            PlayerGlassButton(systemImage: ui.fills ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                              label: ui.fills ? String(localized: "Bild einpassen") : String(localized: "Bild füllen")) {
                ui.setFill(!ui.fills)
                ui.scheduleHide()
            }
            if pip.isSupported {
                PlayerGlassButton(systemImage: pip.isActive ? "pip.exit" : "pip.enter", label: String(localized: "Bild-in-Bild")) {
                    pip.toggle()
                }
                .disabled(!pip.isPossible && !pip.isActive)
            }
            PlayerAirPlayButton()
                .frame(width: 44, height: 44)
                .playerGlass(Circle())
        }
    }

    // MARK: Middle

    private var transport: some View {
        HStack(spacing: regular ? 88 : 56) {
            transportButton("gobackward.10", size: regular ? 34 : 28, label: String(localized: "10 Sekunden zurück")) {
                ui.skip(-10)
            }
            ZStack {
                if player.isBuffering {
                    ProgressView().controlSize(.large).tint(.white)
                } else {
                    transportButton(player.isPlaying ? "pause.fill" : "play.fill", size: regular ? 54 : 44,
                                    label: player.isPlaying ? String(localized: "Pause") : String(localized: "Abspielen")) {
                        if ui.seekTarget != nil { ui.commitSeek() }
                        player.togglePlayPause()
                    }
                    .contentTransition(.symbolEffect(.replace))
                }
            }
            .frame(width: 80, height: 80)
            transportButton("goforward.10", size: regular ? 34 : 28, label: String(localized: "10 Sekunden vor")) {
                ui.skip(10)
            }
        }
        .sensoryFeedback(.impact(weight: .light), trigger: player.isPlaying)
    }

    private func transportButton(_ systemImage: String, size: CGFloat, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: size * 1.7, height: size * 1.7)
                .contentShape(Circle())
                .shadow(color: .black.opacity(0.45), radius: 10)
        }
        .buttonStyle(PlayerPressStyle())
        .accessibilityLabel(label)
    }

    // MARK: Bottom

    private var bottomBar: some View {
        VStack(spacing: regular ? 10 : 6) {
            HStack(alignment: .center, spacing: 10) {
                if let chapter = currentChapter {
                    Text(chapter).font(.footnote.weight(.semibold)).foregroundStyle(.white.opacity(0.8)).lineLimit(1)
                }
                Spacer(minLength: 0)
                PlayerGlassButton(systemImage: "captions.bubble", label: String(localized: "Untertitel")) {
                    ui.openPanel(.subtitles)
                }
                PlayerGlassButton(systemImage: "slider.horizontal.3", label: String(localized: "Wiedergabeoptionen")) {
                    ui.openPanel(ui.optionsTab)
                }
            }
            if let engine = player.aether {
                PlayerScrubber(ui: ui, player: player, clock: engine.clock)
            }
            timeRow
        }
    }

    private var timeRow: some View {
        HStack {
            Text(Format.clock(ui.shownPosition))
                .foregroundStyle(ui.seekTarget == nil ? .white.opacity(0.85) : Theme.accent)
            Spacer()
            if let target = ui.seekTarget {
                let delta = Int((target - player.position).rounded())
                Text(verbatim: delta >= 0 ? "+\(Format.clock(Double(delta)))" : "−\(Format.clock(Double(-delta)))")
                    .foregroundStyle(Theme.accent)
            } else if player.duration > 0 {
                let end = Date().addingTimeInterval(max(0, player.duration - ui.shownPosition)).formatted(date: .omitted, time: .shortened)
                Text("Endet um \(end)").foregroundStyle(.white.opacity(0.7))
            }
            Spacer()
            Text(verbatim: "−" + Format.clock(player.duration - ui.shownPosition)).foregroundStyle(.white.opacity(0.85))
        }
        .font((regular ? Font.subheadline : .caption).monospacedDigit().weight(.medium))
        .lineLimit(1)
    }

    private var currentChapter: String? {
        player.chapters.last { $0.start <= ui.shownPosition }?.name.flatMap { name in
            name.lowercased().hasPrefix("chapter") ? nil : name
        }
    }
}

/// Darkens the top and bottom of the picture behind the controls; drawn under the subtitles so they stay bright.
struct PlayerControlsScrim: View {
    var body: some View {
        LinearGradient(stops: [.init(color: .black.opacity(0.6), location: 0), .init(color: .clear, location: 0.3),
                               .init(color: .clear, location: 0.55), .init(color: .black.opacity(0.8), location: 1)],
                       startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

// MARK: - Scrubber

/// Drag anywhere on the bar to scrub: the picture keeps playing until the finger lifts, a bubble shows the time and
/// a thumbnail of the target. The intro is a lighter section, chapters are small gaps.
struct PlayerScrubber: View {
    @ObservedObject var ui: PlaybackUI
    @ObservedObject var player: PlayerController
    /// For the buffered range; ten ticks a second.
    @ObservedObject var clock: PlaybackClock

    private let height: CGFloat = 34

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let duration = max(player.duration, 1)
            let progress = min(1, max(0, ui.shownPosition / duration))
            let buffered = min(1, max(progress, clock.bufferedPosition / duration))
            let track: CGFloat = ui.scrubbing ? 8 : 5
            let knob: CGFloat = ui.scrubbing ? 22 : 14
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.22)).frame(height: track)
                Capsule().fill(.white.opacity(0.28)).frame(width: width * buffered, height: track)
                if let intro = player.intro, player.duration > 0 {
                    Capsule().fill(.white.opacity(0.3))
                        .frame(width: max(0, width * (intro.upperBound - intro.lowerBound) / duration), height: track)
                        .offset(x: width * intro.lowerBound / duration)
                }
                Capsule().fill(.white).frame(width: max(track, width * progress), height: track)
                ForEach(chapterMarks(duration), id: \.self) { mark in
                    Rectangle().fill(.black.opacity(0.55)).frame(width: 2, height: track).offset(x: width * mark - 1)
                }
                Circle().fill(.white)
                    .frame(width: knob, height: knob)
                    .shadow(color: .black.opacity(0.35), radius: 4)
                    .offset(x: min(max(0, width * progress - knob / 2), width - knob))
                if ui.scrubbing, let target = ui.seekTarget {
                    preview(Format.clock(target))
                        .position(x: min(max(previewWidth / 2, width * progress), width - previewWidth / 2),
                                  y: height / 2 - previewHeight / 2 - 18)
                        .transition(.opacity)
                }
            }
            .frame(width: width, height: height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in ui.scrub(toFraction: value.location.x / max(width, 1)) }
                    .onEnded { _ in ui.commitSeek() }
            )
            .animation(.easeOut(duration: 0.15), value: ui.scrubbing)
        }
        .frame(height: height)
        .sensoryFeedback(.selection, trigger: ui.scrubbing)
        .accessibilityElement()
        .accessibilityLabel(Text("Wiedergabeposition"))
        .accessibilityValue(Text(verbatim: "\(Format.clock(ui.shownPosition)) / \(Format.clock(player.duration))"))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: ui.skip(10)
            case .decrement: ui.skip(-10)
            @unknown default: break
            }
        }
    }

    private var previewWidth: CGFloat { ui.thumbnail == nil ? 90 : 180 }
    private var previewHeight: CGFloat { ui.thumbnail == nil ? 30 : 101 + 8 + 30 }

    private func chapterMarks(_ duration: Double) -> [Double] {
        player.chapters.map { $0.start / duration }.filter { $0 > 0.005 && $0 < 0.995 }
    }

    private func preview(_ time: String) -> some View {
        VStack(spacing: 8) {
            if let thumbnail = ui.thumbnail {
                Image(uiImage: thumbnail).resizable().aspectRatio(contentMode: .fill)
                    .frame(width: 180, height: 101)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.white.opacity(0.85), lineWidth: 2))
                    .shadow(color: .black.opacity(0.5), radius: 12)
            }
            Text(time).font(.footnote.weight(.semibold).monospacedDigit())
                .padding(.horizontal, 12).frame(height: 30)
                .background(.white, in: Capsule())
                .foregroundStyle(.black)
        }
        .fixedSize()
        .allowsHitTesting(false)
    }
}

// MARK: - Buttons

/// A round glass button with an SF Symbol and a VoiceOver label.
struct PlayerGlassButton: View {
    let systemImage: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .buttonStyle(PlayerPressStyle())
        .playerGlass(Circle())
        .accessibilityLabel(label)
    }
}

/// Shrinks a little while pressed.
struct PlayerPressStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.88 : 1)
            .opacity(isEnabled ? 1 : 0.4)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

extension View {
    /// Liquid Glass where available, a thin material before iOS 26.
    @ViewBuilder func playerGlass<S: Shape>(_ shape: S, interactive: Bool = true) -> some View {
        if #available(iOS 26.0, *) {
            glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
        } else {
            background(.ultraThinMaterial, in: shape)
        }
    }
}
