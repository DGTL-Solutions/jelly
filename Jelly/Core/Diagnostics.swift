import Foundation
import AVFoundation

/// Records what the device can decode and how each title was played, so behaviour on real hardware can be checked:
/// `xcrun devicectl device copy from --device <UDID> --domain-type appDataContainer --domain-identifier <bundle ID>
///  --source Library/Caches/jelly-diagnostics.log --destination jelly-diagnostics.log`
enum Diagnostics {
    static let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("jelly-diagnostics.log")
    private static let queue = DispatchQueue(label: "jelly.diagnostics")
    private static let maxSize = 512 * 1024

    static func log(_ message: String) {
        let line = "\(Date().formatted(.iso8601)) \(message)\n"
        queue.async {
            if let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int, size > maxSize {
                try? FileManager.default.removeItem(at: url)
            }
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                try? handle.close()
            } else {
                try? Data(line.utf8).write(to: url)
            }
        }
    }

    /// Strips access tokens before URLs end up in the log.
    static func redact(_ text: String) -> String {
        text.replacingOccurrences(of: #"(?i)(api_?key|token)=[^&\s"]+"#, with: "$1=…", options: .regularExpression)
    }

    #if os(tvOS)
    static func logDevice() {
        let caps = DeviceCapabilities.current
        let modes = AVPlayer.availableHDRModes
        let session = AVAudioSession.sharedInstance()
        let outputs = session.currentRoute.outputs.map { "\($0.portType.rawValue)(\($0.channels?.count ?? 0)ch)" }.joined(separator: ",")
        log("device dv=\(caps.dolbyVision) dv7=\(caps.dolbyVisionProfile7) av1hw=\(caps.av1Hardware) "
            + "hdr=[\(modes.contains(.dolbyVision) ? "DV " : "")\(modes.contains(.hdr10) ? "HDR10 " : "")\(modes.contains(.hlg) ? "HLG" : "")] "
            + "audioOut=\(outputs) maxChannels=\(session.maximumOutputNumberOfChannels)")
    }
    #endif
}
