import SwiftUI

// Placeholder screens – replaced by the account work package.

struct OnboardingFlow: View {
    var body: some View { Text("Willkommen bei Jelly") }
}

struct ProfilePickerScreen: View {
    var body: some View { Text("Wer schaut gerade?") }
}

struct SettingsScreen: View {
    var body: some View { NavigationStack { Text("Einstellungen").navigationTitle("Einstellungen") } }
}

struct MobilePaywall: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View { Button("Später") { dismiss() } }
}
