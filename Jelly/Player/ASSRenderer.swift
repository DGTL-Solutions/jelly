import SwiftUI
import QuartzCore
import Libass

/// Renders ASS/SSA subtitles with libass – positioning, fonts, colours, karaoke and animations as authored.
/// The whole script comes from the server once; rendering follows the player clock independently of the pipeline.
final class ASSRenderer {
    private let library: OpaquePointer
    private let renderer: OpaquePointer
    private var track: UnsafeMutablePointer<ASS_Track>?
    private var frame = CGSize.zero

    init?() {
        guard let library = ass_library_init() else { return nil }
        guard let renderer = ass_renderer_init(library) else { ass_library_done(library); return nil }
        self.library = library
        self.renderer = renderer
        ass_set_extract_fonts(library, 1)
    }

    deinit {
        if let track { ass_free_track(track) }
        ass_renderer_done(renderer)
        ass_library_done(library)
    }

    /// Fonts embedded in the MKV must be added before the script is loaded.
    func load(script: Data, fonts: [(name: String, data: Data)]) -> Bool {
        for font in fonts {
            font.data.withUnsafeBytes { bytes in
                _ = font.name.withCString { name in
                    ass_add_font(library, name, bytes.baseAddress?.assumingMemoryBound(to: CChar.self), Int32(font.data.count))
                }
            }
        }
        ass_set_fonts(renderer, nil, "Helvetica Neue", Int32(ASS_FONTPROVIDER_AUTODETECT.rawValue), nil, 1)
        var buffer = [CChar](repeating: 0, count: script.count + 1)
        script.withUnsafeBytes { source in buffer.withUnsafeMutableBytes { target in target.copyMemory(from: source) } }
        if let track { ass_free_track(track) }
        track = buffer.withUnsafeMutableBufferPointer { ass_read_memory(library, $0.baseAddress, script.count, nil) }
        return track != nil
    }

    var eventCount: Int { Int(track?.pointee.n_events ?? 0) }

    /// Start of the first event at or after `seconds`, for diagnostics.
    func nextEvent(after seconds: Double) -> Double? {
        guard let track else { return nil }
        let ms = Int64(seconds * 1000)
        return (0..<Int(track.pointee.n_events)).lazy.map { Double(track.pointee.events[$0].Start) / 1000 }.filter { $0 * 1000 >= Double(ms) }.min()
    }

    /// `frame` is the on-screen video rectangle in pixels, `video` the coded picture size (for anamorphic scaling).
    func setSize(frame: CGSize, video: CGSize) {
        guard frame != self.frame, frame.width > 0, frame.height > 0 else { return }
        self.frame = frame
        ass_set_frame_size(renderer, Int32(frame.width), Int32(frame.height))
        if video.width > 0, video.height > 0 { ass_set_storage_size(renderer, Int32(video.width), Int32(video.height)) }
    }

    /// Returns nil when nothing changed since the last call; an empty result clears the overlay.
    func render(at seconds: Double) -> (image: CGImage?, rect: CGRect)? {
        guard let track, frame.width > 0 else { return nil }
        var change: Int32 = 0
        let first = ass_render_frame(renderer, track, Int64(seconds * 1000), &change)
        guard change != 0 else { return nil }
        return Self.composite(first)
    }

