import SwiftUI
import UIKit

/// Profil -> "KI-Konnektor (Claude)": persönlichen Schlüssel erzeugen,
/// anzeigen, kopieren und sperren, plus Anleitung zum Eintragen in Claude.
/// Danach kann Claude über den Konnektor (`supabase/functions/teach-mcp`)
/// Unterordner und Karteikarten direkt in die eigenen Teach-Ordner schreiben.
/// Nur im Cloud-Modus erreichbar (siehe `ProfileView`).
struct ConnectorView: View {
    @EnvironmentObject private var auth: AuthManager

    @State private var status: ConnectorKeyStatus?
    /// Der vollständige Schlüssel direkt nach dem Erzeugen. Bleibt nur so
    /// lange sichtbar, wie diese Ansicht offen ist – der Server kennt ihn
    /// danach nicht mehr.
    @State private var newKey: String?
    @State private var isLoading = false
    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var showRegenerateConfirmation = false
    @State private var showRevokeConfirmation = false
    @State private var copiedItem: CopiedItem?

    private enum CopiedItem {
        case key, url, header
    }

    var body: some View {
        withDialogs(content)
            .navigationTitle("KI-Konnektor")
            .navigationBarTitleDisplayMode(.inline)
            .task { await loadStatus() }
            .refreshable { await loadStatus() }
    }

    // MARK: - Inhalt

    private var content: some View {
        List {
            Section {
                Text("Mit dem Konnektor schreibt Claude Karteikarten direkt in deine Teach-Ordner. Sag Claude zum Beispiel: „Mach mir 10 Karten zu Kapitel 3 in den Unterordner Sozialpsychologie.“")
                    .font(.subheadline)
            }

            statusSection

            if let newKey {
                newKeySection(newKey)
            }

            setupSection
            actionsSection
        }
    }

