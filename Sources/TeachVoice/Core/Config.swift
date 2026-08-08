import Foundation

/// Zentrale Supabase-Konfiguration.
///
/// Der `anon`-Key ist bewusst öffentlich (er landet im App-Binary) – der
/// eigentliche Datenschutz kommt aus Row Level Security in Postgres
/// (siehe `supabase/migrations/0001_init.sql`), nicht aus der Geheimhaltung
/// dieses Keys.
enum SupabaseConfig {
    static let projectRef = "rvpisoibtqxxxpgjdhff"
    static let url = URL(string: "https://\(projectRef).supabase.co")!
    static let anonKey = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InJ2cGlzb2lidHF4eHhwZ2pkaGZmIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODYyMTU5NzAsImV4cCI6MjEwMTc5MTk3MH0.DOmcdD3FR8TWFx-RkwO0nXWEx6R9EuTN7X_4SLZ6SUc"

    static var authURL: URL { url.appendingPathComponent("auth/v1") }
    static var restURL: URL { url.appendingPathComponent("rest/v1") }
}
