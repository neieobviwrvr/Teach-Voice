import SwiftUI
import AVFoundation
import UIKit

/// Liste aller auf DIESEM Gerät installierten deutschen TTS-Stimmen (siehe
/// `SpeechService.preferredVoice`) -- inklusive Enhanced-/Premium-/Siri-
/// Stimmen, falls unter Einstellungen -> Bedienungshilfen -> Gesprochener
/// Inhalt -> Stimmen heruntergeladen. Jede Zeile hat einen Anhören-Button mit
/// Beispielsatz, damit der User selbst hört, bevor er wählt. Auswahl ist rein
/// lokal (`VoicePreference`, UserDefaults) -- gilt unabhängig vom Login-/
/// Gastmodus, wie das Vorlesen selbst.
struct VoicePickerView: View {
    // App-weit geteilte Instanz (siehe TeachVoiceApp) statt eine eigene --
    // sonst hätten zwei unabhängige AVSpeechSynthesizer-Instanzen (diese
    // Vorschau + z.B. eine parallel noch nachklingende Frage aus StudyView)
    // tatsächlich gleichzeitig hörbar sein können.
    @EnvironmentObject private var previewSpeech: SpeechService
    @State private var selectedIdentifier: String? = VoicePreference.selectedIdentifier
    // Getrennt von `previewSpeech.isSpeaking` (das ist nur EIN gemeinsamer
    // Bool für den ganzen Service) -- ohne dieses Feld würden beim Abspielen
    // EINER Stimme ALLE Zeilen gleichzeitig das "spielt ab"-Icon zeigen.
    @State private var playingIdentifier: String?

    // `AVSpeechSynthesisVoice.speechVoices()` cached auf iOS bekanntermaßen
    // INNERHALB eines laufenden App-Prozesses -- eine gerade in den
    // Einstellungen heruntergeladene Stimme taucht oft erst nach einem
    // ECHTEN Neustart der App auf, nicht schon beim bloßen Zurückkehren aus
    // dem Hintergrund. `voices`/`resolvedAutomaticVoiceName` rufen die API
    // zwar bei JEDEM `body`-Durchlauf frisch auf (kein eigenes Caching
    // dieser View), aber SwiftUI ruft `body` nur neu auf, wenn sich
    // beobachteter State ändert -- `refreshTrigger` erzwingt genau das, über
    // `.id(refreshTrigger)` auf der Liste, sowohl beim Zurückkehren aus dem
    // Hintergrund (`scenePhase`) als auch manuell (Pull-to-Refresh + Button).
    @State private var refreshTrigger = UUID()
    @Environment(\.scenePhase) private var scenePhase

    private let sampleText = "So klingt diese Stimme beim Vorlesen deiner Karteikarten."

