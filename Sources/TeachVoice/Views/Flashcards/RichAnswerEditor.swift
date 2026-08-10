import SwiftUI
import UIKit

/// Steuert einen `RichAnswerEditor` von außen (der "Fett"-Button in der
/// Toolbar) UND ist gleichzeitig dessen `UITextViewDelegate` – eine einzige
/// Instanz, damit der Toolbar-Button direkt auf die lebende `UITextView`
/// zugreifen kann. `text` ist hier die alleinige Wahrheitsquelle (kein
/// zusätzliches `@State` beim Aufrufer nötig) und enthält den
/// `FlashcardMarkdown`-Dialekt ("**fett**", "- " für Aufzählungspunkte).
///
/// Bewusst als `UIViewRepresentable`/`UITextView` statt SwiftUIs
/// `TextEditor(text: Binding<AttributedString>)` gebaut: Letzteres hat auf
/// iOS 17 (unser Deployment Target) keine öffentliche API für die aktuelle
/// Text-Selektion – "markierten Text fett machen" per Button braucht aber
/// genau das (`UITextView.selectedRange`). `UITextView` ist dafür der
/// etablierte, gut dokumentierte Weg.
final class RichTextEditorController: NSObject, ObservableObject, UITextViewDelegate {
    @Published var text: String
    let supportsBullets: Bool
    fileprivate weak var textView: UITextView?

    init(text: String, supportsBullets: Bool) {
        self.text = text
        self.supportsBullets = supportsBullets
    }

    /// Macht die aktuelle Auswahl fett – oder hebt Fett wieder auf, falls sie
    /// es schon komplett ist (Toggle-Verhalten). Ohne Auswahl passiert nichts.
    func toggleBold() {
        guard let textView, textView.selectedRange.length > 0 else { return }
        let range = textView.selectedRange
        let storage = textView.textStorage

        var isFullyBold = true
        storage.enumerateAttribute(.font, in: range, options: []) { value, _, stop in
            if (value as? UIFont)?.fontDescriptor.symbolicTraits.contains(.traitBold) != true {
                isFullyBold = false
                stop.pointee = true
            }
        }

        storage.beginEditing()
        storage.enumerateAttribute(.font, in: range, options: []) { value, subrange, _ in
            let baseFont = (value as? UIFont) ?? textView.font ?? .preferredFont(forTextStyle: .body)
            var traits = baseFont.fontDescriptor.symbolicTraits
            if isFullyBold {
                traits.remove(.traitBold)
            } else {
                traits.insert(.traitBold)
            }
            let descriptor = baseFont.fontDescriptor.withSymbolicTraits(traits) ?? baseFont.fontDescriptor
            storage.addAttribute(.font, value: UIFont(descriptor: descriptor, size: baseFont.pointSize), range: subrange)
        }
        storage.endEditing()

        textView.selectedRange = range
        syncText(from: textView)
    }

    func textViewDidChange(_ textView: UITextView) {
        syncText(from: textView)
    }

