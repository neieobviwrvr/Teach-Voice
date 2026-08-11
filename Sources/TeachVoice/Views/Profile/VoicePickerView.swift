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
    @StateObject private var previewSpeech = SpeechService()
    @State private var selectedIdentifier: String? = VoicePreference.selectedIdentifier
    // Getrennt von `previewSpeech.isSpeaking` (das ist nur EIN gemeinsamer
    // Bool für den ganzen Service) -- ohne dieses Feld würden beim Abspielen
    // EINER Stimme ALLE Zeilen gleichzeitig das "spielt ab"-Icon zeigen.
    @State private var playingIdentifier: String?

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
        .navigationTitle("Vorlesestimme")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { previewSpeech.stop() }
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
