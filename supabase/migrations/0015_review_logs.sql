-- ============================================================
-- Protokoll jeder einzelnen Bewertung (Simons Wunsch: Lernverlauf mit
-- Lerntagen, Serie und Karten pro Tag).
--
-- Zusätzlich die Grundlage, um FSRS später auf Simons persönliches
-- Gedächtnis zu trainieren (FSRS-Optimierer braucht genau diese Historie:
-- welche Karte, wann, welche Bewertung). Deshalb werden auch Stabilität,
-- Schwierigkeit und Abstand mitgeschrieben.
--
-- Nur Einfügen und Lesen der eigenen Einträge (RLS). Wird eine Karte
-- gelöscht, verschwinden ihre Einträge mit.
-- ============================================================

create table if not exists public.review_logs (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  flashcard_id uuid not null references public.flashcards(id) on delete cascade,
  rating smallint not null check (rating between 1 and 4),
  reviewed_at timestamptz not null default now(),
  mode text not null check (mode in ('sprechen', 'tippen')),
  -- Lerntage seit der vorherigen Wiederholung; null bei einer neuen Karte.
  elapsed_days integer,
  -- Geplanter Abstand in Tagen; null bei "Nochmal" (10 Minuten).
  interval_days integer,
  stability double precision not null,
  difficulty double precision not null,
  -- Anteil getroffener Kontrollpunkte im Sprach-Modus.
  deckung_prozent double precision
);

create index if not exists idx_review_logs_user_time on public.review_logs(user_id, reviewed_at);
create index if not exists idx_review_logs_flashcard on public.review_logs(flashcard_id);

alter table public.review_logs enable row level security;

create policy "Users read own review logs" on public.review_logs
  for select using (auth.uid() = user_id);

create policy "Users insert own review logs" on public.review_logs
  for insert with check (auth.uid() = user_id);