    @ViewBuilder
    private var statusSection: some View {
        Section("Status") {
            if let status {
                if status.active {
                    Label("Schlüssel aktiv", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    if let prefix = status.keyPrefix {
                        LabeledContent("Schlüssel", value: "\(prefix)…")
                    }
                    if let createdAt = status.createdAt {
                        LabeledContent("Erstellt", value: createdAt.formatted(date: .abbreviated, time: .shortened))
                    }
                    LabeledContent(
                        "Zuletzt benutzt",
                        value: status.lastUsedAt?.formatted(date: .abbreviated, time: .shortened) ?? "noch nie"
                    )
                } else {
                    Label("Kein Schlüssel aktiv", systemImage: "key")
                        .foregroundStyle(.secondary)
                }
            } else if isLoading {
                HStack {
                    ProgressView()
                    Text("Wird geladen…")
                }
            } else {
                Text("Status konnte nicht geladen werden. Zum Aktualisieren runterziehen.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func newKeySection(_ key: String) -> some View {
        Section {
            Text(key)
                .font(.system(.footnote, design: .monospaced))
                .textSelection(.enabled)
            copyButton("Schlüssel kopieren", value: key, item: .key)
        } header: {
            Text("Dein neuer Schlüssel")
        } footer: {
            Text("Kopiere ihn jetzt: Er wird nur dieses eine Mal angezeigt. Wer den Schlüssel hat, kann Karten in deine Ordner schreiben, also teile ihn mit niemandem.")
        }
    }

    @ViewBuilder
    private var setupSection: some View {
        if let status {
            Section {
                Text("1. Öffne Claude (Browser, Desktop-App oder Handy-App) und geh zu Einstellungen → Konnektoren → eigenen Konnektor hinzufügen.")
                Text("2. Name: Teach")
                VStack(alignment: .leading, spacing: 6) {
                    Text("3. Als URL diese Adresse eintragen:")
                    Text(status.connectorURL)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                    copyButton("URL kopieren", value: status.connectorURL, item: .url)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("4. In den erweiterten Einstellungen einen Request-Header hinzufügen: Name „Authorization“, Wert „Bearer “ gefolgt von deinem Schlüssel.")
                    if let newKey {
                        copyButton("Header-Wert kopieren", value: "Bearer \(newKey)", item: .header)
                    }
                }
                Text("5. Speichern und in einem neuen Chat fragen: „Zeig mir meine Teach-Ordner.“")
            } header: {
                Text("In Claude einrichten")
            } footer: {
                Text("Im kostenlosen Claude-Abo ist genau ein eigener Konnektor möglich. Neue Karten erscheinen in der App, sobald du den Unterordner öffnest oder die Liste runterziehst. Claude kann über den Konnektor nur lesen und neu anlegen, nichts ändern oder löschen.")
            }
        }
    }

    @ViewBuilder
    private var actionsSection: some View {
        if let status {
            Section {
                if status.active {
                    Button {
                        showRegenerateConfirmation = true
                    } label: {
                        Label("Neuen Schlüssel erzeugen", systemImage: "arrow.clockwise")
                    }
                    .disabled(isWorking)

                    Button(role: .destructive) {
                        showRevokeConfirmation = true
                    } label: {
                        Label("Schlüssel sperren", systemImage: "lock.slash")
                    }
                    .disabled(isWorking)
                } else {
                    Button {
                        Task { await createKey() }
                    } label: {
                        if isWorking {
                            HStack {
                                ProgressView()
                                Text("Wird erzeugt…")
                            }
                        } else {
                            Label("Schlüssel erzeugen", systemImage: "key.fill")
                        }
                    }
                    .disabled(isWorking)
                }
            } footer: {
                if status.active {
                    Text("Ein gesperrter oder ersetzter Schlüssel funktioniert sofort nicht mehr.")
                }
            }
        }
    }

    private func copyButton(_ title: String, value: String, item: CopiedItem) -> some View {
        Button {
            UIPasteboard.general.string = value
            copiedItem = item
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                if copiedItem == item { copiedItem = nil }
            }
        } label: {
            Label(copiedItem == item ? "Kopiert" : title, systemImage: copiedItem == item ? "checkmark" : "doc.on.doc")
        }
    }

    // MARK: - Dialoge

    /// Ausgelagert, damit die Modifier-Kette kurz bleibt (siehe Type-Checker-
    /// Hinweis in `FolderListView`).
    private func withDialogs<Content: View>(_ content: Content) -> some View {
        content
            .confirmationDialog("Neuen Schlüssel erzeugen?", isPresented: $showRegenerateConfirmation, titleVisibility: .visible) {
                Button("Neuen Schlüssel erzeugen") {
                    Task { await createKey() }
                }
                Button("Abbrechen", role: .cancel) {}
            } message: {
                Text("Der bisherige Schlüssel funktioniert danach nicht mehr. Du musst den neuen in Claude eintragen.")
            }
            .confirmationDialog("Schlüssel sperren?", isPresented: $showRevokeConfirmation, titleVisibility: .visible) {
                Button("Sperren", role: .destructive) {
                    Task { await revokeKey() }
                }
                Button("Abbrechen", role: .cancel) {}
            } message: {
                Text("Claude kann danach nicht mehr in deine Teach-Ordner schreiben, bis du einen neuen Schlüssel erzeugst.")
            }
            .alert("Fehler", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
    }

    // MARK: - Aktionen

    private func loadStatus() async {
        isLoading = true
        defer { isLoading = false }
        await perform { token in
            status = try await ConnectorKeyService.status(accessToken: token)
        }
    }

    private func createKey() async {
        isWorking = true
        defer { isWorking = false }
        await perform { token in
            let result = try await ConnectorKeyService.createKey(accessToken: token)
            status = result
            newKey = result.key
        }
    }

    private func revokeKey() async {
        isWorking = true
        defer { isWorking = false }
        await perform { token in
            status = try await ConnectorKeyService.revokeKey(accessToken: token)
            newKey = nil
        }
    }

    private func perform(_ action: (String) async throws -> Void) async {
        guard let token = await auth.validAccessToken() else {
            errorMessage = APIError.notAuthenticated.errorDescription
            return
        }
        do {
            try await action(token)
        } catch let error as APIError {
            errorMessage = error.errorDescription
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
