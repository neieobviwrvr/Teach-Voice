import Foundation

/// Ein einzelner, von GPT vorgeschlagener Frage+Musterantwort-Vorschlag aus
/// dem PDF-Import – noch nicht gespeichert, wird erst nach User-Auswahl im
/// Review-Screen (`PDFImportView`) wirklich als Karte angelegt.
struct GeneratedQuestion: Decodable, Identifiable, Hashable {
    let frage: String
    let musterantwort: String

    // Reicht als stabiler Identifier innerhalb einer einzelnen Generierung
    // (wird nie über Sitzungen hinweg persistiert).
    var id: String { frage }
}

private struct GenerateResponse: Decodable {
    let fragen: [GeneratedQuestion]
}

private struct GenerateRequestBody: Encodable {
    let text: String
    let maxQuestions: Int
}

/// Ruft die zustandslose Supabase Edge Function `generate-questions` auf
/// (GPT-4o-mini) – aus bereits extrahiertem PDF-Text werden bis zu
/// `maxQuestions` Frage+Musterantwort-Vorschläge generiert. Gleiches
/// Auth-/Fehler-Muster wie `GradingService`.
enum QuestionGenerationService {
    static func generate(
        text: String,
        maxQuestions: Int,
        accessToken: String?
    ) async throws -> [GeneratedQuestion] {
        var request = URLRequest(url: SupabaseConfig.url.appendingPathComponent("functions/v1/generate-questions"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(SupabaseConfig.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(accessToken ?? SupabaseConfig.anonKey)", forHTTPHeaderField: "Authorization")

        let body = GenerateRequestBody(text: text, maxQuestions: maxQuestions)
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }

        guard (200...299).contains(http.statusCode) else {
            let message = (try? JSONDecoder().decode(APIErrorBody.self, from: data))?.readableMessage
                ?? String(data: data, encoding: .utf8) ?? "Unbekannter Fehler"
            throw APIError.server(status: http.statusCode, message: message)
        }

        let decoded = try JSONDecoder().decode(GenerateResponse.self, from: data)
        return decoded.fragen
    }
}
