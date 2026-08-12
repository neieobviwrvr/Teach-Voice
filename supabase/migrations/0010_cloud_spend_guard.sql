-- ============================================================
-- Google-Cloud-Ausgaben-Deckel (Simons ausdrueckliche Vorgabe: "AUF
-- GARKEINEN FALL" das 260-Euro-Testguthaben ueberschreiten).
--
-- Bewusst NICHT auf Googles eigene Budget-Alerts verlassen -- die sind
-- reine Benachrichtigungen mit spuerbarer Verzoegerung (teils Stunden),
-- kein echter Sofort-Stopp. Dieser Zaehler wird stattdessen VOR jedem
-- einzelnen bezahlten Google-Cloud-Call atomar geprueft+erhoeht (gleiches
-- Muster wie rate_limit_counters/check_and_increment_rate_limit aus 0008,
-- inklusive derselben "FOR UPDATE"-Zeilensperre gegen Race Conditions bei
-- gleichzeitigen Requests).
--
-- Deckt sowohl das bereits laufende text-to-speech (Google Cloud WaveNet)
-- als auch ein etwaiges spaeteres Gemini-TTS ab -- beide haengen am
-- selben Google-Cloud-Billing-Konto und damit am selben 260-Euro-Guthaben.
--
-- RLS bewusst nicht aktiviert (nur service_role greift zu, wie bei
-- rate_limit_counters), Grants aber SOFORT entzogen -- die 0008/0009-
-- Lektion aus diesem Projekt direkt hier mit eingebaut, statt erst
-- nachtraeglich zu fixen.
-- ============================================================

create table public.cloud_spend_tracker (
  provider text primary key,
  total_cost_usd numeric not null default 0,
  updated_at timestamptz not null default now()
);

revoke all on public.cloud_spend_tracker from anon, authenticated, public;

create or replace function public.add_cloud_spend(
  p_provider text,
  p_amount_usd numeric,
  p_ceiling_usd numeric
)
returns table(allowed boolean, new_total numeric)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_current numeric;
begin
  -- Zeile sperren (falls schon vorhanden) -- verhindert, dass zwei
  -- gleichzeitige Requests beide "unter der Grenze" sehen und beide
  -- durchrutschen, obwohl ihre Summe die Grenze ueberschreiten wuerde.
  select total_cost_usd into v_current
  from public.cloud_spend_tracker
  where provider = p_provider
  for update;

  if v_current is null then
    insert into public.cloud_spend_tracker (provider, total_cost_usd)
    values (p_provider, 0)
    on conflict (provider) do nothing;
    v_current := 0;
  end if;

  if v_current + p_amount_usd > p_ceiling_usd then
    return query select false, v_current;
    return;
  end if;

  update public.cloud_spend_tracker
  set total_cost_usd = v_current + p_amount_usd, updated_at = now()
  where provider = p_provider;

  return query select true, v_current + p_amount_usd;
end;
$$;

revoke all on function public.add_cloud_spend(text, numeric, numeric) from anon, authenticated, public;
grant execute on function public.add_cloud_spend(text, numeric, numeric) to service_role;
