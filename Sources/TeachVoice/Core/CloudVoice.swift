import Foundation

/// Eine der Google-Stimmen, die die Edge Function `text-to-speech` erlaubt.
/// Die Liste MUSS zu `ALLOWED_VOICES` in
/// `supabase/functions/text-to-speech/index.ts` passen (alle live gegen
/// Google getestet, Stand 19.11.2026).
struct CloudVoice: Identifiable, Hashable {
    enum Klasse: String {
        case wavenet = "WaveNet"
        case chirp3HD = "Chirp 3 HD"
    }

    enum Geschlecht: String {
        case weiblich, maennlich

        var anzeige: String {
            switch self {
            case .weiblich: return "weiblich"
            case .maennlich: return "männlich"
            }
        }
    }

    /// Name, wie ihn Google erwartet (z.B. "de-DE-Chirp3-HD-Despina").
    let id: String
    let name: String
    let klasse: Klasse
    let geschlecht: Geschlecht

    var beschreibung: String { "\(klasse.rawValue) · \(geschlecht.anzeige)" }

    /// Bisherige Stimme -- Standard, solange nichts anderes gewählt ist.
    static let standard = CloudVoice(id: "de-DE-Wavenet-G", name: "WaveNet G", klasse: .wavenet, geschlecht: .weiblich)

    static let alle: [CloudVoice] = [
        // Chirp 3 HD: neueste, natürlichste Generation (teurer pro Zeichen).
        CloudVoice(id: "de-DE-Chirp3-HD-Despina", name: "Despina", klasse: .chirp3HD, geschlecht: .weiblich),
        CloudVoice(id: "de-DE-Chirp3-HD-Aoede", name: "Aoede", klasse: .chirp3HD, geschlecht: .weiblich),
        CloudVoice(id: "de-DE-Chirp3-HD-Kore", name: "Kore", klasse: .chirp3HD, geschlecht: .weiblich),
        CloudVoice(id: "de-DE-Chirp3-HD-Leda", name: "Leda", klasse: .chirp3HD, geschlecht: .weiblich),
        CloudVoice(id: "de-DE-Chirp3-HD-Zephyr", name: "Zephyr", klasse: .chirp3HD, geschlecht: .weiblich),
        CloudVoice(id: "de-DE-Chirp3-HD-Sulafat", name: "Sulafat", klasse: .chirp3HD, geschlecht: .weiblich),
        CloudVoice(id: "de-DE-Chirp3-HD-Charon", name: "Charon", klasse: .chirp3HD, geschlecht: .maennlich),
        CloudVoice(id: "de-DE-Chirp3-HD-Puck", name: "Puck", klasse: .chirp3HD, geschlecht: .maennlich),
        CloudVoice(id: "de-DE-Chirp3-HD-Fenrir", name: "Fenrir", klasse: .chirp3HD, geschlecht: .maennlich),
        CloudVoice(id: "de-DE-Chirp3-HD-Schedar", name: "Schedar", klasse: .chirp3HD, geschlecht: .maennlich),
        CloudVoice(id: "de-DE-Chirp3-HD-Umbriel", name: "Umbriel", klasse: .chirp3HD, geschlecht: .maennlich),
        // WaveNet: ältere Generation (bisherige Stimme), günstig.
        standard,
        CloudVoice(id: "de-DE-Wavenet-H", name: "WaveNet H", klasse: .wavenet, geschlecht: .maennlich),
    ]

    static func mitID(_ id: String) -> CloudVoice? {
        alle.first { $0.id == id }
    }
}
