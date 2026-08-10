import Foundation

struct GradingResult: Decodable {
    enum Urteil: String, Decodable {
        case richtig, teilweise, falsch
    }

    let kernelementeGetroffen: Int
    let deckungProzent: Double
    let getroffeneElemente: [String]
    let fehlendeElemente: [String]
    let urteil: Urteil
    let kurzesFeedback: String

    enum CodingKeys: String, CodingKey {
        case kernelementeGetroffen = "kernelemente_getroffen"
        case deckungProzent = "deckung_prozent"
        case getroffeneElemente = "getroffene_elemente"
        case fehlendeElemente = "fehlende_elemente"
        case urteil
        case kurzesFeedback = "kurzes_feedback"
    }
}

private struct GradeResponse: Decodable {
    let kernelemente: [String]
    let result: GradingResult
}

private struct GradeRequestBody: Encodable {
    let question: String
    let answer: String
    let kernelemente: [String]?
    let sttText: String
}

/// Ruft die zustandslose Supabase Edge Function `grade-answer` auf (GPT-4o-mini).
/// Funktioniert identisch für Cloud- und Gastkarten: bei Gästen wird statt eines
/// echten User-Access-Tokens einfach der `anon`-Key als Bearer mitgeschickt
/// (er ist selbst ein gültig signiertes JWT) – die Function selbst greift nie
/// auf Supabase-Tabellen zu, RLS spielt hier also keine Rolle.
enum GradingService {
    /// - Parameters:
    ///   - cachedKernelemente: bereits extrahierte Kernelemente, falls der lokale
    ///     Hash der Musterantwort noch dazu passt. `nil`/leer erzwingt eine
    ///     (kostenpflichtige) Neu-Extraktion durch die Function.
    ///   - accessToken: Supabase-Session-Token im Cloud-Modus, `nil` im Gastmodus.
    static func grade(
        question: String,
        answer: String,
        cachedKernelemente: [String]?,
        sttText: String,
        accessToken: String?
    ) async throws -> (kernelemente: [String], result: GradingResult) {
        var request = URLRequest(url: SupabaseConfig.url.appendingPathComponent("functions/v1/grade-answer"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(SupabaseConfig.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(accessToken ?? SupabaseConfig.anonKey)", forHTTPHeaderField: "Authorization")

        let body = GradeRequestBody(
            // Fett-Markierung in der Frage ist rein fürs eigene Lernen gedacht
            // (Simons Vorgabe) und soll KEINE Auswirkung auf GPT haben – die
            // Antwort behält ihre Formatierung dagegen bewusst, da sie als
            // Signal in die Kernelemente-Extraktion einfließt (siehe index.ts).
            question: FlashcardMarkdown.plainText(from: question),
            answer: answer,
            kernelemente: (cachedKernelemente?.isEmpty ?? true) ? nil : cachedKernelemente,
            sttText: sttText
        )
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }

        guard (200...299).contains(http.statusCode) else {
            let message = (try? JSONDecoder().decode(APIErrorBody.self, from: data))?.readableMessage
                ?? String(data: data, encoding: .utf8) ?? "Unbekannter Fehler"
            throw APIError.server(status: http.statusCode, message: message)
        }

        let decoded = try JSONDecoder().decode(GradeResponse.self, from: data)
        return (decoded.kernelemente, decoded.result)
    }
}
