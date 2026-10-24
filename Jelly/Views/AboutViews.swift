import SwiftUI

// AppInfo, OpenSourceComponent and the privacy and notice texts live in Shared/AboutData.swift (shared with iPhone and iPad).

/// Long text split into focusable blocks, so the Siri Remote can scroll through it.
struct ScrollableText: View {
    let blocks: [String]
    var font: Font = .system(size: 22)

    init(_ text: String, font: Font = .system(size: 22), maxBlock: Int = 900) {
        self.font = font
        var blocks: [String] = []
        for paragraph in text.components(separatedBy: "\n\n") where !paragraph.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if let last = blocks.last, last.count + paragraph.count < maxBlock {
                blocks[blocks.count - 1] = last + "\n\n" + paragraph
            } else {
                blocks.append(paragraph)
            }
        }
        self.blocks = blocks
    }

    var body: some View {
        ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
            TextBlock(text: block, font: font)
        }
    }

    private struct TextBlock: View {
        let text: String
        let font: Font
        @FocusState private var focused: Bool

        var body: some View {
            Text(text)
                .font(font)
                .foregroundStyle(focused ? .primary : .secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
                .background(Color.white.opacity(focused ? 0.08 : 0), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .focusable()
                .focused($focused)
                .animation(.easeOut(duration: 0.15), value: focused)
        }
    }
}

/// Einstellungen › Info › Open-Source-Lizenzen: every library with its licence text, as LGPL and the permissive licences ask.
struct LicensesView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Open-Source-Lizenzen").font(.title2.weight(.bold)).padding(.leading, 28)
                ScrollableText(String(localized: "Jelly spielt Filme mit AetherEngine und FFmpeg ab und nutzt dafür die folgende freie Software. Danke an alle, die daran mitarbeiten. Ein Klick zeigt Herkunft und vollständigen Lizenztext."),
                               font: .callout)
                    .padding(.bottom, 16)
                ForEach(OpenSourceComponent.all) { component in
                    NavigationLink { LicenseTextView(component: component) } label: {
                        SettingsRowLabel(component.name, detail: [component.version, component.license].compactMap { $0 }.joined(separator: "  ·  "),
                                         chevron: true)
                    }
                }
                Text("DATEN & MARKEN")
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    .padding(.leading, 28).padding(.top, 50)
                ScrollableText(Self.notices, font: .callout)
            }
            .frame(maxWidth: 1200)
            .padding(.vertical, 60)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(SettingsRowStyle())
        .background(Theme.background.ignoresSafeArea())
    }

    static var notices: String { AboutTexts.dataNotices }
}

struct LicenseTextView: View {
    let component: OpenSourceComponent
    @State private var text = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text(component.name).font(.title2.weight(.bold))
                Text([component.version.map { String(localized: "Version \($0)") }, component.license].compactMap { $0 }.joined(separator: "  ·  "))
                    .foregroundStyle(.secondary)
                ScrollableText([component.role, component.copyright, String(localized: "Quelle: \(component.url)", comment: "Source: <URL>")]
                                .compactMap { $0 }.joined(separator: "\n"),
                               font: .callout)
                    .padding(.vertical, 12)
                ScrollableText(text, font: .system(size: 21, design: .monospaced))
            }
            .frame(maxWidth: 1400, alignment: .leading)
            .padding(60)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.background.ignoresSafeArea())
        .task { text = component.licenseText }
    }
}

/// Einstellungen › Info › Datenschutz: what Jelly sends where. The App Store privacy policy says the same.
struct PrivacyNoticeView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text("Datenschutz").font(.title2.weight(.bold)).padding(.leading, 20).padding(.bottom, 12)
                ScrollableText(Self.text, font: .callout)
            }
            .frame(maxWidth: 1300, alignment: .leading)
            .padding(60)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.background.ignoresSafeArea())
    }

    static var text: String { AboutTexts.privacyNotice }
}
