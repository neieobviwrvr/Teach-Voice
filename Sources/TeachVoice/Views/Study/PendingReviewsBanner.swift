import SwiftUI

/// Kleiner Hinweis, solange Bewertungen noch nicht gespeichert werden konnten
/// (z.B. kein Netz). Verschwindet von selbst, sobald alles nachgeholt ist.
struct PendingReviewsBanner: View {
    @EnvironmentObject private var library: LibraryStore

    var body: some View {
        if library.pendingReviewCount > 0 {
            Label(text, systemImage: "icloud.slash")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.vertical, 6)
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
                .accessibilityElement(children: .combine)
        }
    }

    private var text: String {
        let count = library.pendingReviewCount
        let subject = count == 1 ? "1 Bewertung wird" : "\(count) Bewertungen werden"
        return "\(subject) nachgeholt, sobald wieder Netz da ist."
    }
}
