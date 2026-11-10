import SwiftUI

/// The Apple TV shows a QR code with a Quick Connect code; this sheet approves it with the profile signed in on this iPhone.
struct SignInApprovalSheet: View {
    let link: SignInLink
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var working = false
    @State private var done = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 22) {
            Image(systemName: done ? "checkmark.circle.fill" : "appletv").font(.system(size: 64)).foregroundStyle(done ? .green : Theme.accent)
            Text(done ? "Apple TV angemeldet" : "Apple TV anmelden?").font(.title2.bold())
            if model.session == nil {
                Text("Melde dich zuerst in Jelly auf diesem iPhone an.").multilineTextAlignment(.center).foregroundStyle(.secondary)
            } else if !done {
                VStack(spacing: 6) {
                    Text("Code \(link.code)").font(.title3.monospacedDigit().bold())
                    Text("Der Apple TV wird mit \(model.session?.name ?? "") auf \(model.session?.serverName ?? link.server.host() ?? "") angemeldet.")
                        .multilineTextAlignment(.center).foregroundStyle(.secondary)
                }
            }
            if let error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).multilineTextAlignment(.center) }
            Spacer(minLength: 8)
            if done {
                Button("Fertig") { dismiss() }.buttonStyle(.borderedProminent).controlSize(.large)
            } else if model.session != nil {
                Button { Task { await approve() } } label: {
                    if working { ProgressView() } else { Text("Anmelden").frame(maxWidth: .infinity) }
                }
                .buttonStyle(.borderedProminent).controlSize(.large).disabled(working)
                Button("Abbrechen", role: .cancel) { dismiss() }
            } else {
                Button("Schließen") { dismiss() }
            }
        }
        .padding(28)
        .presentationDetents([.medium])
    }

    private func approve() async {
        working = true
        defer { working = false }
        do {
            try await model.approve(link)
            done = true
            error = nil
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}
