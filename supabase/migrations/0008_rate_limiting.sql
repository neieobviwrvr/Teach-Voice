-- ============================================================
-- Rate-Limiting-Grundlage für grade-answer/generate-questions.
--
-- Bewusst eine bewusste Abweichung vom "zustandslos"-Prinzip der beiden
-- Functions: reiner Zähler, keine Nutzdaten. Ohne das kann JEDER, der den
-- öffentlichen anon-Key aus der IPA extrahiert, die Functions beliebig oft
-- aufrufen und auf Simons OpenAI-Kosten missbrauchen.
--
-- Identität ist entweder "user:<uuid>" (eingeloggt, aus dem JWT) oder
-- "ip:<adresse>" (Gastmodus – alle Gäste teilen sich denselben anon-Key,
-- daher IP als Notlösung; NAT/CGNAT kann mehrere echte User zusammenwerfen,
-- das ist ein bekannter, akzeptierter Kompromiss, kein Bug).
-- ============================================================

create table if not exists public.rate_limit_counters (
  identity text not null,
  window_start timestamptz not null,
  request_count integer not null default 1,
  primary key (identity, window_start)
);

-- RLS bewusst NICHT aktiviert: diese Tabelle wird ausschließlich von den
-- Edge Functions über den service_role-Key angesprochen (bypasst RLS
-- ohnehin), nie direkt vom Client. Kein User-Bezug in den Daten, der
-- geschützt werden müsste.

-- Atomarer Check-and-Increment (ein einziges Statement, dadurch race-sicher
-- auch bei parallelen Requests derselben Identität). Feste Stunden-Fenster
-- statt gleitendem Fenster – für Abuse-Schutz präzise genug, viel einfacher.
create or replace function public.check_and_increment_rate_limit(
  p_identity text,
  p_max_requests integer
) returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_count integer;
begin
  insert into public.rate_limit_counters (identity, window_start, request_count)
  values (p_identity, date_trunc('hour', now()), 1)
  on conflict (identity, window_start)
  do update set request_count = rate_limit_counters.request_count + 1
  returning request_count into v_count;

  return v_count <= p_max_requests;
end;
$$;

-- Alte Fenster gelegentlich aufräumen, damit die Tabelle nicht unbegrenzt
-- wächst (kein Cron hier eingerichtet – manuell/gelegentlich per Management
-- API ausführbar, oder später per pg_cron nachrüstbar).
create or replace function public.cleanup_old_rate_limit_counters()
returns void
language sql
security definer
set search_path = public
as $$
  delete from public.rate_limit_counters where window_start < now() - interval '48 hours';
$$;
