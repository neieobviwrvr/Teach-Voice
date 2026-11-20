import SwiftUI
import UIKit

/// Wie der "Halten zum Nachdenken"-Kreis losgelassen wurde.
enum HoldRelease: Equatable {
    /// Nur kurz angetippt -- zählt nicht, Aufnahme läuft normal weiter.
    case tap
    /// Lange genug gehalten -> sofort auswerten (wie "Fertig").
    case submit
    /// An einen Bildschirmrand gezogen -> Karte überspringen (zählt als
    /// falsch) und die Rückseite mit der Lösung zeigen.
    case skipWithSolution
}

/// Reine Entscheidungslogik des Kreises, ohne View -- testbar
/// (`HoldReleaseRuleTests`).
enum HoldReleaseRule {
    /// Kürzer gehalten = nur angetippt (zählt nicht).
    static let minimumHold: TimeInterval = 0.5
    /// So nah (pt) muss der Finger an einen Bildschirmrand, damit Loslassen
    /// überspringt.
    static let edgeMargin: CGFloat = 28
    /// Mindestweg (pt) seit dem Drücken. Der Kreis sitzt schon nah am unteren
    /// Rand -- ohne Mindestweg würde ein leichtes Abrutschen des Fingers beim
    /// Nachdenken die Karte überspringen und die Antwort verwerfen.
    static let minimumTravel: CGFloat = 50

    /// Liegt der Finger (globale Koordinaten = Fensterkoordinaten) im
    /// Überspringen-Bereich an einem der vier Ränder?
    static func isInSkipZone(location: CGPoint, start: CGPoint, bounds: CGRect) -> Bool {
        guard bounds.width > 0, bounds.height > 0 else { return false }
        let travel = hypot(location.x - start.x, location.y - start.y)
        guard travel >= minimumTravel else { return false }
        return location.x <= bounds.minX + edgeMargin
            || location.x >= bounds.maxX - edgeMargin
            || location.y <= bounds.minY + edgeMargin
            || location.y >= bounds.maxY - edgeMargin
    }

    /// Rand schlägt Haltedauer: auch ein schnelles Wegwischen an den Rand
    /// überspringt.
    static func release(heldFor seconds: TimeInterval, inSkipZone: Bool,
                        minimumHold: TimeInterval = HoldReleaseRule.minimumHold) -> HoldRelease {
        if inSkipZone { return .skipWithSolution }
        return seconds >= minimumHold ? .submit : .tap
    }
}

/// Runder "Halten zum Nachdenken"-Button für den Sprach-Modus (Simons Idee):
/// Solange man ihn gedrückt hält, endet die Aufnahme nicht durch Stille --
/// man kann in Ruhe nachdenken und dabei schon sprechen. Der Kreis folgt dem
/// Finger über das ganze Display, das Halten bleibt dabei bestehen.
/// Loslassen wertet sofort aus (wie "Fertig" bzw. die abgelaufene
/// Denkpause), danach federt der Kreis an seinen Platz zurück.
///
/// An einen Bildschirmrand gezogen (egal welcher, Simons Wunsch 2026-11-20)
/// wird der Kreis rot; Loslassen dort überspringt die Karte (zählt als
/// falsch) und zeigt die Rückseite mit der Lösung. Zurückziehen bricht das ab.
///
/// Kurzes Antippen (unter `HoldReleaseRule.minimumHold`) zählt bewusst nicht, damit keine
/// Antwort aus Versehen abgegeben wird -- dann erscheint nur der Hinweis
/// "Gedrückt halten" und die Aufnahme läuft normal weiter.
struct HoldToThinkButton: View {
    static let diameter: CGFloat = 96

    let onHoldStart: () -> Void
    let onHoldEnd: (HoldRelease) -> Void

    private struct Press: Equatable {
        var translation: CGSize
        var location: CGPoint
        var start: CGPoint
    }

    /// Aktueller Druck, `nil` = nicht gedrückt. Setzt sich auch zurück, wenn
    /// das System die Geste abbricht -- dadurch kann der Kreis nie "gedrückt"
    /// hängen bleiben. Beim Loslassen liefert `onChange` den letzten Stand
    /// als alten Wert (dort steht, wo der Finger zuletzt war).
    @GestureState private var press: Press? = nil
    @State private var pressStart: Date?
    @State private var windowBounds: CGRect = .zero
    @State private var showTapHint = false
    @State private var hintTask: Task<Void, Never>?

    private var isPressed: Bool { press != nil }

