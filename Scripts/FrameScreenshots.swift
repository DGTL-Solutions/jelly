// Puts the raw App Store screenshots (AppStore/screenshots-raw/<device>/<locale>) on a background in Jelly's colours
// with a headline and a line below from AppStore/captions.json, at the size Apple requires (the raw size).
// Apple TV goes to AppStore/screenshots/<locale>, iPhone and iPad to AppStore/screenshots-ios/<locale>/<device>.
//   swift Scripts/FrameScreenshots.swift
import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("AppStore")
let captions = try! JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("captions.json")))
    as! [String: [String: [String: [String]]]]

/// Text sizes per device, in pixels of the canvas.
let typeSizes: [String: (headline: CGFloat, line: CGFloat)] = ["tv": (64, 30), "iphone": (96, 46), "ipad": (118, 56)]
let brandStart = NSColor(calibratedRed: 0.67, green: 0.36, blue: 0.86, alpha: 1)
let brandEnd = NSColor(calibratedRed: 0.0, green: 0.64, blue: 0.86, alpha: 1)

func text(_ string: String, size: CGFloat, weight: NSFont.Weight, color: NSColor) -> NSAttributedString {
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    paragraph.lineBreakMode = .byWordWrapping
    paragraph.lineHeightMultiple = 1.02
    return NSAttributedString(string: string, attributes: [
        .font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color, .paragraphStyle: paragraph,
        .kern: (weight == .bold || weight == .heavy) ? -size * 0.012 : 0,
    ])
}