    /// Blends libass's coverage bitmaps into one premultiplied RGBA image covering only the area in use.
    private static func composite(_ first: UnsafeMutablePointer<ASS_Image>?) -> (image: CGImage?, rect: CGRect) {
        var bounds = CGRect.null
        var node = first
        while let image = node?.pointee {
            if image.w > 0, image.h > 0 { bounds = bounds.union(CGRect(x: Int(image.dst_x), y: Int(image.dst_y), width: Int(image.w), height: Int(image.h))) }
            node = image.next
        }
        guard !bounds.isNull else { return (nil, .zero) }
        let width = Int(bounds.width), height = Int(bounds.height)
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        node = first
        while let image = node?.pointee {
            let color = image.color
            let r = Int(color >> 24 & 0xFF), g = Int(color >> 16 & 0xFF), b = Int(color >> 8 & 0xFF)
            let opacity = 255 - Int(color & 0xFF)
            let originX = Int(image.dst_x) - Int(bounds.minX), originY = Int(image.dst_y) - Int(bounds.minY)
            if let bitmap = image.bitmap, opacity > 0 {
                for y in 0..<Int(image.h) {
                    let row = (originY + y) * width
                    for x in 0..<Int(image.w) {
                        let coverage = Int(bitmap[y * Int(image.stride) + x])
                        guard coverage > 0 else { continue }
                        let alpha = coverage * opacity / 255
                        let index = (row + originX + x) * 4
                        let keep = 255 - alpha
                        pixels[index] = UInt8((r * alpha + Int(pixels[index]) * keep) / 255)
                        pixels[index + 1] = UInt8((g * alpha + Int(pixels[index + 1]) * keep) / 255)
                        pixels[index + 2] = UInt8((b * alpha + Int(pixels[index + 2]) * keep) / 255)
                        pixels[index + 3] = UInt8(alpha + Int(pixels[index + 3]) * keep / 255)
                    }
                }
            }
            node = image.next
        }
        let provider = CGDataProvider(data: Data(pixels) as CFData)
        let cgImage = provider.flatMap {
            CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                    provider: $0, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        }
        return (cgImage, bounds)
    }
}

/// Drives an `ASSRenderer` from the player clock and publishes the current subtitle image for SwiftUI.
@MainActor
final class ASSOverlayModel: ObservableObject {
    @Published private(set) var image: CGImage?
    @Published private(set) var rect: CGRect = .zero
    @Published private(set) var videoRect: CGRect = .zero
    @Published private(set) var isActive = false

    var clock: () -> Double = { 0 }
    var delay: Double = 0
    private var renderer: ASSRenderer?
    private var displayLink: CADisplayLink?
    private let queue = DispatchQueue(label: "jelly.ass", qos: .userInitiated)
    private var busy = false
    private var scale: CGFloat = 2

    func start(script: Data, fonts: [(name: String, data: Data)], video: CGSize, screen: CGSize, scale: CGFloat) {
        stop()
        guard let renderer = ASSRenderer(), renderer.load(script: script, fonts: fonts) else { return }
        // Fit the video picture into the screen; subtitles are laid out on that rectangle.
        let aspect = video.width > 0 && video.height > 0 ? video.width / video.height : 16 / 9
        let fitted = aspect > screen.width / screen.height
            ? CGSize(width: screen.width, height: screen.width / aspect) : CGSize(width: screen.height * aspect, height: screen.height)
        videoRect = CGRect(x: (screen.width - fitted.width) / 2, y: (screen.height - fitted.height) / 2, width: fitted.width, height: fitted.height)
        self.scale = scale
        renderer.setSize(frame: CGSize(width: fitted.width * scale, height: fitted.height * scale), video: video)
        self.renderer = renderer
        isActive = true
        Diagnostics.log("ass events=\(renderer.eventCount) next=\(renderer.nextEvent(after: clock()).map { String(Int($0)) } ?? "-")s frame=\(Int(fitted.width * scale))x\(Int(fitted.height * scale))")
        let link = CADisplayLink(target: DisplayLinkTarget { [weak self] in self?.tick() }, selector: #selector(DisplayLinkTarget.fire))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: 30, preferred: 30)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
        renderer = nil
        image = nil
        isActive = false
    }

    private func tick() {
        guard !busy, let renderer else { return }
        busy = true
        let time = clock() - delay
        let scale = scale
        queue.async { [weak self] in
            let result = renderer.render(at: time)
            DispatchQueue.main.async {
                guard let self else { return }
                self.busy = false
                guard let result, self.renderer === renderer else { return }
                if self.image == nil, result.image != nil { Diagnostics.log("ass first image at \(Int(time))s rect=\(result.rect)") }
                self.image = result.image
                self.rect = CGRect(x: result.rect.minX / scale, y: result.rect.minY / scale,
                                   width: result.rect.width / scale, height: result.rect.height / scale)
            }
        }
    }
}

private final class DisplayLinkTarget {
    let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func fire() { action() }
}

struct ASSOverlay: View {
    @ObservedObject var model: ASSOverlayModel

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            if let image = model.image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .frame(width: model.rect.width, height: model.rect.height)
                    .offset(x: model.videoRect.minX + model.rect.minX, y: model.videoRect.minY + model.rect.minY)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}
