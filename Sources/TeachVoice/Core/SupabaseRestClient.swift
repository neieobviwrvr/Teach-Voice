import Foundation

/// Dünner PostgREST-Client für die Tabellen `folders`, `subfolders`, `flashcards`.
/// Row Level Security in Postgres sorgt dafür, dass jeder User nur seine eigenen
/// Zeilen sieht/ändert – der Access-Token identifiziert den User (`auth.uid()`).
enum SupabaseRestClient {
    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            if let date = PostgrestDate.parse(string) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Ungültiges Datum: \(string)")
        }
        return d
    }()

    static func select<T: Decodable>(
        table: String,
        query: [URLQueryItem] = [],
        accessToken: String
    ) async throws -> [T] {
        var components = URLComponents(url: SupabaseConfig.restURL.appendingPathComponent(table), resolvingAgainstBaseURL: false)!
        components.queryItems = query.isEmpty ? nil : query
        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        applyHeaders(&request, accessToken: accessToken)
        return try await send(request)
    }

    @discardableResult
    static func insert<Body: Encodable, T: Decodable>(
        table: String,
        body: Body,
        accessToken: String
    ) async throws -> T {
        var request = URLRequest(url: SupabaseConfig.restURL.appendingPathComponent(table))
        request.httpMethod = "POST"
        applyHeaders(&request, accessToken: accessToken)
        request.setValue("return=representation", forHTTPHeaderField: "Prefer")
        request.setValue("application/vnd.pgrst.object+json", forHTTPHeaderField: "Accept")
        request.httpBody = try encoder.encode(body)
        return try await send(request)
    }

    @discardableResult
    static func update<Body: Encodable, T: Decodable>(
        table: String,
        id: UUID,
        body: Body,
        accessToken: String
    ) async throws -> T {
        var components = URLComponents(url: SupabaseConfig.restURL.appendingPathComponent(table), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "id", value: "eq.\(id.uuidString)")]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "PATCH"
        applyHeaders(&request, accessToken: accessToken)
        request.setValue("return=representation", forHTTPHeaderField: "Prefer")
        request.setValue("application/vnd.pgrst.object+json", forHTTPHeaderField: "Accept")
        request.httpBody = try encoder.encode(body)
        return try await send(request)
    }

    static func delete(table: String, id: UUID, accessToken: String) async throws {
        var components = URLComponents(url: SupabaseConfig.restURL.appendingPathComponent(table), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "id", value: "eq.\(id.uuidString)")]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "DELETE"
        applyHeaders(&request, accessToken: accessToken)
        let _: EmptyResponse = try await send(request, allowEmptyBody: true)
    }

    private static func applyHeaders(_ request: inout URLRequest, accessToken: String) {
        request.setValue(SupabaseConfig.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }

    private static func send<T: Decodable>(_ request: URLRequest, allowEmptyBody: Bool = false) async throws -> T {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }

        guard (200...299).contains(http.statusCode) else {
            let message = (try? decoder.decode(APIErrorBody.self, from: data))?.readableMessage ?? String(data: data, encoding: .utf8) ?? "Unbekannter Fehler"
            throw APIError.server(status: http.statusCode, message: message)
        }

        if allowEmptyBody, data.isEmpty {
            // EmptyResponse hat keine Felder, ein leeres Objekt reicht.
            return try decoder.decode(T.self, from: Data("{}".utf8))
        }

        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw APIError.decoding(error)
        }
    }
}

private struct EmptyResponse: Decodable {}
