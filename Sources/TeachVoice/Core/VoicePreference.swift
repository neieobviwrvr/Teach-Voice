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
    /// Auch die Schlüssel für `@AppStorage` in den Einstellungs-Views.
    static let sourceKey = "teachvoice.speechSource"
    static let googleVoiceKey = "teachvoice.googleVoice"
    static let speakingRateKey = "teachvoice.speakingRate"

    /// Spanne und Schrittweite des Tempo-Reglers (1.0 = normal). Liegt
    /// innerhalb dessen, was `text-to-speech` annimmt (0.5-1.5).
    static let minSpeakingRate = 0.7
    static let maxSpeakingRate = 1.2
    static let speakingRateStep = 0.05

    /// Die gewählte Google-Stimme (nur Stimmen aus `CloudVoice.alle`).
    static var googleVoice: CloudVoice {
        get { UserDefaults.standard.string(forKey: googleVoiceKey).flatMap(CloudVoice.mitID) ?? .standard }
        set { UserDefaults.standard.set(newValue.id, forKey: googleVoiceKey) }
    }

    /// Sprechtempo für Google- UND iPhone-Stimme, auf die Regler-Schritte
    /// gerundet und begrenzt.
    static var speakingRate: Double {
        get {
            let stored = UserDefaults.standard.object(forKey: speakingRateKey) as? Double
            return normalizedRate(stored ?? 1.0)
        }
        set { UserDefaults.standard.set(normalizedRate(newValue), forKey: speakingRateKey) }
    }

    static func normalizedRate(_ rate: Double) -> Double {
        let clamped = min(max(rate, minSpeakingRate), maxSpeakingRate)
        return (clamped / speakingRateStep).rounded() * speakingRateStep
    }

    /// Deutsch formatiert, z.B. "0,85×".
    static func rateLabel(_ rate: Double) -> String {
        String(format: "%.2f×", normalizedRate(rate)).replacingOccurrences(of: ".", with: ",")
    }

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
