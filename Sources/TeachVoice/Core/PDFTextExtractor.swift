import PDFKit

/// Extrahiert reinen Text aus einem PDF für den PDF-Import (`PDFImportView`),
/// seitenweise über `PDFKit` (nativ, on-device, keine dritte Abhängigkeit).
///
/// Die Zeichen-Obergrenze ist bewusst NICHT primär ein Kosten-Schutz (GPT-4o-mini
/// ist pro Token günstig genug, dass das kaum ins Gewicht fällt) – der eigentliche
/// Grund ist, dass ein wirklich langer, ungekappter Text das 128K-Token-
/// Kontextfenster sprengen und die Anfrage schlicht scheitern lassen würde.
/// Getestet an einem echten 19-seitigen Vorlesungs-PDF (1,8MB -> 21.616
/// extrahierte Zeichen) – 80.000 Zeichen decken damit deutlich umfangreichere
/// Foliensätze komfortabel ab, ohne in Kontext-Nähe zu kommen.
enum PDFTextExtractor {
    static let characterCap = 80_000

    /// `Sendable`, damit `Task.detached` (siehe `PDFImportView`, extrahiert
    /// bewusst abseits des Main Threads) den Rückgabewert unproblematisch
    /// über die Actor-Grenze zurückreichen kann.
    struct Result: Sendable {
        let text: String
        let includedPages: Int
        let totalPages: Int
        var wasTruncated: Bool { includedPages < totalPages }
    }

    /// Synchron und potenziell nicht ganz billig (PDF-Parsing) – bewusst NICHT
    /// `@MainActor`, damit Aufrufer das z.B. via `Task.detached` vom Main
    /// Thread wegholen können, statt die UI beim Import kurz einfrieren zu
    /// lassen.
    static func extract(from url: URL) -> Result? {
        guard let document = PDFDocument(url: url) else { return nil }
        let totalPages = document.pageCount
        guard totalPages > 0 else { return Result(text: "", includedPages: 0, totalPages: 0) }

        var combined = ""
        var includedPages = 0

        for pageIndex in 0..<totalPages {
            guard let page = document.page(at: pageIndex) else { continue }
            let marker = "--- Seite \(pageIndex + 1) ---\n"
            let addition = marker + (page.string ?? "") + "\n\n"

            if combined.count + addition.count > characterCap {
                if includedPages == 0 {
                    // Selbst die erste Seite allein wäre schon zu lang (bei
                    // normalen Folien praktisch ausgeschlossen) – hart am
                    // Zeichenlimit abschneiden, damit wenigstens etwas
                    // zurückkommt statt gar nichts.
                    let remaining = characterCap - combined.count
                    if remaining > 0 {
                        combined += String(addition.prefix(remaining))
                    }
                    includedPages = 1
                }
                break
            }

            combined += addition
            includedPages = pageIndex + 1
        }

        return Result(text: combined, includedPages: includedPages, totalPages: totalPages)
    }
}
