-- ============================================================
-- Keine Mengen-Limits mehr (Simons Entscheidung fürs MVP, das vorerst nur er
-- selbst nutzt): beliebig viele Ober-Ordner, Unterordner und Karteikarten.
--
-- Entfernt die Trigger aus 0001/0003/0005/0007/0011. Das Subfolder-Limit ist
-- schon seit 0007 weg. Längen-Obergrenzen für Fragen/Antworten bleiben
-- bestehen (die liegen in den Edge Functions, nicht hier), ebenso RLS.
-- ============================================================

drop trigger if exists trg_folder_limit on public.folders;
drop function if exists public.enforce_folder_limit();

drop trigger if exists trg_flashcard_limit on public.flashcards;
drop function if exists public.enforce_flashcard_limit();