    // Nur deutsche Sprachvarianten (de-DE/de-AT/de-CH) -- die App liest
    // ausschließlich deutschsprachige Karteikarten vor, eine komplette
    // Geräte-weite Sprachenliste würde hier nur unnötig Auswahl erschweren.
    private var voices: [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("de") }
            .sorted { lhs, rhs in
                let lhsRank = qualityRank(lhs.quality)
                let rhsRank = qualityRank(rhs.quality)
                if lhsRank != rhsRank { return lhsRank > rhsRank }
                return lhs.name.localizedCompare(rhs.name) == .orderedAscending
            }
    }

    /// Zeigt an, welche Stimme "Automatisch" GERADE konkret bedeutet -- ruft
    /// exakt dieselbe Kaskade wie `SpeechService.preferredVoice` auf (ohne
    /// die manuelle Auswahl, die ist hier ja explizit nicht aktiv). Macht
    /// sichtbar, ob eine neu heruntergeladene Stimme schon erkannt wird,
    /// statt raten zu müssen.
    private var resolvedAutomaticVoiceName: String {
        let languageCode = Locale.preferredLanguages.first ?? "de-DE"
        return SpeechService.automaticVoice(languageCode: languageCode)?.name ?? "Standardstimme"
    }

    var body: some View {
        List {
            Section {
                automaticRow
            } footer: {
                Text("Wählt beim Vorlesen automatisch die beste heruntergeladene Stimme (bevorzugt Siri-/Enhanced-Qualität).")
            }

            Section {
                ForEach(voices, id: \.identifier) { voice in
                    voiceRow(voice)
                }
            } header: {
                Text("Deutsche Stimmen auf diesem Gerät")
            } footer: {
                Text("Fehlt eine gerade heruntergeladene Stimme? Zieh die Liste nach unten zum Aktualisieren -- hilft das nicht, starte die App einmal KOMPLETT neu (aus der App-Übersicht wegwischen, nicht nur in den Hintergrund schicken). iOS aktualisiert die Stimmenliste manchmal erst dann.")
            }

            Section {
                DisclosureGroup("Alle vom System gemeldeten Stimmen (Diagnose)") {
                    diagnosticVoiceList
                }
            } footer: {
                Text("Zeigt ALLES, was iOS dieser App gerade als Stimme meldet -- über alle Sprachen hinweg, ungefiltert. Hilft zu klären, ob eine fehlende Stimme (z.B. eine Siri-Stimme) wirklich nicht gemeldet wird, oder ob sie da ist und nur falsch gefiltert wird.")
            }

            Section {
                Button {
                    openSettings()
                } label: {
                    Label("Einstellungen öffnen", systemImage: "gear")
                }
            } footer: {
                // Ehrlich formuliert statt einen direkten Sprung zu
                // versprechen: Apple erlaubt Drittanbieter-Apps öffentlich
                // NUR den Sprung zur eigenen App-Einstellungsseite, keinen
                // direkten Deep-Link zu einem bestimmten System-Untermenü
                // wie "Bedienungshilfen -> Gesprochener Inhalt -> Stimmen".
                // Ein inoffizieller Deep-Link-Trick wäre nicht zuverlässig
                // testbar (kein Gerät/Simulator hier verfügbar) und könnte
                // je nach iOS-Version einfach ins Leere laufen.
                Text("Öffnet die App-Einstellungsseite. Weitere Stimmen lädst du von dort über Einstellungen -> Bedienungshilfen -> Gesprochener Inhalt -> Stimmen herunter (Apple erlaubt Apps keinen direkten Sprung zu diesem Untermenü).")
            }
        }
        .id(refreshTrigger)
        .navigationTitle("Vorlesestimme")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    refreshTrigger = UUID()
                } label: {
                    Label("Aktualisieren", systemImage: "arrow.clockwise")
                }
            }
        }
        .refreshable { refreshTrigger = UUID() }
        .onChange(of: scenePhase) { _, newPhase in
            // Fängt den Fall ab, in dem der User über "Einstellungen öffnen"
            // (s.u.) eine Stimme herunterlädt und per App-Wechsler zurückkommt
            // (kein kompletter Neustart) -- ob das reicht, damit iOS die
            // Stimmenliste wirklich aktualisiert, ließ sich hier ohne Gerät
            // nicht verifizieren, daher zusätzlich Pull-to-Refresh + Button.
            if newPhase == .active { refreshTrigger = UUID() }
        }
        .onDisappear {
            previewSpeech.stop()
            AudioSessionCoordinator.deactivate()
        }
    }

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    private var automaticRow: some View {
        Button {
            selectedIdentifier = nil
            VoicePreference.selectedIdentifier = nil
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Automatisch (empfohlen)").font(.body)
                    Text("Aktuell: \(resolvedAutomaticVoiceName)").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if selectedIdentifier == nil {
                    Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func voiceRow(_ voice: AVSpeechSynthesisVoice) -> some View {
        HStack {
            Button {
                selectedIdentifier = voice.identifier
                VoicePreference.selectedIdentifier = voice.identifier
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(voice.name).font(.body)
                        Text("\(qualityLabel(voice.quality)) · \(voice.language)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if selectedIdentifier == voice.identifier {
                        Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                    }
                }
            }
            .buttonStyle(.plain)

            Button {
                playingIdentifier = voice.identifier
                previewSpeech.speak(sampleText, voice: voice)
            } label: {
                let isPlayingThis = previewSpeech.isSpeaking && playingIdentifier == voice.identifier
                Image(systemName: isPlayingThis ? "speaker.wave.2.fill" : "play.circle")
                    .font(.title3)
            }
            .buttonStyle(.borderless)
        }
    }

    /// Roh-Dump ALLER von `AVSpeechSynthesisVoice.speechVoices()` gemeldeten
    /// Stimmen, unabhängig von Sprache/Filter -- reine Diagnose, um zu sehen
    /// was iOS der App WIRKLICH meldet, statt der gefilterten `voices`-Liste
    /// oben blind vertrauen zu müssen.
    @ViewBuilder
    private var diagnosticVoiceList: some View {
        let all = AVSpeechSynthesisVoice.speechVoices()
        let germanCount = all.filter { $0.language.hasPrefix("de") }.count
        Text("\(all.count) Stimmen insgesamt gemeldet, davon \(germanCount) mit Sprachcode \"de*\".")
            .font(.caption)
            .foregroundStyle(.secondary)
        ForEach(all, id: \.identifier) { voice in
            VStack(alignment: .leading, spacing: 1) {
                Text("\(voice.name) — \(voice.language) — \(qualityLabel(voice.quality))")
                    .font(.caption2)
                Text(voice.identifier)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func qualityLabel(_ quality: AVSpeechSynthesisVoiceQuality) -> String {
        switch quality {
        case .premium: return "Premium"
        case .enhanced: return "Enhanced"
        default: return "Standard"
        }
    }

    private func qualityRank(_ quality: AVSpeechSynthesisVoiceQuality) -> Int {
        switch quality {
        case .premium: return 3
        case .enhanced: return 2
        default: return 1
        }
    }
}
