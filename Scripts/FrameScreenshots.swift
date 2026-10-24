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
        .kern: weight == .bold ? -size * 0.012 : 0,
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

    // Background: Jelly's night colours with a soft glow of the brand gradient behind the screenshot.
    NSGradient(colors: [NSColor(calibratedRed: 0.11, green: 0.06, blue: 0.25, alpha: 1),
                        NSColor(calibratedRed: 0.04, green: 0.07, blue: 0.17, alpha: 1)])!.draw(in: bounds, angle: -70)
    let glow = NSRect(x: width * 0.05, y: height * 0.08, width: width * 0.9, height: height * 0.7)
    NSGradient(colors: [brandStart.withAlphaComponent(0.42), brandEnd.withAlphaComponent(0.0)])!
        .draw(in: NSBezierPath(ovalIn: glow), relativeCenterPosition: NSPoint(x: -0.2, y: 0.1))

    // Headline and line below, centred at the top.
    let margin = width * (landscape ? 0.07 : 0.06)
    let textWidth = width - 2 * margin
    let headline = text(caption[0], size: sizes.headline, weight: .bold, color: .white)
    let line = text(caption[1], size: sizes.line, weight: .regular, color: NSColor.white.withAlphaComponent(0.78))
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
    let scale = min(available.width / width, available.height / height)
    let shot = NSRect(x: (width - width * scale) / 2, y: bottom, width: width * scale, height: height * scale)
    let radius = shot.width * (device == "iphone" ? (landscape ? 0.03 : 0.075) : (device == "ipad" ? 0.03 : 0.018))
    let clip = NSBezierPath(roundedRect: shot, xRadius: radius, yRadius: radius)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.55)
    shadow.shadowBlurRadius = width * 0.025
    shadow.shadowOffset = NSSize(width: 0, height: -width * 0.006)
    shadow.set()
    NSColor.black.setFill()
    clip.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGraphicsContext.saveGraphicsState()
    clip.addClip()
    raw.draw(in: shot, from: .zero, operation: .sourceOver, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    NSColor.white.withAlphaComponent(0.12).setStroke()
    clip.lineWidth = max(2, width * 0.0015)
    clip.stroke()

    NSGraphicsContext.restoreGraphicsState()
    try? FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
    try! canvas.representation(using: .png, properties: [:])!.write(to: output)
    print("  \(output.path.replacingOccurrences(of: root.deletingLastPathComponent().path + "/", with: ""))")
}

for (device, files) in captions {
    for locale in ["de-DE", "en-US"] {
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
