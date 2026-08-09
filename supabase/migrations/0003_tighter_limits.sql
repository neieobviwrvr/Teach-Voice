-- ============================================================
-- Verschärfte Limits für die Startphase (ausdrücklich als vorläufiger
-- Startwert bezeichnet, nicht als endgültige Grenze):
--   - maximal 1 Ober-Ordner pro Nutzer
--   - maximal 2 Unterordner pro Ober-Ordner
--   - maximal 10 (statt bisher 20) Karteikarten pro Unterordner
-- ============================================================

-- Bestehenden Trigger für Karteikarten von 20 auf 10 ändern.
create or replace function public.enforce_flashcard_limit()
returns trigger as $$
declare
  card_count integer;
begin
  select count(*) into card_count
  from public.flashcards
  where subfolder_id = new.subfolder_id;

  if card_count >= 10 then
    raise exception 'Maximal 10 Karteikarten pro Unterordner erlaubt';
  end if;

  return new;
end;
$$ language plpgsql;

-- Neu: maximal 1 Ober-Ordner pro Nutzer.
create or replace function public.enforce_folder_limit()
returns trigger as $$
declare
  folder_count integer;
begin
  select count(*) into folder_count
  from public.folders
  where user_id = new.user_id;

  if folder_count >= 1 then
    raise exception 'Maximal 1 Ordner pro Nutzer erlaubt (aktuelle Startphase)';
  end if;

  return new;
end;
$$ language plpgsql;

drop trigger if exists trg_folder_limit on public.folders;
create trigger trg_folder_limit
  before insert on public.folders
  for each row execute function public.enforce_folder_limit();

-- Neu: maximal 2 Unterordner pro Ober-Ordner.
create or replace function public.enforce_subfolder_limit()
returns trigger as $$
declare
  subfolder_count integer;
begin
  select count(*) into subfolder_count
  from public.subfolders
  where folder_id = new.folder_id;

  if subfolder_count >= 2 then
    raise exception 'Maximal 2 Unterordner pro Ordner erlaubt (aktuelle Startphase)';
  end if;

  return new;
end;
$$ language plpgsql;

drop trigger if exists trg_subfolder_limit on public.subfolders;
create trigger trg_subfolder_limit
  before insert on public.subfolders
  for each row execute function public.enforce_subfolder_limit();
