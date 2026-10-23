import AppKit

/// Renders the layered tvOS app icon and Top Shelf images into Jelly/Assets.xcassets.
/// Run: xcrun swift Scripts/GenerateArtwork.swift
let root = URL(fileURLWithPath: "Jelly/Assets.xcassets")
let brand = root.appendingPathComponent("App Icon & Top Shelf Image.brandassets")
let purple = NSColor(calibratedRed: 0.55, green: 0.25, blue: 0.85, alpha: 1)
let blue = NSColor(calibratedRed: 0.0, green: 0.58, blue: 0.84, alpha: 1)

func png(_ width: Int, _ height: Int, _ draw: (CGRect) -> Void) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    draw(CGRect(x: 0, y: 0, width: width, height: height))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

func background(_ rect: CGRect) {
    NSGradient(starting: purple, ending: blue)!.draw(in: rect, angle: -25)
    // Soft "jelly" bubbles for depth behind the parallax front layer.
    for (x, y, r, a) in [(0.18, 0.85, 0.55, 0.16), (0.9, 0.1, 0.5, 0.12), (0.75, 0.95, 0.25, 0.10)] as [(CGFloat, CGFloat, CGFloat, CGFloat)] {
        let radius = rect.height * r
        let center = CGPoint(x: rect.minX + rect.width * x, y: rect.minY + rect.height * y)
        NSGradient(starting: NSColor.white.withAlphaComponent(a), ending: NSColor.white.withAlphaComponent(0))!
            .draw(fromCenter: center, radius: 0, toCenter: center, radius: radius, options: [])
    }
}

func playMark(center: CGPoint, height: CGFloat, alpha: CGFloat = 1) {
    let w = height * 0.9
    let path = NSBezierPath()
    let left = center.x - w * 0.4
    path.move(to: CGPoint(x: left, y: center.y + height / 2))
    path.line(to: CGPoint(x: left + w, y: center.y))
    path.line(to: CGPoint(x: left, y: center.y - height / 2))
    path.close()
    path.lineJoinStyle = .round
    path.lineWidth = height * 0.16
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    shadow.shadowBlurRadius = height * 0.12
    shadow.shadowOffset = NSSize(width: 0, height: -height * 0.05)
    // One transparency layer so the shadow is cast by the finished shape, not separately by fill and stroke.
    let context = NSGraphicsContext.current!.cgContext
    NSGraphicsContext.saveGraphicsState()
    shadow.set()
    context.beginTransparencyLayer(auxiliaryInfo: nil)
    NSColor.white.withAlphaComponent(alpha).setFill()
    NSColor.white.withAlphaComponent(alpha).setStroke()
    path.fill()
    path.stroke()
    context.endTransparencyLayer()
    NSGraphicsContext.restoreGraphicsState()
}

func write(_ data: Data, _ path: URL) {
    try! FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
    try! data.write(to: path)
}

func json(_ object: Any, _ path: URL) {
    write(try! JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]), path)
}

let info = ["author": "xcode", "version": 1] as [String: Any]

func imageset(_ dir: URL, base: String, sizes: [(Int, Int, String)], draw: @escaping (CGRect) -> Void) {
    var images: [[String: String]] = []
    for (w, h, scale) in sizes {
        let file = scale == "1x" ? "\(base).png" : "\(base)@\(scale).png"
        write(png(w, h, draw), dir.appendingPathComponent(file))
        images.append(["filename": file, "idiom": "tv", "scale": scale])
    }
    json(["images": images, "info": info], dir.appendingPathComponent("Contents.json"))
}

/// The glossy "jelly" drop between background and play mark: a third layer, so the focused icon tilts with depth.
func jellyDrop(_ rect: CGRect) {
    let size = rect.height * 0.62
    let drop = NSBezierPath(roundedRect: CGRect(x: rect.midX - size / 2, y: rect.midY - size / 2, width: size, height: size),
                            xRadius: size * 0.32, yRadius: size * 0.32)
    let shadow = NSShadow()
    shadow.shadowColor = NSColor(calibratedRed: 0.12, green: 0.05, blue: 0.35, alpha: 0.45)
    shadow.shadowBlurRadius = size * 0.12
    shadow.shadowOffset = NSSize(width: 0, height: -size * 0.05)
    NSGraphicsContext.saveGraphicsState()
    shadow.set()
    NSColor.white.withAlphaComponent(0.16).setFill()
    drop.fill()
    NSGraphicsContext.restoreGraphicsState()
    // Light from above, like on glass.
    NSGradient(starting: NSColor.white.withAlphaComponent(0.34), ending: NSColor.white.withAlphaComponent(0.02))!.draw(in: drop, angle: -90)
    NSColor.white.withAlphaComponent(0.35).setStroke()
    drop.lineWidth = size * 0.012
    drop.stroke()
}

