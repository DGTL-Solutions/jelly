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
        let center = CGPoint(x: rect.width * x, y: rect.height * y)
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

func imagestack(_ name: String, sizes: [(Int, Int, String)]) {
    let stack = brand.appendingPathComponent("\(name).imagestack")
    json(["info": info, "layers": [["filename": "Front.imagestacklayer"], ["filename": "Back.imagestacklayer"]]],
         stack.appendingPathComponent("Contents.json"))
    for layer in ["Front", "Back"] {
        let dir = stack.appendingPathComponent("\(layer).imagestacklayer")
        json(["info": info], dir.appendingPathComponent("Contents.json"))
        imageset(dir.appendingPathComponent("Content.imageset"), base: layer.lowercased(), sizes: sizes) { rect in
            if layer == "Back" { background(rect) } else { playMark(center: CGPoint(x: rect.midX, y: rect.midY), height: rect.height * 0.42) }
        }
    }
}

func topShelf(_ rect: CGRect) {
    background(rect)
    let h = rect.height
    playMark(center: CGPoint(x: h * 0.42, y: rect.midY), height: h * 0.3)
    let title = NSAttributedString(string: "Jelly", attributes: [
        .font: NSFont.systemFont(ofSize: h * 0.2, weight: .bold), .foregroundColor: NSColor.white
    ])
    let tagline = NSAttributedString(string: "Dein Jellyfin. Auf dem großen Bildschirm.", attributes: [
        .font: NSFont.systemFont(ofSize: h * 0.06, weight: .medium), .foregroundColor: NSColor.white.withAlphaComponent(0.85)
    ])
    title.draw(at: CGPoint(x: h * 0.72, y: rect.midY - h * 0.04))
    tagline.draw(at: CGPoint(x: h * 0.74, y: rect.midY - h * 0.13))
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
