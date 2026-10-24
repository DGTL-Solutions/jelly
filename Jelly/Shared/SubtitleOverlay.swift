import SwiftUI
import AetherEngine

/// The engine's subtitle cues – text (SRT, WebVTT, also from server streams) in the viewer's style, picture subtitles
/// (PGS, VobSub, DVB) where the disc placed them. ASS/SSA draws `ASSOverlay` instead.
struct SubtitleOverlay: View {
    @ObservedObject var engine: AetherEngine
    /// Ten ticks a second; cues carry the source time of the frame on screen.
    @ObservedObject var clock: PlaybackClock
    var delay: Double = 0
    let size: CGFloat
    var background = SubtitleBackground.shadow
    var color = Color.white
    let lifted: Bool

    var body: some View {
        let time = clock.sourceTime - delay
        let cues = engine.subtitleCues.filter { $0.startTime <= time && time < $0.endTime }
        GeometryReader { proxy in
            ZStack {
                ForEach(cues) { cue in
                    if case .image(let image) = cue.body {
                        let rect = Self.place(image, in: proxy.size)
                        Image(decorative: image.cgImage, scale: 1).resizable()
                            .frame(width: rect.width, height: rect.height)
                            .position(x: rect.midX, y: rect.midY)
                    }
                }
                let lines = cues.filter { $0.text != nil }
                let top = lines.filter { (7...9).contains($0.placement?.alignment ?? 2) }
                let bottom = lines.filter { !(7...9).contains($0.placement?.alignment ?? 2) }
                VStack {
                    ForEach(top) { styled(text(for: $0)) }
                    Spacer()
                    ForEach(bottom) { styled(text(for: $0)) }
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 140)
                .padding(.top, 60)
                .padding(.bottom, lifted ? 260 : 70)
            }
        }
        .animation(.easeOut(duration: 0.25), value: lifted)
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    /// Bold and italic from the file; size, colour and background follow the viewer's settings.
    private func text(for cue: SubtitleCue) -> Text {
        guard case .richText(let runs) = cue.body else { return Text(cue.text ?? "") }
        return runs.reduce(Text("")) { result, run in
            var piece = Text(run.text)
            if run.isBold { piece = piece.bold() }
            if run.isItalic { piece = piece.italic() }
            if run.isUnderlined { piece = piece.underline() }
            return result + piece
        }
    }

    /// The picture's canvas (the video frame it was authored for) fitted into the screen like the video itself.
    static func place(_ image: SubtitleImage, in screen: CGSize) -> CGRect {
        let canvas = image.canvasSize.width > 0 && image.canvasSize.height > 0 ? image.canvasSize : screen
        let scale = min(screen.width / canvas.width, screen.height / canvas.height)
        let origin = CGPoint(x: (screen.width - canvas.width * scale) / 2, y: (screen.height - canvas.height * scale) / 2)
        return CGRect(x: origin.x + image.position.minX * scale, y: origin.y + image.position.minY * scale,
                      width: image.position.width * scale, height: image.position.height * scale)
    }

    @ViewBuilder private func styled(_ text: Text) -> some View {
        let base = text
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(color)
            .multilineTextAlignment(.center)
        switch background {
        case .shadow:
            base.shadow(color: .black.opacity(0.95), radius: 2, x: 0, y: 1).shadow(color: .black.opacity(0.7), radius: 8)
        case .box:
            base.padding(.horizontal, 18).padding(.vertical, 6)
                .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }
}
