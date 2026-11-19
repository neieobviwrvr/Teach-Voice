import Foundation

/// Womit die App vorliest -- app-weit für alle Ansagen (Fragen, Kurzlösung,
/// Statistik, "Vorlesen"-Buttons). Simons Wunsch nach einem Schalter, weil
/// ihm die Google-WaveNet-Stimme zu künstlich klang.
enum SpeechSource: String, CaseIterable, Identifiable {
    /// Google Cloud TTS über die Edge Function `text-to-speech` (mit Cache,
    /// Kostendeckel und lokalem Fallback ohne Netz).
    case google
    /// Die auf dem iPhone installierte Apple-Stimme (`AVSpeechSynthesizer`):
    /// kostenlos, offline, ohne Netzwerk-Pause. Klingt mit einer
    /// heruntergeladenen Premium-Stimme oft natürlicher als WaveNet.
    case iphone

    var id: String { rawValue }

    var label: String {
        switch self {
        case .google: return "Google-Stimme"
        case .iphone: return "iPhone-Stimme"
        }
    }
}

/// Persistiert die Vorlese-Einstellungen. Rein lokal (UserDefaults, wie
/// `GuestIdentity`) -- eine Vorlese-Stimme ist eine Geräteeigenschaft, keine
/// Account-/Cloud-Daten, gilt daher bewusst GLEICHERMASSEN im Cloud- und im
/// Gastmodus, unabhängig vom Login.
enum VoicePreference {
    private static let identifierKey = "teachvoice.preferredVoiceIdentifier"
    /// Auch der Schlüssel für `@AppStorage` in den Einstellungs-Views.
    static let sourceKey = "teachvoice.speechSource"

    /// Die in `VoicePickerView` gewählte iPhone-Stimme. `nil` bedeutet
    /// "automatisch" (siehe `SpeechService.preferredVoice`): die beste auf
    /// dem Gerät heruntergeladene Stimme wird selbst ermittelt.
    static var selectedIdentifier: String? {
        get { UserDefaults.standard.string(forKey: identifierKey) }
        set { UserDefaults.standard.set(newValue, forKey: identifierKey) }
    }

    /// Google (Standard, wie bisher) oder iPhone-Stimme.
    static var source: SpeechSource {
        get { UserDefaults.standard.string(forKey: sourceKey).flatMap(SpeechSource.init(rawValue:)) ?? .google }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: sourceKey) }
    }
}
