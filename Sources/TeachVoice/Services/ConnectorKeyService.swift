import Foundation

/// Antwort der Edge Function `connector-key` – für GET (Status), POST
/// (neuer Schlüssel) und DELETE (sperren) dieselbe Form.
struct ConnectorKeyStatus: Decodable {
    let active: Bool
    /// Die ersten Zeichen des Schlüssels ("tvk_AbCdEf"), zum Wiedererkennen.
    let keyPrefix: String?
    let createdAtRaw: String?
    let lastUsedAtRaw: String?
    /// Adresse, die man in Claude als Konnektor-URL einträgt.
    let connectorURL: String
    /// Der vollständige Schlüssel – NUR direkt nach dem Erzeugen gesetzt.
    /// Der Server speichert nur einen Hash und kann ihn danach nicht mehr
    /// anzeigen.
    let key: String?

    enum CodingKeys: String, CodingKey {
        case active, key
        case keyPrefix = "key_prefix"
        case createdAtRaw = "created_at"
        case lastUsedAtRaw = "last_used_at"
        case connectorURL = "connector_url"
    }

    var createdAt: Date? { createdAtRaw.flatMap(PostgrestDate.parse) }
    var lastUsedAt: Date? { lastUsedAtRaw.flatMap(PostgrestDate.parse) }
}

/// Verwaltet den persönlichen Schlüssel für den Claude-Konnektor
/// (`supabase/functions/teach-mcp`) über die Edge Function `connector-key`.
/// Nur im Cloud-Modus sinnvoll: Gast-Karten liegen ausschließlich auf dem
/// Gerät, dort kann der Konnektor nicht hineinschreiben.
enum ConnectorKeyService {
    static func status(accessToken: String) async throws -> ConnectorKeyStatus {
        try await send(method: "GET", accessToken: accessToken)
    }

    /// Erzeugt einen neuen Schlüssel und sperrt dabei einen alten.
    static func createKey(accessToken: String) async throws -> ConnectorKeyStatus {
        try await send(method: "POST", accessToken: accessToken)
    }

    static func revokeKey(accessToken: String) async throws -> ConnectorKeyStatus {
        try await send(method: "DELETE", accessToken: accessToken)
    }

    /// Gleicher Request-Aufbau wie `AuthManager.deleteAccount()`.
    private static func send(method: String, accessToken: String) async throws -> ConnectorKeyStatus {
        var request = URLRequest(url: SupabaseConfig.url.appendingPathComponent("functions/v1/connector-key"))
        request.httpMethod = method
        request.setValue(SupabaseConfig.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        guard (200...299).contains(http.statusCode) else {
            let message = (try? JSONDecoder().decode(APIErrorBody.self, from: data))?.readableMessage ?? "Unbekannter Fehler"
            throw APIError.server(status: http.statusCode, message: message)
        }

        do {
            return try JSONDecoder().decode(ConnectorKeyStatus.self, from: data)
        } catch {
            throw APIError.decoding(error)
        }
    }
}
