-- ============================================================
-- Karteikarten-Limit pro Unterordner: 10 -> 25.
--
-- Grund: der PDF-Import (Text extrahieren -> GPT generiert bis zu 25 Fragen
-- -> User wählt per Checkbox aus) soll die generierten Fragen sinnvoll in
-- einen einzelnen Unterordner packen können. Bei weiterhin nur 10 wäre die
-- "wie viele Fragen generieren?"-Auswahl (12/18/25) im Client großteils
-- witzlos, weil das DB-Limit sofort hart abschneidet.
--
-- maxFoldersPerUser (1) und maxSubfoldersPerFolder (2) bleiben unverändert.
-- ============================================================

create or replace function public.enforce_flashcard_limit()
returns trigger as $$
declare
  card_count integer;
begin
  select count(*) into card_count
  from public.flashcards
  where subfolder_id = new.subfolder_id;

  if card_count >= 25 then
    raise exception 'Maximal 25 Karteikarten pro Unterordner erlaubt';
  end if;

  return new;
end;
$$ language plpgsql;