    private var inSkipZone: Bool {
        guard let press else { return false }
        return HoldReleaseRule.isInSkipZone(location: press.location, start: press.start, bounds: windowBounds)
    }

    private var caption: String {
        if showTapHint { return "Gedrückt halten" }
        if inSkipZone { return "Loslassen = überspringen + Lösung" }
        return isPressed ? "Loslassen = auswerten" : "Halten zum Nachdenken"
    }

    private var circleColor: Color {
        if inSkipZone { return .red }
        return isPressed ? .orange : .accentColor
    }

    var body: some View {
        VStack(spacing: 6) {
            Text(caption)
                .font(.caption.bold())
                .foregroundStyle(showTapHint ? Color.orange : (inSkipZone ? Color.red : Color.secondary))
                .multilineTextAlignment(.center)
            circle
        }
        .frame(maxWidth: .infinity)
    }

    private var circle: some View {
        ZStack {
            Circle()
                .fill(circleColor)
                .shadow(color: .black.opacity(isPressed ? 0.3 : 0.15), radius: isPressed ? 12 : 6, y: 4)
            VStack(spacing: 2) {
                if inSkipZone {
                    Image(systemName: "forward.fill")
                        .font(.system(size: 28, weight: .semibold))
                    Text("Überspringen")
                        .font(.caption2.bold())
                } else {
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
            }
            .foregroundStyle(.white)
        }
        .frame(width: Self.diameter, height: Self.diameter)
        .scaleEffect(isPressed ? 1.12 : 1)
        .contentShape(Circle())
        .gesture(holdGesture)
        // Folgt dem Finger ohne Verzögerung; nur beim Drücken/Loslassen wird
        // animiert (Zurückfedern an den festen Platz).
        .offset(press?.translation ?? .zero)
        .animation(.spring(response: 0.35, dampingFraction: 0.7), value: isPressed)
        .animation(.easeOut(duration: 0.15), value: inSkipZone)
        .sensoryFeedback(.impact(weight: .medium), trigger: isPressed)
        // Spürbar, sobald Loslassen überspringen würde -- auch wer beim
        // Nachdenken nicht hinschaut, merkt es.
        .sensoryFeedback(.warning, trigger: inSkipZone) { _, entered in entered }
        .onChange(of: press) { old, new in
            if old == nil, new != nil {
                pressStarted()
            } else if let old, new == nil {
                pressEnded(last: old)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Halten zum Nachdenken")
        .accessibilityHint("Solange du hältst, endet die Aufnahme nicht durch Stille. Beim Loslassen wird ausgewertet. An den Bildschirmrand gezogen wird die Karte übersprungen und die Lösung gezeigt.")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: "Überspringen und Lösung zeigen") {
            onHoldEnd(.skipWithSolution)
        }
    }

    /// `minimumDistance: 0`: zählt sofort beim Aufsetzen des Fingers als
    /// gedrückt. Globale Koordinaten, damit das Mitbewegen des Kreises die
    /// gemessene Verschiebung nicht verfälscht -- und damit `location` direkt
    /// mit den Fenstergrenzen verglichen werden kann.
    private var holdGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .updating($press) { value, state, _ in
                state = Press(translation: value.translation, location: value.location, start: value.startLocation)
            }
    }

    private func pressStarted() {
        hintTask?.cancel()
        showTapHint = false
        pressStart = Date()
        windowBounds = Self.currentWindowBounds() ?? .zero
        onHoldStart()
    }

    private func pressEnded(last: Press) {
        let held = pressStart.map { Date().timeIntervalSince($0) } ?? 0
        pressStart = nil
        let inZone = HoldReleaseRule.isInSkipZone(location: last.location, start: last.start, bounds: windowBounds)
        let release = HoldReleaseRule.release(heldFor: held, inSkipZone: inZone)
        onHoldEnd(release)
        guard release == .tap else { return }
        showTapHint = true
        hintTask?.cancel()
        hintTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if !Task.isCancelled { showTapHint = false }
        }
    }

    /// Grenzen des Fensters, in dem die App läuft. `.global` in SwiftUI ist
    /// relativ zu genau diesem Fenster.
    private static func currentWindowBounds() -> CGRect? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        return (scene?.keyWindow ?? scene?.windows.first)?.bounds
    }

    /// "0:07", "1:23". `nonisolated`, damit Tests sie direkt aufrufen können
    /// (Views sind seit dem iOS-18-SDK MainActor-gebunden).
    nonisolated static func elapsedLabel(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
