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

/// Jelly's logo, flat and crisp like YouTube's: a rounded play button in the brand gradient with a white triangle.
let brandStart = NSColor(calibratedRed: 0.67, green: 0.36, blue: 0.86, alpha: 1)   // Theme.brand in the app
let brandEnd = NSColor(calibratedRed: 0.0, green: 0.64, blue: 0.86, alpha: 1)

func logoButton(center: CGPoint, height: CGFloat) {
    let width = height * 1.42
    let rect = CGRect(x: center.x - width / 2, y: center.y - height / 2, width: width, height: height)
    let path = NSBezierPath(roundedRect: rect, xRadius: height * 0.28, yRadius: height * 0.28)
    NSGradient(starting: brandStart, ending: brandEnd)!.draw(in: path, angle: -32)
}

/// A right-pointing triangle with just slightly softened corners, optically centred on `center`.
func logoTriangle(center: CGPoint, height: CGFloat, color: NSColor = .white) {
    let round = height * 0.09
    let h = height - round, w = h * 0.88
    let x = center.x - w / 2 + w * 0.06
    let path = NSBezierPath()
    path.move(to: CGPoint(x: x, y: center.y + h / 2))
    path.line(to: CGPoint(x: x + w, y: center.y))
    path.line(to: CGPoint(x: x, y: center.y - h / 2))
    path.close()
    path.lineJoinStyle = .round
    path.lineWidth = round
    color.setFill()
    color.setStroke()
    path.fill()
    path.stroke()
}

func logo(center: CGPoint, height: CGFloat) {
    logoButton(center: center, height: height)
    logoTriangle(center: center, height: height * 0.44)
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
    let layers = ["Front", "Middle", "Back"]
    json(["info": info, "layers": layers.map { ["filename": "\($0).imagestacklayer"] }], stack.appendingPathComponent("Contents.json"))
    for layer in layers {
        let dir = stack.appendingPathComponent("\(layer).imagestacklayer")
        json(["info": info], dir.appendingPathComponent("Contents.json"))
        imageset(dir.appendingPathComponent("Content.imageset"), base: layer.lowercased(), sizes: sizes) { rect in
            // White ground, the button above it and the triangle on top: three layers that tilt apart when focused.
            let center = CGPoint(x: rect.midX, y: rect.midY)
            switch layer {
            case "Back": NSColor.white.setFill(); rect.fill()
            case "Middle": logoButton(center: center, height: rect.height * 0.56)
            default: logoTriangle(center: center, height: rect.height * 0.56 * 0.44)
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

    let markHeight = h * 0.24, mark = markHeight * 1.42
    let title = NSAttributedString(string: "Jelly", attributes: [
        .font: NSFont.systemFont(ofSize: h * 0.19, weight: .bold), .foregroundColor: NSColor.white, .kern: -h * 0.004
    ])
    let tagline = NSAttributedString(string: "Deine Filme und Serien von Jellyfin – direkt auf dem Apple TV.", attributes: [
        .font: NSFont.systemFont(ofSize: h * 0.05, weight: .medium), .foregroundColor: NSColor.white.withAlphaComponent(0.78)
    ])
    let gap = h * 0.07
    let textWidth = max(title.size().width, tagline.size().width)
    let left = rect.midX - (mark + gap + textWidth) / 2
    let middle = h * 0.54
    logo(center: CGPoint(x: left + mark / 2, y: middle), height: markHeight)

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
