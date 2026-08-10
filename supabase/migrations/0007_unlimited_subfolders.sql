-- ============================================================
-- Unterordner pro Ober-Ordner: unbegrenzt (Simons Entscheidung). Bremsend
-- ist stattdessen jetzt eine NEUE Gesamt-Obergrenze von 50 Karteikarten pro
-- Ober-Ordner, über ALLE seine Unterordner zusammen gerechnet – nicht mehr
-- die Anzahl der Unterordner selbst.
--
-- maxFlashcardsPerSubfolder (25, pro einzelnem Unterordner) bleibt
-- unverändert bestehen und wirkt zusätzlich zur neuen 50er-Gesamtgrenze,
-- damit ein einzelner Unterordner nicht die ganzen 50 Plätze allein belegt.
-- ============================================================

-- Trigger + Funktion für das bisherige 2-Unterordner-Limit entfernen.
drop trigger if exists trg_subfolder_limit on public.subfolders;
drop function if exists public.enforce_subfolder_limit();

-- enforce_flashcard_limit prüft jetzt ZUSÄTZLICH zum bestehenden
-- Pro-Unterordner-Limit (25) die Gesamtzahl über alle Unterordner desselben
-- Ober-Ordners.
create or replace function public.enforce_flashcard_limit()
returns trigger as $$
declare
  card_count integer;
  folder_total integer;
  target_folder_id uuid;
begin
  select count(*) into card_count
  from public.flashcards
  where subfolder_id = new.subfolder_id;

  if card_count >= 25 then
    raise exception 'Maximal 25 Karteikarten pro Unterordner erlaubt';
  end if;

  select folder_id into target_folder_id
  from public.subfolders
  where id = new.subfolder_id;

  select count(*) into folder_total
  from public.flashcards f
  join public.subfolders s on s.id = f.subfolder_id
  where s.folder_id = target_folder_id;

  if folder_total >= 50 then
    raise exception 'Maximal 50 Karteikarten pro Ordner erlaubt (über alle Unterordner zusammen)';
  end if;

  return new;
end;
$$ language plpgsql;
