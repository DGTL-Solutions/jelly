import SwiftUI

/// Einstellungen › Info › Open-Source-Lizenzen: every library with its licence text, as LGPL and the permissive licences ask.
struct LicensesScreen: View {
    var body: some View {
        List {
            Section {
                ForEach(OpenSourceComponent.all) { component in
                    NavigationLink(value: SettingsRoute.license(component.name)) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: component.name)
                            Text([component.version, component.license].compactMap { $0 }.joined(separator: " · "))
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("Jelly spielt Filme mit AetherEngine und FFmpeg ab und nutzt dafür die folgende freie Software. Danke an alle, die daran mitarbeiten.")
                    .textCase(nil)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 8)
            }
            Section("DATEN & MARKEN") {
                Text(AboutTexts.dataNotices)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(.vertical, 4)
            }
        }
        .accountReadableWidth()
        .navigationTitle("Open-Source-Lizenzen")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// One library: what it does, who holds the copyright, where it comes from, and the full licence text.
struct LicenseTextScreen: View {
    let component: OpenSourceComponent
    @State private var text: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: component.name).font(.title2.bold())
                    Text([component.version.map { String(localized: "Version \($0)") }, component.license].compactMap { $0 }.joined(separator: " · "))
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 8) {
                    if let role = component.role { Text(role) }
                    if let copyright = component.copyright { Text(verbatim: copyright).foregroundStyle(.secondary) }
                    if let url = URL(string: component.url), url.scheme?.hasPrefix("http") == true {
                        Link(destination: url) {
                            Label(url.host(percentEncoded: false).map { $0 + url.path(percentEncoded: false) } ?? component.url,
                                  systemImage: "arrow.up.right.square")
                                .multilineTextAlignment(.leading)
                        }
                    } else {
                        Text("Quelle: \(component.url)", comment: "Source: <URL>").foregroundStyle(.secondary)
                    }
                }
                .font(.callout)
                Divider()
                if let text {
                    Text(text)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                } else {
                    ProgressView().frame(maxWidth: .infinity)
                }
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding()
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(Text(verbatim: component.name))
        .navigationBarTitleDisplayMode(.inline)
        .task {
            let component = component
            text = await Task.detached { Self.reflow(component.licenseText) }.value
        }
    }

    /// Licence files are wrapped for 80-column terminals; on a phone the paragraphs read better rejoined.
    nonisolated static func reflow(_ text: String) -> String {
        var paragraphs: [String] = []
        var current: [String] = []
        for line in text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                if !current.isEmpty { paragraphs.append(current.joined(separator: " ")); current = [] }
            } else {
                current.append(trimmed)
            }
        }
        if !current.isEmpty { paragraphs.append(current.joined(separator: " ")) }
        return paragraphs.joined(separator: "\n\n")
    }
}

/// Einstellungen › Info › Datenschutz: what Jelly sends where, with the full privacy policy on the web.
struct PrivacyNoticeScreen: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(AboutTexts.privacyNotice)
                    .font(.body)
                    .textSelection(.enabled)
                if let url = URL(string: AppInfo.localizedPrivacyURL) {
                    Link(destination: url) {
                        Label("Vollständige Datenschutzerklärung", systemImage: "arrow.up.right.square")
                    }
                    .font(.body.weight(.semibold))
                }
            }
            .frame(maxWidth: 680, alignment: .leading)
            .padding()
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Datenschutz")
        .navigationBarTitleDisplayMode(.inline)
    }
}
