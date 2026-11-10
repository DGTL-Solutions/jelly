import SwiftUI
import CoreImage.CIFilterBuiltins

/// A QR code for `text`, drawn crisp at any size.
struct QRCodeView: View {
    let text: String

    var body: some View {
        if let image = Self.image(text) {
            Image(decorative: image, scale: 1).interpolation(.none).resizable().scaledToFit()
        }
    }

    private static func image(_ text: String) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)) else { return nil }
        return CIContext().createCGImage(output, from: output.extent)
    }
}

/// What the QR code on the Apple TV carries: the server and the Quick Connect code to approve.
struct SignInLink: Identifiable {
    var id: String { code }
    var server: URL
    var serverID: String?
    var code: String

    var url: URL {
        var components = URLComponents()
        components.scheme = "jelly"
        components.host = "signin"
        components.queryItems = [URLQueryItem(name: "server", value: server.absoluteString), URLQueryItem(name: "code", value: code)]
            + (serverID.map { [URLQueryItem(name: "id", value: $0)] } ?? [])
        return components.url!
    }

    init(server: URL, serverID: String?, code: String) { self.server = server; self.serverID = serverID; self.code = code }

    init?(_ url: URL) {
        guard url.scheme == "jelly", url.host() == "signin",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let server = items.first(where: { $0.name == "server" })?.value.flatMap(URL.init(string:)),
              let code = items.first(where: { $0.name == "code" })?.value, code.count >= 4, code.allSatisfy(\.isNumber) else { return nil }
        self.server = server
        self.code = code
        serverID = items.first { $0.name == "id" }?.value
    }
}
