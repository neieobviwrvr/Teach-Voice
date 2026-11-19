import SwiftUI

/// Karte, die sich um die senkrechte Achse umdreht (wie bei StudyFlash).
/// `angle` 0 = Vorderseite, 180 = Rückseite. Die Seiten tauschen genau bei
/// 90° -- dann steht die Karte hochkant und man sieht keine von beiden.
/// `Animatable`, damit `withAnimation { flipped = true }` die Drehung
/// Bild für Bild durchrechnet.
struct FlipCard<Front: View, Back: View>: View, Animatable {
    var angle: Double
    let front: Front
    let back: Back

    init(angle: Double, @ViewBuilder front: () -> Front, @ViewBuilder back: () -> Back) {
        self.angle = angle
        self.front = front()
        self.back = back()
    }

    var animatableData: Double {
        get { angle }
        set { angle = newValue }
    }

    var body: some View {
        ZStack {
            if angle < 90 {
                front
            } else {
                // Gegengedreht, damit die Rückseite nicht spiegelverkehrt ist.
                back.rotation3DEffect(.degrees(180), axis: (x: 0, y: 1, z: 0))
            }
        }
        .rotation3DEffect(.degrees(angle), axis: (x: 0, y: 1, z: 0), perspective: 0.4)
    }
}

/// "Überspringen" in beiden Lernmodi (statt des früheren "Beenden"): die
/// Karte zählt als falsch gewusst (FSRS "Nochmal", kommt in der Runde
/// wieder), danach geht es direkt weiter. Beenden geht über den Zurück-Pfeil.
struct SkipCardButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Label("Überspringen", systemImage: "forward.fill")
                Text("zählt als falsch")
                    .font(.caption2)
                    .opacity(0.8)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .tint(Color.gray)
    }
}
