import Foundation

/// Runs the intro detection on pairs of audio files: `intro-check [--credits] a.mp3 b.mp3 [c.mp3 d.mp3 …]`.
@main
struct IntroCheck {
    static func main() throws {
        let credits = CommandLine.arguments.contains("--credits")
        let files = CommandLine.arguments.dropFirst().filter { $0 != "--credits" }.map { URL(fileURLWithPath: $0) }
        for pair in stride(from: 0, to: files.count - 1, by: 2) {
            let started = Date()
            let first = IntroDetector.fingerprint(try IntroDetector.samples(of: files[pair]))
            let second = IntroDetector.fingerprint(try IntroDetector.samples(of: files[pair + 1]))
            let printed = Date().timeIntervalSince(started)
            let match = credits ? IntroDetector.match(first, second, minimum: 25, maximum: 600) : IntroDetector.match(first, second)
            let names = "\(files[pair].deletingPathExtension().lastPathComponent) / \(files[pair + 1].deletingPathExtension().lastPathComponent)"
            let timing = String(format: "(fingerprints %.2fs, match %.2fs)", printed, Date().timeIntervalSince(started) - printed)
            if let match {
                print("\(names): \(format(match.first)) | \(format(match.second)) \(timing)")
            } else {
                print("\(names): no intro \(timing)")
            }
        }
    }

    static func format(_ range: ClosedRange<Double>) -> String {
        func clock(_ seconds: Double) -> String { String(format: "%d:%04.1f", Int(seconds) / 60, seconds.truncatingRemainder(dividingBy: 60)) }
        return "\(clock(range.lowerBound))–\(clock(range.upperBound)) (\(Int(range.upperBound - range.lowerBound)) s)"
    }
}
