import Foundation

/// Bewertung einer Wiederholung im Sinne von FSRS. Die App hat drei Buttons:
/// Falsch = Again, Teilweise = Hard (zählt in FSRS als "gerade noch gewusst"),
/// Richtig = Good. Easy gibt es (noch) nicht als Button, das Modell
/// unterstützt es aber vollständig.
enum FSRSRating: Int, CaseIterable {
    case again = 1, hard = 2, good = 3, easy = 4

    init(_ urteil: GradingResult.Urteil) {
        switch urteil {
        case .falsch: self = .again
        case .teilweise: self = .hard
        case .richtig: self = .good
        }
    }
}

/// Das FSRS-6-Gedächtnismodell (Free Spaced Repetition Scheduler, derselbe
/// Algorithmus wie in Anki). Formeln, Konstanten und Standardparameter sind
/// 1:1 aus der offiziellen Referenzimplementierung übernommen
/// (open-spaced-repetition/py-fsrs, `fsrs/scheduler.py`) und in
/// `FSRSTests` gegen eine unabhängige Nachrechnung geprüft.
///
/// Begriffe:
/// - Stabilität S: Tage, nach denen die Abrufwahrscheinlichkeit auf 90 % fällt.
/// - Schwierigkeit D: 1 (leicht) bis 10 (schwer).
/// - Abrufwahrscheinlichkeit R: Wie wahrscheinlich die Karte nach t Tagen noch sitzt.
struct FSRS {
    /// FSRS-6-Standardparameter (21 Werte, w0-w20).
    static let defaultWeights: [Double] = [
        0.212, 1.2931, 2.3065, 8.2956, 6.4133, 0.8334, 3.0194, 0.001, 1.8722, 0.1666, 0.796,
        1.4835, 0.0614, 0.2629, 1.6483, 0.6014, 1.8729, 0.5425, 0.0912, 0.0658, 0.1542,
    ]
    static let stabilityMin = 0.001
    static let minDifficulty = 1.0
    static let maxDifficulty = 10.0

    let w: [Double]
    /// Ziel-Abrufwahrscheinlichkeit zum Fälligkeitszeitpunkt (Anki-Standard 0,9).
    let desiredRetention: Double
    let maximumInterval: Int

    init(weights: [Double] = FSRS.defaultWeights, desiredRetention: Double = 0.9, maximumInterval: Int = 36_500) {
        precondition(weights.count == 21, "FSRS-6 braucht genau 21 Parameter")
        self.w = weights
        self.desiredRetention = desiredRetention
        self.maximumInterval = maximumInterval
    }

    var decay: Double { -w[20] }
    /// So gewählt, dass R(t = S) genau 0,9 ist.
    var factor: Double { pow(0.9, 1 / decay) - 1 }

    func retrievability(elapsedDays: Double, stability: Double) -> Double {
        pow(1 + factor * max(0, elapsedDays) / stability, decay)
    }

    func initialStability(_ rating: FSRSRating) -> Double {
        clampStability(w[rating.rawValue - 1])
    }

    func initialDifficulty(_ rating: FSRSRating, clamp: Bool = true) -> Double {
        let difficulty = w[4] - exp(w[5] * Double(rating.rawValue - 1)) + 1
        return clamp ? clampDifficulty(difficulty) : difficulty
    }

    /// Linear Damping + Mean Reversion zum Easy-Startwert.
    func nextDifficulty(_ difficulty: Double, _ rating: FSRSRating) -> Double {
        let delta = -(w[6] * Double(rating.rawValue - 3))
        let damped = difficulty + (10 - difficulty) * delta / 9
        let reverted = w[7] * initialDifficulty(.easy, clamp: false) + (1 - w[7]) * damped
        return clampDifficulty(reverted)
    }

    /// Stabilität nach einer Wiederholung am SELBEN Lerntag.
    func shortTermStability(_ stability: Double, _ rating: FSRSRating) -> Double {
        var increase = exp(w[17] * (Double(rating.rawValue) - 3 + w[18])) * pow(stability, -w[19])
        if rating != .again {
            increase = max(increase, 1)
        }
        return clampStability(stability * increase)
    }