    /// Fängt "- " am Zeilenanfang ab und macht daraus live einen sichtbaren
    /// Aufzählungspunkt ("•  "), statt den Bindestrich stehen zu lassen.
    /// Absichtlich NUR dieser eine Trigger (kein Auto-Fortsetzen der Liste
    /// bei Enter) – das deckt genau an, was verlangt wurde, ohne zusätzliche,
    /// ungetestete Cursor-Logik zu riskieren.
    func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText replacement: String) -> Bool {
        guard supportsBullets, replacement == " ", range.length == 0, range.location >= 1 else { return true }

        let ns = textView.text as NSString
        guard ns.substring(with: NSRange(location: range.location - 1, length: 1)) == "-" else { return true }
        let isLineStart = range.location == 1
            || ns.substring(with: NSRange(location: range.location - 2, length: 1)) == "\n"
        guard isLineStart else { return true }

        let dashRange = NSRange(location: range.location - 1, length: 1)
        let bulletFont = textView.font ?? .preferredFont(forTextStyle: .body)
        let bullet = NSAttributedString(string: "•  ", attributes: [.font: bulletFont, .foregroundColor: UIColor.secondaryLabel])
        textView.textStorage.replaceCharacters(in: dashRange, with: bullet)
        textView.selectedRange = NSRange(location: dashRange.location + bullet.length, length: 0)
        syncText(from: textView)
        return false
    }

    private func syncText(from textView: UITextView) {
        text = Self.serialize(textView.attributedText)
    }

    // MARK: - Serialisierung (UITextView <-> FlashcardMarkdown-String)

    static func serialize(_ attributed: NSAttributedString) -> String {
        let fullString = attributed.string as NSString
        var offset = 0
        var resultLines: [String] = []
        for line in fullString.components(separatedBy: "\n") {
            let lineLength = (line as NSString).length
            let lineRange = NSRange(location: offset, length: lineLength)
            if line.hasPrefix("•") {
                let markerLength = min(3, lineLength) // "•  " = 1 Punkt + 2 Leerzeichen
                let restRange = NSRange(location: lineRange.location + markerLength, length: lineRange.length - markerLength)
                resultLines.append("- " + serializeInline(attributed, range: restRange))
            } else {
                resultLines.append(serializeInline(attributed, range: lineRange))
            }
            offset += lineLength + 1 // +1 für das "\n"
        }
        return resultLines.joined(separator: "\n")
    }

    private static func serializeInline(_ attributed: NSAttributedString, range: NSRange) -> String {
        guard range.length > 0, range.location + range.length <= attributed.length else { return "" }
        var out = ""
        attributed.enumerateAttribute(.font, in: range, options: []) { value, subrange, _ in
            let substring = (attributed.string as NSString).substring(with: subrange)
            let isBold = (value as? UIFont)?.fontDescriptor.symbolicTraits.contains(.traitBold) ?? false
            out += isBold ? "**\(substring)**" : substring
        }
        return out
    }

    static func deserialize(_ raw: String, baseFont: UIFont) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let lines = raw.components(separatedBy: "\n")
        for (index, line) in lines.enumerated() {
            if index > 0 { result.append(NSAttributedString(string: "\n")) }
            if line.hasPrefix("- ") {
                result.append(NSAttributedString(string: "•  ", attributes: [.font: baseFont, .foregroundColor: UIColor.secondaryLabel]))
                result.append(inlineBoldAttributed(String(line.dropFirst(2)), baseFont: baseFont))
            } else {
                result.append(inlineBoldAttributed(line, baseFont: baseFont))
            }
        }
        return result
    }

    private static func inlineBoldAttributed(_ line: String, baseFont: UIFont) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let segments = line.components(separatedBy: "**")
        for (index, segment) in segments.enumerated() {
            let font: UIFont
            if index % 2 == 1 {
                let descriptor = baseFont.fontDescriptor.withSymbolicTraits(
                    baseFont.fontDescriptor.symbolicTraits.union(.traitBold)
                ) ?? baseFont.fontDescriptor
                font = UIFont(descriptor: descriptor, size: baseFont.pointSize)
            } else {
                font = baseFont
            }
            result.append(NSAttributedString(string: segment, attributes: [.font: font, .foregroundColor: UIColor.label]))
        }
        return result
    }
}

/// Die eigentliche `UITextView`-Bridge. Rein UI-seitig – die ganze
/// Formatierungs-/Serialisierungslogik lebt im `RichTextEditorController`.
struct RichAnswerEditor: UIViewRepresentable {
    @ObservedObject var controller: RichTextEditorController

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.font = .preferredFont(forTextStyle: .body)
        textView.textColor = .label
        textView.backgroundColor = .clear
        textView.isScrollEnabled = true
        textView.delegate = controller
        textView.attributedText = RichTextEditorController.deserialize(controller.text, baseFont: textView.font ?? .preferredFont(forTextStyle: .body))
        controller.textView = textView
        return textView
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        // Kein Rückschreiben nötig: `controller.text` wird ausschließlich als
        // Reaktion auf Eingaben in genau dieser UITextView aktualisiert (siehe
        // syncText), nie von außen gesetzt. Ein Rückschreiben hier würde nur
        // unnötig den Cursor zurücksetzen.
    }

    func makeCoordinator() -> RichTextEditorController {
        controller
    }
}

/// Editor + "Fett"-Button + kurzer Tipp-Text (nur wenn Aufzählungspunkte
/// unterstützt werden) als fertiges, wiederverwendbares Feld für Frage und
/// Antwort in `AddFlashcardSheet`.
struct FormattedTextField: View {
    @ObservedObject var controller: RichTextEditorController
    var minHeight: CGFloat = 100

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button {
                    controller.toggleBold()
                } label: {
                    Image(systemName: "bold")
                }
                .buttonStyle(.bordered)

                if controller.supportsBullets {
                    Text("Tipp: \"- \" + Leertaste am Zeilenanfang = Aufzählungspunkt")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            RichAnswerEditor(controller: controller)
                .frame(minHeight: minHeight)
        }
    }
}
