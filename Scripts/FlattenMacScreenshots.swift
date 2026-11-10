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
        guard let image = NSImage(contentsOf: raw.appendingPathComponent("\(locale)/\(name)")),
              let canvas = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1440, pixelsHigh: 900, bitsPerSample: 8, samplesPerPixel: 3,
                                            hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { continue }
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: canvas)
        NSColor.black.setFill()
        NSRect(x: 0, y: 0, width: 1440, height: 900).fill()
        image.draw(in: NSRect(x: 0, y: 0, width: 1440, height: 900))
        try? canvas.representation(using: .png, properties: [:])?.write(to: output.appendingPathComponent(name))
        print("\(locale)/\(name)")
    }
}