    /// Stabilität nach erfolgreichem Abruf (Hard/Good/Easy) an einem späteren Tag.
    func nextRecallStability(difficulty: Double, stability: Double, retrievability: Double, rating: FSRSRating) -> Double {
        let hardPenalty = rating == .hard ? w[15] : 1
        let easyBonus = rating == .easy ? w[16] : 1
        let growth = exp(w[8]) * (11 - difficulty) * pow(stability, -w[9])
            * (exp((1 - retrievability) * w[10]) - 1) * hardPenalty * easyBonus
        return clampStability(stability * (1 + growth))
    }

    /// Stabilität nach Vergessen (Again) an einem späteren Tag.
    func nextForgetStability(difficulty: Double, stability: Double, retrievability: Double) -> Double {
        let longTerm = w[11] * pow(difficulty, -w[12]) * (pow(stability + 1, w[13]) - 1)
            * exp((1 - retrievability) * w[14])
        let shortTerm = stability / exp(w[17] * w[18])
        return clampStability(min(longTerm, shortTerm))
    }

    /// Ganze Tage bis zur nächsten Wiederholung (gerundet wie Python, d.h.
    /// .5 zur geraden Zahl, mindestens 1, höchstens `maximumInterval`).
    func nextInterval(stability: Double) -> Int {
        let raw = stability / factor * (pow(desiredRetention, 1 / decay) - 1)
        let rounded = Int(raw.rounded(.toNearestOrEven))
        return min(max(rounded, 1), maximumInterval)
    }

    private func clampStability(_ stability: Double) -> Double { max(stability, FSRS.stabilityMin) }
    private func clampDifficulty(_ difficulty: Double) -> Double {
        min(max(difficulty, FSRS.minDifficulty), FSRS.maxDifficulty)
    }
}

/// Lernzustand einer Karte für FSRS.
struct FSRSCardState: Equatable {
    var stability: Double?
    var difficulty: Double?
    var lastReview: Date?
    var due: Date?
    var reps: Int = 0
    var lapses: Int = 0

    var isNew: Bool { stability == nil || difficulty == nil || lastReview == nil }
}

/// Plant Wiederholungen mit FSRS (ohne Lernschritte -- das Wiederholen am
/// selben Tag übernimmt die Lernrunde selbst, siehe `StudyQueue`).
///
/// Konventionen (wie in Anki):
/// - Ein Lerntag beginnt um 4 Uhr morgens (Ortszeit). "Vergangene Tage" sind
///   Lerntage, nicht 24-Stunden-Blöcke -- wer abends lernt und am nächsten
///   Morgen wiederholt, hat einen Tag Abstand.
/// - Wiederholung am selben Lerntag -> Kurzzeit-Stabilität (FSRS-6).
/// - Falsch -> die Karte ist in 10 Minuten wieder fällig und kommt in der
///   laufenden Runde erneut dran.
/// - Sonst fällig zu Beginn des Lerntags in `nextInterval` Tagen. Kein
///   Zufallsrauschen ("fuzz"), damit alles nachvollziehbar bleibt.
/// - Prüfungstermin: Würde die nächste Wiederholung auf oder nach den
///   Prüfungstag fallen, wird sie auf die Hälfte der verbleibenden Tage
///   vorgezogen (mindestens 1). So kommt jede Karte vor der Prüfung noch
///   mindestens einmal dran, und die Abstände werden zur Prüfung hin kürzer,
///   statt dass sich alles auf den letzten Abend stapelt.
enum FSRSScheduler {
    static let againDelay: TimeInterval = 10 * 60
    static let dayStartHour = 4

    struct Outcome: Equatable {
        let state: FSRSCardState
        /// `nil` bei "Falsch" (dann in 10 Minuten fällig).
        let intervalDays: Int?
        /// Muss die Karte noch in dieser Lernrunde erneut abgefragt werden?
        var isDueAgainToday: Bool { intervalDays == nil }
    }

