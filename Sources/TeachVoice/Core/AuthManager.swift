import Foundation

struct AuthSession: Codable {
    let accessToken: String
    let refreshToken: String
    let userId: UUID
    let email: String
    let expiresAt: Date
}

private struct TokenResponse: Decodable {
    let accessToken: String
    let refreshToken: String
    let expiresIn: Int
    let user: SupabaseUser

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
        case user
    }
}

private struct SupabaseUser: Decodable {
    let id: UUID
    let email: String?
}

/// Verwaltet Login/Registrierung/Logout gegen Supabase Auth (GoTrue) per REST –
/// bewusst ohne das `supabase-swift` SPM-Package, um die Build-Abhängigkeiten
/// für die (unsignierte) CI-Build-Pipeline gering zu halten.
@MainActor
final class AuthManager: ObservableObject {
    @Published private(set) var session: AuthSession?
    @Published private(set) var isGuest: Bool
    @Published var isLoading = false
    @Published var errorMessage: String?

    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601WithFractionalSeconds
        return d
    }()

    private enum KeychainKey {
        static let refreshToken = "refresh_token"
    }

    private enum DefaultsKey {
        static let isGuest = "teachvoice.isGuest"
    }

    init() {
        isGuest = UserDefaults.standard.bool(forKey: DefaultsKey.isGuest)
        if let refreshToken = Keychain.get(KeychainKey.refreshToken) {
            Task { await refresh(refreshToken: refreshToken) }
        }
    }

    var isAuthenticated: Bool { session != nil }

    /// Hartcodiert `false` für JEDEN Account – es gibt aktuell keine echte
    /// Bezahlfunktion (kein In-App-Purchase, kein Apple-Developer-Konto, kein
    /// App-Store-Vertrieb, siehe `supabase/migrations/0006_user_entitlements.sql`).
    /// Die DB-Spalte `profiles.is_paid_user` existiert schon als vorbereiteter
    /// Anknüpfungspunkt, wird aber bewusst noch nicht gelesen – reine
    /// Datenstruktur-Vorbereitung, kein Zahlungs-Feature. Gatet aktuell nur die
    /// PDF-Upload-Anzahl im PDF-Import (siehe `PDFImportView`).
    var isPaidUser: Bool { false }

    /// Startet die App im Gastmodus: keine Registrierung, keine Cloud-Anbindung –
    /// Karteikarten werden ausschließlich lokal auf diesem Gerät gespeichert.
    func continueAsGuest() {
        isGuest = true
        UserDefaults.standard.set(true, forKey: DefaultsKey.isGuest)
    }

    /// Verlässt den Gastmodus wieder (z.B. um sich stattdessen per E-Mail anzumelden).
    /// Bereits lokal gespeicherte Gastdaten bleiben auf dem Gerät erhalten, bis der
    /// Gastmodus erneut aktiviert wird.
    func exitGuestMode() {
        isGuest = false
        UserDefaults.standard.set(false, forKey: DefaultsKey.isGuest)
    }

    /// Beendet die aktuelle Sitzung, egal ob Cloud-Login oder Gastmodus.
    func leaveCurrentSession() {
        if isGuest {
            exitGuestMode()
        } else {
            signOut()
        }
    }

    func signUp(email: String, password: String) async {
        await performAuthRequest(path: "signup", body: ["email": email, "password": password]) { [weak self] result in
            // Falls E-Mail-Bestätigung in Supabase aktiviert ist, kommt ggf. keine Session zurück.
            if result == nil {
                self?.errorMessage = "Konto erstellt. Falls Bestätigung aktiviert ist, prüfe dein E-Mail-Postfach und melde dich danach an."
            }
        }
    }

    func signIn(email: String, password: String) async {
        await performAuthRequest(path: "token?grant_type=password", body: ["email": email, "password": password]) { _ in }
    }

    func signOut() {
        Keychain.remove(KeychainKey.refreshToken)
        session = nil
    }

    /// Löscht den eingeloggten Account server-seitig UNWIDERRUFLICH, inklusive
    /// aller Ordner/Unterordner/Karteikarten (via `ON DELETE CASCADE`, siehe
    /// `supabase/migrations/0001_init.sql`) -- über die Edge Function
    /// `delete-account`, da das Löschen eines Auth-Users den `service_role`-
    /// Key braucht, den der Client nie besitzt (wie bei allen anderen
    /// Edge Functions in diesem Projekt). Beendet bei Erfolg lokal die
    /// Sitzung wie `signOut()`, da Account+Session serverseitig nicht mehr
    /// existieren.
    func deleteAccount() async throws {
        guard let token = await validAccessToken() else {
            throw APIError.notAuthenticated
        }

        var request = URLRequest(url: SupabaseConfig.url.appendingPathComponent("functions/v1/delete-account"))
        request.httpMethod = "POST"
        request.setValue(SupabaseConfig.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        guard (200...299).contains(http.statusCode) else {
            let message = (try? decoder.decode(APIErrorBody.self, from: data))?.readableMessage ?? "Unbekannter Fehler"
            throw APIError.server(status: http.statusCode, message: message)
        }

        signOut()
    }

    /// Liefert einen gültigen Access-Token, refresht bei Bedarf.
    func validAccessToken() async -> String? {
        guard let session else { return nil }
        if session.expiresAt > Date().addingTimeInterval(30) {
            return session.accessToken
        }
        await refresh(refreshToken: session.refreshToken)
        return self.session?.accessToken
    }

    private func refresh(refreshToken: String) async {
        await performAuthRequest(path: "token?grant_type=refresh_token", body: ["refresh_token": refreshToken]) { _ in }
    }

    private func performAuthRequest(path: String, body: [String: String], onSuccessWithNoSession: (AuthSession?) -> Void) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        // `token?grant_type=...` enthält einen Query-String – URL manuell zusammensetzen,
        // da appendingPathComponent das "?" escapen würde.
        let parts = path.split(separator: "?", maxSplits: 1)
        let basePath = String(parts[0])
        var components = URLComponents(
            url: SupabaseConfig.authURL.appendingPathComponent(basePath),
            resolvingAgainstBaseURL: false
        )!
        if parts.count > 1 {
            components.query = String(parts[1])
        }

        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(SupabaseConfig.anonKey, forHTTPHeaderField: "apikey")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }

            guard (200...299).contains(http.statusCode) else {
                let body = (try? decoder.decode(APIErrorBody.self, from: data))?.readableMessage ?? "Unbekannter Fehler"
                throw APIError.server(status: http.statusCode, message: body)
            }

            if let token = try? decoder.decode(TokenResponse.self, from: data) {
                let newSession = AuthSession(
                    accessToken: token.accessToken,
                    refreshToken: token.refreshToken,
                    userId: token.user.id,
                    email: token.user.email ?? "",
                    expiresAt: Date().addingTimeInterval(TimeInterval(token.expiresIn))
                )
                self.session = newSession
                Keychain.set(newSession.refreshToken, for: KeychainKey.refreshToken)
                onSuccessWithNoSession(newSession)
            } else {
                onSuccessWithNoSession(nil)
            }
        } catch let error as APIError {
            errorMessage = error.errorDescription
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private extension JSONDecoder.DateDecodingStrategy {
    static var iso8601WithFractionalSeconds: JSONDecoder.DateDecodingStrategy {
        .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: string) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            if let date = formatter.date(from: string) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Ungültiges Datum: \(string)")
        }
    }
}
