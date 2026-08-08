import Foundation

struct APIErrorBody: Decodable {
    let message: String?
    let errorDescription: String?
    let error: String?
    let msg: String?

    enum CodingKeys: String, CodingKey {
        case message
        case errorDescription = "error_description"
        case error
        case msg
    }

    var readableMessage: String {
        message ?? errorDescription ?? msg ?? error ?? "Unbekannter Fehler"
    }
}

enum APIError: LocalizedError {
    case invalidResponse
    case server(status: Int, message: String)
    case notAuthenticated
    case decoding(Error)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Ungültige Antwort vom Server."
        case .server(let status, let message):
            return "Fehler (\(status)): \(message)"
        case .notAuthenticated:
            return "Bitte melde dich an."
        case .decoding(let error):
            return "Antwort konnte nicht gelesen werden: \(error.localizedDescription)"
        }
    }
}