func frame(_ input: URL, device: String, caption: [String], output: URL) {
    guard let raw = NSImage(contentsOf: input), let rep = raw.representations.first else { return }
    let width = CGFloat(rep.pixelsWide), height = CGFloat(rep.pixelsHigh)
    let landscape = width > height
    var sizes = typeSizes[device]!
    if device == "iphone" && landscape { sizes = (84, 40) }

    let canvas = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width), pixelsHigh: Int(height), bitsPerSample: 8,
                                  samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                  bytesPerRow: 0, bitsPerPixel: 0)!
    canvas.size = NSSize(width: width, height: height)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: canvas)
    let bounds = NSRect(x: 0, y: 0, width: width, height: height)

    // Background: the violet-to-blue gradient of the new app icon, a little deeper for contrast, with a bright glow
    // behind the screenshot. Light and colourful so the first three images stand out between the dark app screens in the search.
    NSGradient(colors: [NSColor(calibratedRed: 0.44, green: 0.26, blue: 0.96, alpha: 1),
                        NSColor(calibratedRed: 0.26, green: 0.44, blue: 0.98, alpha: 1),
                        NSColor(calibratedRed: 0.06, green: 0.60, blue: 1.0, alpha: 1)])!.draw(in: bounds, angle: -62)
    let glow = NSRect(x: width * 0.02, y: height * 0.02, width: width * 0.96, height: height * 0.78)
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.20), NSColor.white.withAlphaComponent(0.0)])!
        .draw(in: NSBezierPath(ovalIn: glow), relativeCenterPosition: NSPoint(x: 0.0, y: 0.25))

    // Headline and line below, centred at the top.
    let margin = width * (landscape ? 0.07 : 0.06)
    let textWidth = width - 2 * margin
    let headline = text(caption[0], size: sizes.headline, weight: .heavy, color: .white)
    let line = text(caption[1], size: sizes.line, weight: .medium, color: NSColor.white.withAlphaComponent(0.94))
    let options: NSString.DrawingOptions = [.usesLineFragmentOrigin, .usesFontLeading]
    let headlineHeight = ceil(headline.boundingRect(with: NSSize(width: textWidth, height: 10_000), options: options).height)
    let lineHeight = ceil(line.boundingRect(with: NSSize(width: textWidth, height: 10_000), options: options).height)
    let top = height * (landscape ? 0.045 : 0.05)
    headline.draw(with: NSRect(x: margin, y: height - top - headlineHeight, width: textWidth, height: headlineHeight), options: options)
    let lineTop = top + headlineHeight + sizes.line * 0.45
    line.draw(with: NSRect(x: margin, y: height - lineTop - lineHeight, width: textWidth, height: lineHeight), options: options)

    // The screenshot, scaled into the space below with rounded corners and a shadow.
    let areaTop = lineTop + lineHeight + height * (landscape ? 0.035 : 0.028)
    let bottom = height * (landscape ? 0.045 : 0.035)
    let available = NSSize(width: width * (landscape ? 0.86 : 0.84), height: height - areaTop - bottom)
    // iPhone and iPad get a device frame (black bezel, Dynamic Island on the iPhone); the Apple TV image stays frameless.
    let k: CGFloat = device == "tv" ? 0 : (device == "iphone" ? 0.036 : 0.03)
    let scale = min(available.width / (width * (1 + 2 * k)), available.height / (height * (1 + 2 * k)))
    let bezel = k * width * scale
    let shot = NSRect(x: (width - width * scale) / 2, y: bottom + bezel, width: width * scale, height: height * scale)
    let screenRadius = shot.width * (device == "iphone" ? (landscape ? 0.06 : 0.125) : (device == "ipad" ? 0.032 : 0.018))
    let body = shot.insetBy(dx: -bezel, dy: -bezel)
    let bodyRadius = screenRadius + bezel
    let bodyPath = NSBezierPath(roundedRect: body, xRadius: bodyRadius, yRadius: bodyRadius)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor(calibratedRed: 0.05, green: 0.03, blue: 0.25, alpha: 0.5)
    shadow.shadowBlurRadius = width * 0.03
    shadow.shadowOffset = NSSize(width: 0, height: -width * 0.01)
    shadow.set()
    (device == "tv" ? NSColor.black : NSColor(calibratedWhite: 0.07, alpha: 1)).setFill()
    bodyPath.fill()
    NSGraphicsContext.restoreGraphicsState()
    if device != "tv" {
        // A fine light edge along the frame, brighter at the top, like titanium catching the light.
        NSGradient(colors: [NSColor(calibratedWhite: 0.55, alpha: 1), NSColor(calibratedWhite: 0.16, alpha: 1), NSColor(calibratedWhite: 0.38, alpha: 1)])!
            .draw(in: { let p = NSBezierPath(roundedRect: body, xRadius: bodyRadius, yRadius: bodyRadius); p.append(NSBezierPath(roundedRect: body.insetBy(dx: width * 0.0014, dy: width * 0.0014), xRadius: bodyRadius, yRadius: bodyRadius).reversed); return p }(), angle: -60)
    }
    let clip = NSBezierPath(roundedRect: shot, xRadius: screenRadius, yRadius: screenRadius)
    NSGraphicsContext.saveGraphicsState()
    clip.addClip()
    raw.draw(in: shot, from: .zero, operation: .sourceOver, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    if device == "iphone" && !landscape {
        let islandWidth = shot.width * 0.285, islandHeight = shot.width * 0.082
        let island = NSRect(x: shot.midX - islandWidth / 2, y: shot.maxY - shot.width * 0.026 - islandHeight, width: islandWidth, height: islandHeight)
        NSColor.black.setFill()
        NSBezierPath(roundedRect: island, xRadius: islandHeight / 2, yRadius: islandHeight / 2).fill()
    }
    if device == "tv" {
        NSColor.white.withAlphaComponent(0.12).setStroke()
        clip.lineWidth = max(2, width * 0.0015)
        clip.stroke()
    }

    NSGraphicsContext.restoreGraphicsState()
    try? FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
    try! canvas.representation(using: .png, properties: [:])!.write(to: output)
    print("  \(output.path.replacingOccurrences(of: root.deletingLastPathComponent().path + "/", with: ""))")
}

for (device, files) in captions {
    for locale in ["de-DE", "en-US", "fr-FR", "es-ES", "it-IT", "nl-NL", "pt-BR", "da-DK", "sv-SE", "pl-PL"] {
        let language = String(locale.prefix(2))
        for (name, texts) in files.sorted(by: { $0.key < $1.key }) {
            guard let caption = texts[language] else { continue }
            let input = root.appendingPathComponent("screenshots-raw/\(device)/\(locale)/\(name).png")
            let output = device == "tv"
                ? root.appendingPathComponent("screenshots/\(locale)/\(name).png")
                : root.appendingPathComponent("screenshots-ios/\(locale)/\(device)/\(name).png")
            frame(input, device: device, caption: caption, output: output)
        }
    }
}