func imagestack(_ name: String, sizes: [(Int, Int, String)]) {
    let stack = brand.appendingPathComponent("\(name).imagestack")
    let layers = ["Front", "Middle", "Back"]
    json(["info": info, "layers": layers.map { ["filename": "\($0).imagestacklayer"] }], stack.appendingPathComponent("Contents.json"))
    for layer in layers {
        let dir = stack.appendingPathComponent("\(layer).imagestacklayer")
        json(["info": info], dir.appendingPathComponent("Contents.json"))
        imageset(dir.appendingPathComponent("Content.imageset"), base: layer.lowercased(), sizes: sizes) { rect in
            switch layer {
            case "Back": background(rect)
            case "Middle": jellyDrop(rect)
            default: playMark(center: CGPoint(x: rect.midX + rect.height * 0.025, y: rect.midY), height: rect.height * 0.3)
            }
        }
    }
}

/// The static Top Shelf, shown when nobody is signed in or there is nothing to continue. tvOS shows it full-screen,
/// crops it to the middle 1920 points and fills above and below with a blurred mirror image; the Dock covers the lower
/// part. So: calm, dark edges and everything that matters in the middle, a little above centre.
func topShelf(_ rect: CGRect) {
    let h = rect.height
    NSGradient(colors: [NSColor(calibratedRed: 0.07, green: 0.05, blue: 0.16, alpha: 1),
                        NSColor(calibratedRed: 0.10, green: 0.06, blue: 0.24, alpha: 1),
                        NSColor(calibratedRed: 0.03, green: 0.10, blue: 0.20, alpha: 1)])!.draw(in: rect, angle: -15)
    for (x, y, r, color, a) in [(0.36, 0.62, 1.05, purple, 0.55), (0.66, 0.40, 0.95, blue, 0.42), (0.52, 1.05, 0.55, purple, 0.25)]
        as [(CGFloat, CGFloat, CGFloat, NSColor, CGFloat)] {
        let center = CGPoint(x: rect.width * x, y: h * y)
        NSGradient(starting: color.withAlphaComponent(a), ending: color.withAlphaComponent(0))!
            .draw(fromCenter: center, radius: 0, toCenter: center, radius: h * r, options: [])
    }

    let mark = h * 0.30
    let title = NSAttributedString(string: "Jelly", attributes: [
        .font: NSFont.systemFont(ofSize: h * 0.19, weight: .bold), .foregroundColor: NSColor.white, .kern: -h * 0.004
    ])
    let tagline = NSAttributedString(string: "Deine Filme und Serien von Jellyfin – direkt auf dem Apple TV.", attributes: [
        .font: NSFont.systemFont(ofSize: h * 0.05, weight: .medium), .foregroundColor: NSColor.white.withAlphaComponent(0.78)
    ])
    let gap = h * 0.075
    let textWidth = max(title.size().width, tagline.size().width)
    let left = rect.midX - (mark + gap + textWidth) / 2
    let middle = h * 0.54

    // The app's mark: the icon's gradient tile with its play symbol.
    let tile = CGRect(x: left, y: middle - mark / 2, width: mark, height: mark)
    let tilePath = NSBezierPath(roundedRect: tile, xRadius: mark * 0.26, yRadius: mark * 0.26)
    let glow = NSShadow()
    glow.shadowColor = NSColor(calibratedRed: 0.45, green: 0.3, blue: 1, alpha: 0.6)
    glow.shadowBlurRadius = mark * 0.3
    glow.shadowOffset = NSSize(width: 0, height: -mark * 0.06)
    NSGraphicsContext.saveGraphicsState()
    glow.set()
    purple.setFill()
    tilePath.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGraphicsContext.saveGraphicsState()
    tilePath.addClip()
    background(tile)
    NSGraphicsContext.restoreGraphicsState()
    playMark(center: CGPoint(x: tile.midX + mark * 0.03, y: tile.midY), height: mark * 0.42)

    let textLeft = left + mark + gap
    title.draw(at: CGPoint(x: textLeft - h * 0.008, y: middle - h * 0.02))
    tagline.draw(at: CGPoint(x: textLeft, y: middle - h * 0.105))
}

try? FileManager.default.removeItem(at: brand)
json(["info": info], root.appendingPathComponent("Contents.json"))
json(["assets": [
    ["filename": "App Icon - App Store.imagestack", "idiom": "tv", "role": "primary-app-icon", "size": "1280x768"],
    ["filename": "App Icon.imagestack", "idiom": "tv", "role": "primary-app-icon", "size": "400x240"],
    ["filename": "Top Shelf Image Wide.imageset", "idiom": "tv", "role": "top-shelf-image-wide", "size": "2320x720"],
    ["filename": "Top Shelf Image.imageset", "idiom": "tv", "role": "top-shelf-image", "size": "1920x720"]
], "info": info], brand.appendingPathComponent("Contents.json"))
imagestack("App Icon", sizes: [(400, 240, "1x"), (800, 480, "2x")])
imagestack("App Icon - App Store", sizes: [(1280, 768, "1x")])
imageset(brand.appendingPathComponent("Top Shelf Image.imageset"), base: "topshelf", sizes: [(1920, 720, "1x"), (3840, 1440, "2x")], draw: topShelf)
imageset(brand.appendingPathComponent("Top Shelf Image Wide.imageset"), base: "topshelf-wide", sizes: [(2320, 720, "1x"), (4640, 1440, "2x")], draw: topShelf)
print("Artwork written to \(brand.path)")
