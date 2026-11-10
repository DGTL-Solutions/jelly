// Turns the raw Mac window pictures (AppStore/screenshots-raw/mac/<locale>, 1440×900 with transparent window corners)
// into App Store images without transparency: AppStore/screenshots-mac/<locale>.
//   swift Scripts/FlattenMacScreenshots.swift
import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("AppStore")
let raw = root.appendingPathComponent("screenshots-raw/mac")
for locale in (try? FileManager.default.contentsOfDirectory(atPath: raw.path)) ?? [] where !locale.hasPrefix(".") {
    let output = root.appendingPathComponent("screenshots-mac/\(locale)")
    try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    for name in ((try? FileManager.default.contentsOfDirectory(atPath: raw.appendingPathComponent(locale).path)) ?? []).sorted() where name.hasSuffix(".png") {
        guard let image = NSImage(contentsOf: raw.appendingPathComponent("\(locale)/\(name)"))?.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let context = CGContext(data: nil, width: 1440, height: 900, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { continue }
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1440, height: 900))
        context.draw(image, in: CGRect(x: 0, y: 0, width: 1440, height: 900))
        guard let flat = context.makeImage() else { continue }
        try? NSBitmapImageRep(cgImage: flat).representation(using: .png, properties: [:])?.write(to: output.appendingPathComponent(name))
        print("\(locale)/\(name)")
    }
}
