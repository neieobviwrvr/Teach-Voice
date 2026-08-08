-- ============================================================
-- Teach (Voice) - Initial Schema
-- Ordner (top-level) -> Unterordner -> Karteikarten (Frage/Antwort)
-- Auth: Supabase Auth (E-Mail + Passwort)
-- ============================================================

create extension if not exists "pgcrypto";

-- ------------------------------------------------------------
-- Tables
-- ------------------------------------------------------------

create table if not exists public.folders (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  name text not null,
  position integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.subfolders (
  id uuid primary key default gen_random_uuid(),
  folder_id uuid not null references public.folders(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  name text not null,
  position integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.flashcards (
  id uuid primary key default gen_random_uuid(),
  subfolder_id uuid not null references public.subfolders(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  question text not null,
  answer text not null,
  position integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists idx_subfolders_folder_id on public.subfolders(folder_id);
create index if not exists idx_flashcards_subfolder_id on public.flashcards(subfolder_id);
create index if not exists idx_folders_user_id on public.folders(user_id);
create index if not exists idx_subfolders_user_id on public.subfolders(user_id);
create index if not exists idx_flashcards_user_id on public.flashcards(user_id);

-- ------------------------------------------------------------
-- Row Level Security: jeder User sieht/bearbeitet nur eigene Daten
-- ------------------------------------------------------------

alter table public.folders enable row level security;
alter table public.subfolders enable row level security;
alter table public.flashcards enable row level security;

create policy "Users manage own folders" on public.folders
  for all using (auth.uid() = user_id) with check (auth.uid() = user_id);

create policy "Users manage own subfolders" on public.subfolders
  for all using (auth.uid() = user_id) with check (auth.uid() = user_id);

create policy "Users manage own flashcards" on public.flashcards
  for all using (auth.uid() = user_id) with check (auth.uid() = user_id);

-- ------------------------------------------------------------
-- updated_at automatisch pflegen
-- ------------------------------------------------------------

create or replace function public.set_updated_at()
returns trigger as $$
begin
  new.updated_at = now();
  return new;
end;
$$ language plpgsql;

create trigger trg_folders_updated_at before update on public.folders
  for each row execute function public.set_updated_at();
create trigger trg_subfolders_updated_at before update on public.subfolders
  for each row execute function public.set_updated_at();
create trigger trg_flashcards_updated_at before update on public.flashcards
  for each row execute function public.set_updated_at();

-- ------------------------------------------------------------
-- Limit: maximal 20 Karteikarten pro Unterordner
-- ------------------------------------------------------------

create or replace function public.enforce_flashcard_limit()
returns trigger as $$
declare
  card_count integer;
begin
  select count(*) into card_count
  from public.flashcards
  where subfolder_id = new.subfolder_id;

  if card_count >= 20 then
    raise exception 'Maximal 20 Karteikarten pro Unterordner erlaubt';
  end if;

  return new;
end;
$$ language plpgsql;

create trigger trg_flashcard_limit
  before insert on public.flashcards
  for each row execute function public.enforce_flashcard_limit();
