import Foundation

/// Persistiert die vom User manuell in `VoicePickerView` gewählte TTS-Stimme.
/// Rein lokal (UserDefaults, wie `GuestIdentity`) -- eine Vorlese-Stimme ist
/// eine Geräteeigenschaft, keine Account-/Cloud-Daten, gilt daher bewusst
/// GLEICHERMASSEN im Cloud- und im Gastmodus, unabhängig vom Login.
///
/// `nil` bedeutet "automatisch" (siehe `SpeechService.preferredVoice`): die
/// beste auf dem Gerät heruntergeladene Stimme wird selbst ermittelt, statt
/// eine feste Auswahl zu erzwingen.
enum VoicePreference {
    private static let key = "teachvoice.preferredVoiceIdentifier"

    static var selectedIdentifier: String? {
        get { UserDefaults.standard.string(forKey: key) }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}
