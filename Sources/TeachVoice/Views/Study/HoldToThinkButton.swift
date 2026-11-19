import SwiftUI

/// Runder "Halten zum Nachdenken"-Button für den Sprach-Modus (Simons Idee):
/// Solange man ihn gedrückt hält, endet die Aufnahme nicht durch Stille --
/// man kann in Ruhe nachdenken und dabei schon sprechen. Der Kreis folgt dem
/// Finger über das ganze Display, das Halten bleibt dabei bestehen.
/// Loslassen wertet sofort aus (wie "Fertig" bzw. die abgelaufene
/// Denkpause), danach federt der Kreis an seinen Platz zurück.
///
/// Kurzes Antippen (unter `minimumHold`) zählt bewusst nicht, damit keine
/// Antwort aus Versehen abgegeben wird -- dann erscheint nur der Hinweis
/// "Gedrückt halten" und die Aufnahme läuft normal weiter.
struct HoldToThinkButton: View {
    static let minimumHold: TimeInterval = 0.5
    static let diameter: CGFloat = 96

    let onHoldStart: () -> Void
    /// `submit`: lange genug gehalten -> auswerten. Sonst nur angetippt.
    let onHoldEnd: (_ submit: Bool) -> Void

    /// Fingerverschiebung seit dem Drücken, `nil` = nicht gedrückt. Setzt
    /// sich auch zurück, wenn das System die Geste abbricht -- dadurch kann
    /// der Kreis nie "gedrückt" hängen bleiben.
    @GestureState private var press: CGSize? = nil
    @State private var pressStart: Date?
    @State private var showTapHint = false
    @State private var hintTask: Task<Void, Never>?

    private var isPressed: Bool { press != nil }

    private var caption: String {
        if showTapHint { return "Gedrückt halten" }
        return isPressed ? "Loslassen = auswerten" : "Halten zum Nachdenken"
    }

    var body: some View {
        VStack(spacing: 6) {
            Text(caption)
                .font(.caption.bold())
                .foregroundStyle(showTapHint ? Color.orange : Color.secondary)
            circle
        }
        .frame(maxWidth: .infinity)
    }

    private var circle: some View {
        ZStack {
            Circle()
                .fill(isPressed ? Color.orange : Color.accentColor)
                .shadow(color: .black.opacity(isPressed ? 0.3 : 0.15), radius: isPressed ? 12 : 6, y: 4)
            VStack(spacing: 2) {
                Image(systemName: "brain.head.profile")
                    .font(.system(size: 30, weight: .semibold))
                    .symbolEffect(.pulse, isActive: isPressed)
                if isPressed, let pressStart {
                    TimelineView(.periodic(from: pressStart, by: 1)) { context in
                        Text(Self.elapsedLabel(context.date.timeIntervalSince(pressStart)))
                            .font(.caption.monospacedDigit().bold())
                    }
                }
            }
            .foregroundStyle(.white)
        }
        .frame(width: Self.diameter, height: Self.diameter)
        .scaleEffect(isPressed ? 1.12 : 1)
        .contentShape(Circle())
        .gesture(holdGesture)
        // Folgt dem Finger ohne Verzögerung; nur beim Drücken/Loslassen wird
        // animiert (Zurückfedern an den festen Platz).
        .offset(press ?? .zero)
        .animation(.spring(response: 0.35, dampingFraction: 0.7), value: isPressed)
        .sensoryFeedback(.impact(weight: .medium), trigger: isPressed)
        .onChange(of: isPressed) { _, pressed in
            if pressed { pressStarted() } else { pressEnded() }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Halten zum Nachdenken")
        .accessibilityHint("Solange du hältst, endet die Aufnahme nicht durch Stille. Beim Loslassen wird ausgewertet.")
        .accessibilityAddTraits(.isButton)
    }

    /// `minimumDistance: 0`: zählt sofort beim Aufsetzen des Fingers als
    /// gedrückt. Globale Koordinaten, damit das Mitbewegen des Kreises die
    /// gemessene Verschiebung nicht verfälscht.
    private var holdGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .updating($press) { value, state, _ in
                state = value.translation
            }
    }

    private func pressStarted() {
        hintTask?.cancel()
        showTapHint = false
        pressStart = Date()
        onHoldStart()
    }

    private func pressEnded() {
        let held = pressStart.map { Date().timeIntervalSince($0) } ?? 0
        pressStart = nil
        let submit = held >= Self.minimumHold
        onHoldEnd(submit)
        guard !submit else { return }
        showTapHint = true
        hintTask?.cancel()
        hintTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if !Task.isCancelled { showTapHint = false }
        }
    }

    /// "0:07", "1:23". `nonisolated`, damit Tests sie direkt aufrufen können
    /// (Views sind seit dem iOS-18-SDK MainActor-gebunden).
    nonisolated static func elapsedLabel(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
