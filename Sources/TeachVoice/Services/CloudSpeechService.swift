import Foundation

/// Muss mit `VOICE_NAME` in `text-to-speech/index.ts` übereinstimmen -- dient
/// hier nur als Cache-Schlüssel-Bestandteil (siehe `AudioFileCache`), nicht
/// als tatsächlicher Request-Parameter (die Stimme ist serverseitig fest
/// hinterlegt, nicht vom Client wählbar -- anders als bei den lokalen
/// Apple-Stimmen in `VoicePickerView`).
enum CloudSpeechConfig {
    static let voiceIdentifier = "google:de-DE-Wavenet-F"
}

private struct TTSRequestBody: Encodable {
    let text: String
}

private struct TTSResponseBody: Decodable {
    let audioContent: String
}

enum CloudSpeechError: Error {
    case invalidAudio
}

/// Ruft die zustandslose Supabase Edge Function `text-to-speech` auf (Google
/// Cloud TTS, WaveNet). Gleiches Auth-/Fehler-Muster wie `GradingService` --
/// bei Gästen wird der `anon`-Key als Bearer mitgeschickt statt eines echten
/// User-Tokens.
enum CloudSpeechService {
    static func synthesize(text: String, accessToken: String?) async throws -> Data {
        var request = URLRequest(url: SupabaseConfig.url.appendingPathComponent("functions/v1/text-to-speech"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(SupabaseConfig.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(accessToken ?? SupabaseConfig.anonKey)", forHTTPHeaderField: "Authorization")
        // Kurzes Timeout statt der URLSession-Standardvorgabe (60s) -- bei
        // schlechtem Netz soll zügig auf die lokale Apple-Stimme
        // zurückgefallen werden (siehe SpeechService), statt den User im
        // Hands-free-Modus lange in Stille warten zu lassen.
        request.timeoutInterval = 10

        request.httpBody = try JSONEncoder().encode(TTSRequestBody(text: text))

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }

        guard (200...299).contains(http.statusCode) else {
            let message = (try? JSONDecoder().decode(APIErrorBody.self, from: data))?.readableMessage
                ?? String(data: data, encoding: .utf8) ?? "Unbekannter Fehler"
            throw APIError.server(status: http.statusCode, message: message)
        }

        let decoded = try JSONDecoder().decode(TTSResponseBody.self, from: data)
        guard let audio = Data(base64Encoded: decoded.audioContent) else {
            throw CloudSpeechError.invalidAudio
        }
        return audio
    }
}
