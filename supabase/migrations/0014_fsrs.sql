-- ============================================================
-- FSRS (Free Spaced Repetition Scheduler, derselbe Algorithmus wie in Anki)
-- ersetzt das bisherige 5-Boxen-System (Simons Wunsch: "FSRS für die ganze
-- App, MUSS richtig funktionieren").
--
-- Pro Karte merkt sich FSRS Stabilität und Schwierigkeit. Fälligkeit und
-- letzte Wiederholung stehen weiter in srs_due_at / srs_last_reviewed_at.
-- srs_box bleibt nur aus Kompatibilität stehen und wird nicht mehr benutzt.
-- Karten ohne fsrs_stability gelten als neu (betrifft beim Umstieg nur eine
-- einzige bisher bewertete Karte).
--
-- Dazu ein optionaler Prüfungstermin pro Ober-Ordner: Würde eine Karte erst
-- nach der Prüfung wieder fällig, zieht die App die Wiederholung vor.
--
-- Nur neue Spalten: RLS und die bestehenden Grants der Tabellen gelten
-- automatisch auch für sie.
-- ============================================================

alter table public.flashcards
  add column if not exists fsrs_stability double precision,
  add column if not exists fsrs_difficulty double precision,
  add column if not exists fsrs_reps integer not null default 0,
  add column if not exists fsrs_lapses integer not null default 0;

alter table public.folders
  add column if not exists exam_at timestamptz;
