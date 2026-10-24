import SwiftUI
import AetherEngine

/// Subtitles, audio, quality, chapters, sync and playback details – the Apple TV panel as a side panel in landscape
/// and a bottom sheet in portrait, with the picture still visible.
struct PlayerOptionsPanel: View {
    @ObservedObject var ui: PlaybackUI
    @ObservedObject var player: PlayerController
    @EnvironmentObject private var model: AppModel
    @AppStorage("subtitleSize") private var subtitleSize = SubtitleSize.standard
    @AppStorage("subtitleBackground") private var subtitleBackground = SubtitleBackground.shadow
    @AppStorage("subtitleColor") private var subtitleColor = SubtitleColor.white

    private var tabs: [MobilePanelTab] { MobilePanelTab.allCases.filter { $0 != .chapters || !player.chapters.isEmpty } }

    var body: some View {
        GeometryReader { proxy in
            let side = proxy.size.width > proxy.size.height
            ZStack(alignment: side ? .trailing : .bottom) {
                if ui.panelOpen {
                    Color.black.opacity(0.35)
                        .ignoresSafeArea()
                        .onTapGesture { ui.closePanel() }
                        .accessibilityHidden(true)
                        .transition(.opacity)
                    panel
                        .frame(width: side ? min(460, max(360, proxy.size.width * 0.44)) : nil)
                        .frame(maxHeight: side ? .infinity : max(320, proxy.size.height * 0.62))
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
                        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                        .shadow(color: .black.opacity(0.35), radius: 30)
                        .padding(side ? 10 : 8)
                        .transition(.move(edge: side ? .trailing : .bottom).combined(with: .opacity))
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: side ? .trailing : .bottom)
        }
        .allowsHitTesting(ui.panelOpen)
        .sensoryFeedback(.selection, trigger: ui.panelTab)
    }

    private var panel: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                ScrollView(.horizontal) {
                    HStack(spacing: 6) {
                        ForEach(tabs) { tab in
                            Button { withAnimation(.easeOut(duration: 0.2)) { ui.selectTab(tab) } } label: {
                                Text(tab.title)
                                    .font(.subheadline.weight(.semibold))
                                    .padding(.horizontal, 14).padding(.vertical, 8)
                                    .foregroundStyle(ui.panelTab == tab ? .black : .white)
                                    .background(ui.panelTab == tab ? AnyShapeStyle(Color.white) : AnyShapeStyle(Color.white.opacity(0.1)), in: Capsule())
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(ui.panelTab == tab ? .isSelected : [])
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .scrollIndicators(.hidden)
                Button { ui.closePanel() } label: {
                    Image(systemName: "xmark")
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(.white.opacity(0.85))
                        .frame(width: 30, height: 30)
                        .background(.white.opacity(0.12), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "Schließen"))
                .padding(.trailing, 14)
            }
            .padding(.vertical, 12)
            Divider().overlay(.white.opacity(0.08))
            ScrollView {
                Group {
                    switch ui.panelTab {
                    case .subtitles: subtitlesTab
                    case .audio: audioTab
                    case .quality: qualityTab
                    case .chapters: chaptersTab
                    case .sync: syncTab
                    case .info: PlayerInfoList(player: player)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.hidden)
        }
    }

    // MARK: Tabs

    private var trackHeader: String { String(localized: "Spur", comment: "Column header: subtitle/audio tracks") }

    private var subtitlesTab: some View {
        VStack(alignment: .leading, spacing: 22) {
            PlayerPanelSection(title: trackHeader) {
                PlayerTrackList(options: player.subtitleOptions, selected: player.subtitleIndex ?? -1) { player.selectSubtitle($0) }
            }
            PlayerPanelSection(title: String(localized: "Größe", comment: "Subtitle size")) {
                Picker(String(localized: "Größe", comment: "Subtitle size"), selection: $subtitleSize) {
                    ForEach(SubtitleSize.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            PlayerPanelSection(title: String(localized: "Hintergrund", comment: "Subtitle background")) {
                Picker(String(localized: "Hintergrund", comment: "Subtitle background"), selection: $subtitleBackground) {
                    ForEach(SubtitleBackground.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            PlayerPanelSection(title: String(localized: "Farbe", comment: "Subtitle colour")) {
                Picker(String(localized: "Farbe", comment: "Subtitle colour"), selection: $subtitleColor) {
                    ForEach(SubtitleColor.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
        }
    }

    private var audioTab: some View {
        VStack(alignment: .leading, spacing: 22) {
            PlayerPanelSection(title: trackHeader) {
                PlayerTrackList(options: player.audioOptions, selected: player.audioIndex ?? Int.min) { player.selectAudio($0) }
            }
            if let output = player.audioOutput {
                PlayerPanelSection(title: String(localized: "Ausgabe", comment: "Info panel label: audio output")) {
                    Text(PlayerInfoList.forThisDevice(output)).font(.subheadline)
                }
            }
        }
    }

    private var qualityTab: some View {
        VStack(alignment: .leading, spacing: 22) {
            PlayerPanelSection(title: String(localized: "Stream", comment: "Column header: stream quality options")) {
                PlayerTrackList(options: player.qualityOptions, selected: player.quality) { player.selectQuality($0) }
            }
            PlayerPanelSection(title: String(localized: "Verbindung")) {
                VStack(alignment: .leading, spacing: 6) {
                    if let capacity = player.stats.capacity ?? player.stats.throughput {
                        Text("\(capacity / 1_000_000, specifier: "%.0f") Mbit/s verfügbar").font(.subheadline)
                    }
                    Text("\(player.stats.required / 1_000_000, specifier: "%.0f") Mbit/s benötigt").font(.subheadline)
                    Text("„Original“ spielt die Datei unverändert. „Nur gewählte Tonspur“ bleibt verlustfrei. Bei einer Bitrate-Grenze rechnet der Server das Bild herunter – nur sinnvoll, wenn die Leitung nicht reicht.")
                        .font(.caption).foregroundStyle(.secondary).padding(.top, 4)
                }
            }
        }
    }

    private var chaptersTab: some View {
        LazyVStack(spacing: 4) {
            ForEach(Array(player.chapters.enumerated()), id: \.offset) { index, chapter in
                let current = player.chapters.last(where: { $0.start <= ui.shownPosition }) == chapter
                Button {
                    player.seek(to: chapter.start)
                    ui.closePanel()
                } label: {
                    HStack(spacing: 14) {
                        ZStack {
                            Theme.placeholder
                            if let tag = chapter.imageTag {
                                RemoteImage(url: model.client?.url("Items/\(player.item.id)/Images/Chapter/\(index)", query: ["tag": tag, "maxWidth": "400"]))
                            } else {
                                Text(verbatim: "\(index + 1)").font(.title2.weight(.bold)).foregroundStyle(.white.opacity(0.35))
                            }
                        }
                        .frame(width: 112, height: 63)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Theme.accent, lineWidth: current ? 2 : 0))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(chapter.name ?? String(localized: "Kapitel \(index + 1)")).font(.subheadline.weight(.semibold)).lineLimit(2)
                            Text(Format.clock(chapter.start)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(PlayerRowStyle())
            }
        }
    }

    private var syncTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            PlayerDelayControl(title: String(localized: "Untertitel"), value: player.subtitleDelay, step: 0.1,
                               hint: String(localized: "Positiv: Untertitel erscheinen später")) { player.setSubtitleDelay($0) }
            if player.canDelayAudio {
                PlayerDelayControl(title: String(localized: "Ton", comment: "Sound (sync setting, diagnostics label)"), value: player.audioDelay,
                                   step: 0.05, hint: String(localized: "Positiv: Ton kommt später als das Bild")) { player.setAudioDelay($0) }
            } else {
                Text("Die Ton-Synchronisation übernimmt bei diesem Titel Apples Player selbst.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Pieces

/// A small uppercase heading over grouped content.
struct PlayerPanelSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased()).font(.caption.weight(.bold)).tracking(1.2).foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
            content
        }
    }
}

/// Selectable tracks with a check mark on the current one.
struct PlayerTrackList: View {
    let options: [TrackOption]
    let selected: Int
    let choose: (Int) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(options.enumerated()), id: \.element.id) { index, option in
                if index > 0 { Divider().overlay(.white.opacity(0.06)).padding(.leading, 44) }
                Button { choose(option.id) } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "checkmark")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(Theme.accent)
                            .opacity(option.id == selected ? 1 : 0)
                            .frame(width: 20)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(option.title).font(.body)
                            if let detail = option.detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(PlayerRowStyle())
                .accessibilityAddTraits(option.id == selected ? .isSelected : [])
            }
        }
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .sensoryFeedback(.selection, trigger: selected)
    }
}

/// A row that lights up while pressed.
struct PlayerRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(configuration.isPressed ? 0.12 : 0)))
    }
}

/// Minus, value, plus and reset for the audio and subtitle delay.
struct PlayerDelayControl: View {
    let title: String
    let value: Double
    let step: Double
    let hint: String
    let set: (Double) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(hint).font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 14) {
                stepButton("minus") { set(value - step) }
                Text(String(format: "%+.2f s", value))
                    .font(.title3.monospacedDigit().weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .contentTransition(.numericText(value: value))
                stepButton("plus") { set(value + step) }
            }
            Button("Zurücksetzen") { set(0) }
                .font(.subheadline.weight(.semibold))
                .disabled(value == 0)
        }
        .padding(14)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .animation(.easeOut(duration: 0.15), value: value)
        .sensoryFeedback(.selection, trigger: value)
        .accessibilityElement(children: .contain)
    }

    private func stepButton(_ systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.body.weight(.bold))
                .frame(width: 44, height: 44)
                .background(.white.opacity(0.12), in: Circle())
        }
        .buttonStyle(PlayerPressStyle())
        .accessibilityLabel(Text(verbatim: "\(title) \(systemImage == "plus" ? "+" : "−")\(String(format: "%.2f", step)) s"))
    }
}

/// What plays and how: the file, the pipeline, what reaches the screen and the speakers.
struct PlayerInfoList: View {
    @ObservedObject var player: PlayerController

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            let badges = TechInfo.badges(player.source).filter { $0 != TechInfo.subtitlesBadge }
            if !badges.isEmpty { PlayerBadges(badges: badges) }
            row(String(localized: "Video", comment: "Info panel label"), TechInfo.videoDescription(player.source?.video))
            row(String(localized: "Audio", comment: "Audio (player panel tab, info label)"),
                TechInfo.audioDescription(player.source?.audioStreams.first { $0.index == player.audioIndex }))
            row(String(localized: "Ausgabe", comment: "Info panel label: audio output"), player.audioOutput)
            row(String(localized: "Datei", comment: "Info panel label: file"),
                [JellyfinClient.fileExtension(container: player.source?.container).uppercased(), TechInfo.bitrate(player.source)]
                    .compactMap { $0 }.joined(separator: " · "))
            row(String(localized: "Wiedergabe", comment: "Info panel label: playback pipeline"), player.streamTitle)
            row(String(localized: "Bildausgabe", comment: "Info panel label: video output"), player.outputVideo)
            row(String(localized: "Warum", comment: "Info panel label: reason for the playback pipeline"), player.plan?.reason)
        }
    }

    @ViewBuilder private func row(_ title: String, _ value: String?) -> some View {
        if let value, !value.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text(Self.forThisDevice(value)).font(.subheadline)
            }
            .accessibilityElement(children: .combine)
        }
    }

    /// The engine's descriptions name the Apple TV ("auf dem Apple TV umverpackt"); here it's this iPhone or iPad.
    static func forThisDevice(_ text: String) -> String {
        text.replacingOccurrences(of: "Apple TV", with: UIDevice.current.model)
    }
}

/// Outlined format badges: 4K, Dolby Vision, Atmos, 5.1.
struct PlayerBadges: View {
    let badges: [String]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(badges, id: \.self) { badge in
                Text(badge)
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(.white.opacity(0.6), lineWidth: 1))
                    .foregroundStyle(.white.opacity(0.9))
            }
        }
        .accessibilityElement(children: .combine)
    }
}
