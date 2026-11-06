import AppKit

/// Renders the layered tvOS app icon and Top Shelf images into Jelly/Assets.xcassets.
/// Run: xcrun swift Scripts/GenerateArtwork.swift
let root = URL(fileURLWithPath: "Jelly/Assets.xcassets")
let brand = root.appendingPathComponent("App Icon & Top Shelf Image.brandassets")
let purple = NSColor(calibratedRed: 0.55, green: 0.25, blue: 0.85, alpha: 1)
let brandStart = NSColor(calibratedRed: 0.42, green: 0.25, blue: 0.98, alpha: 1)   // violet to blue, as in Design/AppIcon-v2.icon
let brandEnd = NSColor(calibratedRed: 0.08, green: 0.62, blue: 1.0, alpha: 1)
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

/// Jelly's logo: one connected glass jellyfish swimming to the right, the bell doubling as the play shape.
/// The outline is the one in Design/AppIcon-v2.icon (the source of the iPhone and iPad icon).
let jellyPoints: [CGPoint] = {
    let svg = try! String(contentsOfFile: "Design/AppIcon-v2.icon/Assets/jelly.svg", encoding: .utf8)
    let d = svg.components(separatedBy: " d=\"")[1].components(separatedBy: "\"")[0]
    return d.split(whereSeparator: { "MLZ ".contains($0) }).map { token in
        let n = token.split(separator: ",").map { Double($0)! }
        return CGPoint(x: n[0], y: n[1])
    }
}()
let jellyBox: CGRect = {
    let xs = jellyPoints.map(\.x), ys = jellyPoints.map(\.y)
    return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
}()

func jellyPath(center: CGPoint, height: CGFloat) -> NSBezierPath {
    let scale = height / jellyBox.height
    let path = NSBezierPath()
    for (i, p) in jellyPoints.enumerated() {
        let point = CGPoint(x: center.x + (p.x - jellyBox.midX) * scale, y: center.y - (p.y - jellyBox.midY) * scale)
        if i == 0 { path.move(to: point) } else { path.line(to: point) }
    }
    path.close()
    path.lineJoinStyle = .round
    return path
}

/// The glass body: milky white, brighter at the top left, with a fine light edge.
func jellyGlass(center: CGPoint, height: CGFloat) {
    let path = jellyPath(center: center, height: height)
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.97), NSColor.white.withAlphaComponent(0.60)])!.draw(in: path, angle: -60)
    NSColor.white.withAlphaComponent(0.9).setStroke()
    path.lineWidth = max(1, height * 0.006)
    path.stroke()
}

/// The soft shadow that gives the glass its depth: an own layer on the Apple TV, where it moves apart on focus.
func jellyShadow(center: CGPoint, height: CGFloat) {
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor(calibratedRed: 0.10, green: 0.05, blue: 0.42, alpha: 0.5)
    shadow.shadowBlurRadius = height * 0.06
    shadow.shadowOffset = NSSize(width: 0, height: -height * 0.035)
    shadow.set()
    NSColor(calibratedRed: 0.20, green: 0.25, blue: 0.85, alpha: 0.55).setFill()
    jellyPath(center: center, height: height).fill()
    NSGraphicsContext.restoreGraphicsState()
}

func logo(center: CGPoint, height: CGFloat) {
    jellyShadow(center: center, height: height)
    jellyGlass(center: center, height: height)
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
            // Gradient ground, the shadow above it and the glass jellyfish on top: three layers that tilt apart when focused.
            let center = CGPoint(x: rect.midX, y: rect.midY)
            switch layer {
            case "Back": NSGradient(starting: brandStart, ending: brandEnd)!.draw(in: rect, angle: -32)
            case "Middle": jellyShadow(center: center, height: rect.height * 0.62)
            default: jellyGlass(center: center, height: rect.height * 0.62)
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

    // Logo and name only: the image can't follow the device language, so it carries no sentence.
    let markHeight = h * 0.26, mark = markHeight * 1.42
    let title = NSAttributedString(string: "Jelly", attributes: [
        .font: NSFont.systemFont(ofSize: h * 0.22, weight: .bold), .foregroundColor: NSColor.white, .kern: -h * 0.004
    ])
    let gap = h * 0.075
    let size = title.size()
    let left = rect.midX - (mark + gap + size.width) / 2
    let middle = h * 0.54
    logo(center: CGPoint(x: left + mark / 2, y: middle), height: markHeight)
    // Centres the capital letters on the logo; draw(at:) places the bottom of the descenders.
    let font = NSFont.systemFont(ofSize: h * 0.22, weight: .bold)
    title.draw(at: CGPoint(x: left + mark + gap, y: middle - font.capHeight / 2 + font.descender))
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
// iPhone and iPad: the Liquid Glass icon is JellyMobile/AppIcon.icon (a copy of Design/AppIcon-v2.icon, built by Xcode 26 or later),
// so no AppIcon.appiconset any more: both with the same name would collide.
let mobile = URL(fileURLWithPath: "JellyMobile/Assets.xcassets")
try? FileManager.default.removeItem(at: mobile.appendingPathComponent("AppIcon.appiconset"))
json(["info": info], mobile.appendingPathComponent("Contents.json"))
print("Artwork written to \(brand.path) and \(mobile.path)")
