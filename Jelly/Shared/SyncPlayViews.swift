import SwiftUI

/// "Gemeinsam schauen": the SyncPlay groups on the server – join one, start one, see who is in, leave.
struct SyncPlayGroupsView: View {
    let onClose: () -> Void
    @EnvironmentObject private var model: AppModel
    @ObservedObject var syncPlay: SyncPlay

    var body: some View {
        NavigationStack {
            List {
                if let group = syncPlay.group {
                    Section {
                        ForEach(group.participants, id: \.self) { Label($0, systemImage: "person.fill") }
                    } header: {
                        Text(group.groupName)
                    } footer: {
                        Text("Was jemand in der Gruppe startet, pausiert oder vorspult, passiert bei allen. Wähle einfach einen Film oder eine Folge und drücke Abspielen.")
                    }
                    Section {
                        Button(role: .destructive) { Task { await syncPlay.leave(); await syncPlay.refresh() } } label: {
                            Label("Gruppe verlassen", systemImage: "rectangle.portrait.and.arrow.right")
                        }
                    }
                } else {
                    Section {
                        ForEach(syncPlay.available) { group in
                            Button { Task { await syncPlay.join(group) } } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(group.groupName)
                                    Text(group.participants.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        Button { Task { await syncPlay.create(name: String(localized: "Gruppe von \(model.session?.name ?? "Jelly")")) } } label: {
                            Label("Neue Gruppe starten", systemImage: "plus")
                        }
                    } header: {
                        Text("Gruppen auf diesem Server")
                    } footer: {
                        Text("Alle in einer Gruppe sehen dieselbe Sekunde desselben Films – jeder auf seinem Gerät, mit seinem eigenen Konto auf diesem Server.")
                    }
                }
                if let error = syncPlay.error {
                    Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                }
            }
            .navigationTitle("Gemeinsam schauen")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Fertig", action: onClose) } }
        }
        .task {
            await syncPlay.refresh()
            // New groups of others appear while the list is open.
            while !Task.isCancelled, syncPlay.group == nil {
                try? await Task.sleep(for: .seconds(4))
                if syncPlay.group == nil { await syncPlay.refresh() }
            }
        }
    }
}
