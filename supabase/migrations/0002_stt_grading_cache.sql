-- ============================================================
-- Lazy-Cache für die GPT-4o-mini-Kernelement-Extraktion der Musterantwort.
-- Wird vom Client gepflegt (nicht von einem DB-Trigger): beim Grading prüft
-- der Client per Hash, ob die Musterantwort seit dem letzten Cache geändert
-- wurde, und aktualisiert diese Spalten nur bei Bedarf.
-- ============================================================

alter table public.flashcards
  add column if not exists kernelemente jsonb,
  add column if not exists kernelemente_source_hash text;
