-- ============================================================
-- Einfaches 5-Stufen-Box-System für Spaced Repetition im Hands-free-Modus.
-- srs_box: 1-5, srs_due_at: wann die Karte als nächstes fällig ist
-- (NULL = noch nie bewertet), srs_last_reviewed_at: letzte Bewertung
-- (egal ob per Selbsteinschätzung im Detail-Modus oder GPT im Hands-free-Modus).
--
-- Box-Intervalle (Tage), Box 1 = Index 0: [0, 1, 3, 7, 14].
-- Übergänge: "richtig" -> Box+1 (max. 5), "teilweise" -> Box bleibt gleich,
-- "falsch" -> zurück auf Box 1. Siehe Core/SpacedRepetition.swift.
-- ============================================================

alter table public.flashcards
  add column if not exists srs_box integer not null default 1,
  add column if not exists srs_due_at timestamptz,
  add column if not exists srs_last_reviewed_at timestamptz;
