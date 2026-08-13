-- ============================================================
-- Ober-Ordner-Limit von 1 auf 2 pro Nutzer gelockert (Simon: "Lockere das
-- Ordnerlimit auf zwei, damit wir das auch testen können" -- zum Testen des
-- neuen Oberordner-Dropdowns in FolderListView, das bei nur 1 Ordner nie
-- eine echte Auswahl zeigt). Client-seitige Spiegelung: `maxFoldersPerUser`
-- in Models.swift, siehe dortigen Kommentar.
-- ============================================================

create or replace function public.enforce_folder_limit()
returns trigger as $$
declare
  folder_count integer;
begin
  select count(*) into folder_count
  from public.folders
  where user_id = new.user_id;

  if folder_count >= 2 then
    raise exception 'Maximal 2 Ordner pro Nutzer erlaubt (aktuelle Startphase)';
  end if;

  return new;
end;
$$ language plpgsql;