    static func review(
        _ card: FSRSCardState,
        rating: FSRSRating,
        now: Date = Date(),
        examDate: Date? = nil,
        fsrs: FSRS = FSRS(),
        calendar: Calendar = .current
    ) -> Outcome {
        var next = card
        if let stability = card.stability, let difficulty = card.difficulty, let lastReview = card.lastReview {
            let elapsed = learningDay(now, calendar: calendar) - learningDay(lastReview, calendar: calendar)
            if elapsed < 1 {
                next.stability = fsrs.shortTermStability(stability, rating)
            } else {
                let retrievability = fsrs.retrievability(elapsedDays: Double(elapsed), stability: stability)
                next.stability = rating == .again
                    ? fsrs.nextForgetStability(difficulty: difficulty, stability: stability, retrievability: retrievability)
                    : fsrs.nextRecallStability(difficulty: difficulty, stability: stability, retrievability: retrievability, rating: rating)
            }
            next.difficulty = fsrs.nextDifficulty(difficulty, rating)
            if rating == .again { next.lapses += 1 }
        } else {
            next.stability = fsrs.initialStability(rating)
            next.difficulty = fsrs.initialDifficulty(rating)
        }
        next.reps += 1
        next.lastReview = now

        guard rating != .again else {
            next.due = now.addingTimeInterval(againDelay)
            return Outcome(state: next, intervalDays: nil)
        }

        var interval = fsrs.nextInterval(stability: next.stability ?? 0)
        if let examDate {
            let daysUntilExam = learningDay(examDate, calendar: calendar) - learningDay(now, calendar: calendar)
            if daysUntilExam >= 1, interval >= daysUntilExam {
                interval = max(1, daysUntilExam / 2)
            }
        }
        next.due = startOfLearningDay(learningDay(now, calendar: calendar) + interval, calendar: calendar)
        return Outcome(state: next, intervalDays: interval)
    }

    /// Wann die Karte bei jeder Bewertung wieder dran wäre, als kurzer Text --
    /// für die Beschriftung der Buttons ("Richtig · 3 T").
    static func previewLabels(
        _ card: FSRSCardState,
        now: Date = Date(),
        examDate: Date? = nil,
        calendar: Calendar = .current
    ) -> [FSRSRating: String] {
        var result: [FSRSRating: String] = [:]
        for rating in FSRSRating.allCases {
            let outcome = review(card, rating: rating, now: now, examDate: examDate, calendar: calendar)
            result[rating] = intervalLabel(outcome.intervalDays)
        }
        return result
    }

    /// Kurzer Text für eine Vorschau, z.B. "10 Min", "1 T", "3 Wo", "2 Mon".
    static func intervalLabel(_ days: Int?) -> String {
        guard let days else { return "10 Min" }
        switch days {
        case ..<14: return "\(days) T"
        case ..<60: return "\(Int((Double(days) / 7).rounded())) Wo"
        case ..<365: return "\(Int((Double(days) / 30).rounded())) Mon"
        default:
            let years = (Double(days) / 365 * 10).rounded() / 10
            return String(format: "%.1f J", years).replacingOccurrences(of: ".", with: ",")
        }
    }

    // MARK: - Lerntage (Tagesgrenze 4 Uhr)

    /// Fortlaufende Nummer des Lerntags, zu dem `date` gehört.
    static func learningDay(_ date: Date, calendar: Calendar) -> Int {
        let shifted = date.addingTimeInterval(-Double(dayStartHour) * 3600)
        let reference = calendar.startOfDay(for: Date(timeIntervalSince1970: 0))
        return calendar.dateComponents([.day], from: reference, to: calendar.startOfDay(for: shifted)).day ?? 0
    }

    /// Beginn (4 Uhr) des Lerntags mit der Nummer `day`.
    static func startOfLearningDay(_ day: Int, calendar: Calendar) -> Date {
        let reference = calendar.startOfDay(for: Date(timeIntervalSince1970: 0))
        let dayStart = calendar.date(byAdding: .day, value: day, to: reference) ?? reference
        return calendar.date(byAdding: .hour, value: dayStartHour, to: dayStart) ?? dayStart
    }
}
