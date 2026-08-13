import SwiftUI

/// Wrapping "Tag-Cloud"-artiges Layout: reiht Subviews von links nach rechts
/// auf und bricht automatisch in eine neue Zeile um, sobald die vorgegebene
/// Breite nicht mehr ausreicht.
///
/// Grund für diese eigene Implementierung (statt eines HStack mit fixem
/// Offset/Radius, wie ursprünglich im "Lernen"-Mindmap-Reveal auf
/// `FolderListView` verwendet): ein `Layout` bekommt von SwiftUI die ECHTE,
/// vom Elternview vorgegebene Breite (`proposal.width`) und misst die ECHTE
/// Größe jeder Subview (`subview.sizeThatFits`) -- Zeilenumbrüche passieren
/// dadurch automatisch korrekt, egal wie schmal der Bildschirm oder wie lang
/// der Text einer einzelnen Pille ist. Kein manuelles Schätzen von
/// Pixel-Radien/-Offsets nötig, die auf einem anderen Gerät/einer anderen
/// iOS-Version brechen könnten.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0
        var usedWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                totalHeight += rowHeight + lineSpacing
                usedWidth = max(usedWidth, x - spacing)
                x = 0
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        totalHeight += rowHeight
        usedWidth = max(usedWidth, x - spacing)

        // Bei endlicher Breitenvorgabe (Normalfall: innerhalb einer List-Row)
        // genau diese Breite melden, statt nur den tatsächlich genutzten
        // Platz -- sonst würde das Elternview die FlowLayout auf die Breite
        // der längsten Zeile zusammenschrumpfen statt sie zu füllen.
        let width = maxWidth.isFinite ? maxWidth : usedWidth
        return CGSize(width: width, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x: CGFloat = bounds.minX
        var y: CGFloat = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + lineSpacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: .unspecified)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
