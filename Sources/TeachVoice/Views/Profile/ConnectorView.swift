import SwiftUI
import UIKit

/// Profil -> "KI-Konnektor (Claude)": persönlichen Schlüssel erzeugen und
/// daraus den "persönlichen Claude-Link" anzeigen, kopieren und sperren,
/// plus Anleitung zum Einfügen in Claude. Danach kann Claude über den
/// Konnektor (`supabase/functions/teach-mcp`) Ordner, Unterordner und
/// Karteikarten direkt in die eigene Teach-Bibliothek schreiben.
/// Nur im Cloud-Modus erreichbar (siehe `ProfileView`).
struct ConnectorView: View {
    @EnvironmentObject private var auth: AuthManager

    @State private var status: ConnectorKeyStatus?
    /// Der vollständige Schlüssel für den Link: direkt nach dem Erzeugen vom
    /// Server, später aus dem Keychain dieses Geräts (`ConnectorLink`).
    @State private var linkKey: String?
    @State private var isLoading = false
    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var showRegenerateConfirmation = false
    @State private var showRevokeConfirmation = false
    @State private var linkCopied = false

    private var personalLink: String? {
        guard let status, status.active, let linkKey else { return nil }
        return ConnectorLink.make(base: status.connectorURL, key: linkKey)
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
            linkSection
            setupSection
            actionsSection
        }
    }

    @ViewBuilder
    private var statusSection: some View {
        Section("Status") {
            if let status {
                if status.active {
                    Label("Konnektor aktiv", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    if let createdAt = status.createdAt {
                        LabeledContent("Erstellt", value: createdAt.formatted(date: .abbreviated, time: .shortened))
                    }
                    LabeledContent(
                        "Zuletzt benutzt",
                        value: status.lastUsedAt?.formatted(date: .abbreviated, time: .shortened) ?? "noch nie"
                    )
                } else {
                    Label("Noch kein Link erzeugt", systemImage: "link")
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

    @ViewBuilder
    private var linkSection: some View {
        if let personalLink {
            Section {
                Text(personalLink)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                Button {
                    UIPasteboard.general.string = personalLink
                    linkCopied = true
                    Task {
                        try? await Task.sleep(for: .seconds(1.5))
                        linkCopied = false
                    }
                } label: {
                    Label(linkCopied ? "Kopiert" : "Link kopieren", systemImage: linkCopied ? "checkmark" : "doc.on.doc")
                }
            } header: {
                Text("Dein persönlicher Claude-Link")
            } footer: {
                Text("Behandle den Link wie ein Passwort: Wer ihn hat, kann Karten in deine Ordner schreiben. Teile ihn mit niemandem.")
            }
        } else if let status, status.active {
            Section {
                Text("Der Link ist auf diesem Gerät nicht gespeichert (z.B. weil er auf einem anderen Gerät erzeugt wurde). Erzeuge unten einen neuen Link und trag ihn in Claude ein – der alte funktioniert dann nicht mehr.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Dein persönlicher Claude-Link")
            }
        }
    }

    @ViewBuilder
    private var setupSection: some View {
        if status != nil {
            Section {
                Text("1. Öffne Claude (Browser, Desktop-App oder Handy-App) → Einstellungen → Konnektoren → „Eigenen Konnektor hinzufügen“.")
                Text("2. Name: Teach")
                Text("3. Bei „URL“ deinen persönlichen Claude-Link von oben einfügen und hinzufügen. Sonst nichts ausfüllen.")
                Text("4. Neuen Chat starten und fragen: „Zeig mir meine Teach-Ordner.“")
            } header: {
                Text("In Claude einrichten (einmalig)")
            } footer: {
                Text("Danach reicht in jedem Chat z.B. „Schreib mir Karten zu Thema X in Teach“. Im kostenlosen Claude-Abo ist ein eigener Konnektor möglich. Neue Karten erscheinen in der App, sobald du sie wieder öffnest oder die Liste runterziehst. Claude kann über den Konnektor nur lesen und neu anlegen, nichts ändern oder löschen.")
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
                        Label("Neuen Link erzeugen", systemImage: "arrow.clockwise")
                    }
                    .disabled(isWorking)

                    Button(role: .destructive) {
                        showRevokeConfirmation = true
                    } label: {
                        Label("Link sperren", systemImage: "lock.slash")
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
                            Label("Persönlichen Claude-Link erzeugen", systemImage: "link.badge.plus")
                        }
                    }
                    .disabled(isWorking)
                }
            } footer: {
                if status.active {
                    Text("Ein gesperrter oder ersetzter Link funktioniert sofort nicht mehr.")
                }
            }
        }
    }

    // MARK: - Dialoge

    /// Ausgelagert, damit die Modifier-Kette kurz bleibt (siehe Type-Checker-
    /// Hinweis in `FolderListView`).
    private func withDialogs<Content: View>(_ content: Content) -> some View {
        content
            .confirmationDialog("Neuen Link erzeugen?", isPresented: $showRegenerateConfirmation, titleVisibility: .visible) {
                Button("Neuen Link erzeugen") {
                    Task { await createKey() }
                }
                Button("Abbrechen", role: .cancel) {}
            } message: {
                Text("Der bisherige Link funktioniert danach nicht mehr. Du musst den neuen in Claude eintragen (Konnektor entfernen und neu hinzufügen).")
            }
            .confirmationDialog("Link sperren?", isPresented: $showRevokeConfirmation, titleVisibility: .visible) {
                Button("Sperren", role: .destructive) {
                    Task { await revokeKey() }
                }
                Button("Abbrechen", role: .cancel) {}
            } message: {
                Text("Claude kann danach nicht mehr in deine Teach-Ordner schreiben, bis du einen neuen Link erzeugst.")
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
            let loaded = try await ConnectorKeyService.status(accessToken: token)
            status = loaded
            linkKey = storedKeyMatching(loaded)
        }
    }

    private func createKey() async {
        isWorking = true
        defer { isWorking = false }
        await perform { token in
            let result = try await ConnectorKeyService.createKey(accessToken: token)
            status = result
            linkKey = result.key
            if let key = result.key, let userId = auth.session?.userId {
                ConnectorLink.store(key, for: userId)
            }
        }
    }

    private func revokeKey() async {
        isWorking = true
        defer { isWorking = false }
        await perform { token in
            status = try await ConnectorKeyService.revokeKey(accessToken: token)
            linkKey = nil
            if let userId = auth.session?.userId {
                ConnectorLink.removeStoredKey(for: userId)
            }
        }
    }

    /// Der im Keychain gespeicherte Schlüssel, falls er zum aktiven passt.
    private func storedKeyMatching(_ status: ConnectorKeyStatus) -> String? {
        guard status.active,
              let userId = auth.session?.userId,
              let stored = ConnectorLink.storedKey(for: userId),
              ConnectorLink.matches(stored, activePrefix: status.keyPrefix)
        else { return nil }
        return stored
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
