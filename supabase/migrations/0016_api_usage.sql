-- ============================================================
-- Eigene Kostenmessung + Datenquelle für das interne Dashboard (dashboard/).
--
-- Simons Wunsch: die Kosten der bezahlten APIs (Google Cloud TTS, OpenAI)
-- pro Stimmklasse/Funktion und Zeitraum im Blick haben, plus Nutzungs-
-- Analytics. Bis hierhin gab es dafür keine Daten: cloud_spend_tracker
-- (0010) hält nur EINE Gesamtsumme pro Anbieter (für den harten Deckel),
-- rate_limit_counters (0008) zählt nur Aufrufe pro Identität und Stunde,
-- und die OpenAI-Token aus der API-Antwort wurden verworfen.
--
-- api_usage_events: eine Zeile pro bezahltem Aufruf, geschrieben von
-- text-to-speech, grade-answer und generate-questions über
-- _shared/usageLog.ts (service_role). Bewusst KEINE Inhalte (keine Frage,
-- Antwort, kein Transkript, kein Vorlesetext) und KEINE IP-Adresse -- nur
-- Mengen, Preisklasse, Status und die User-ID (Gäste: is_guest = true,
-- user_id null). Die Kosten sind eine Schätzung aus Zeichen bzw. Token mal
-- Listenpreis (_shared/apiPricing.ts), ohne Freikontingent -- die
-- offiziellen Zahlen bleiben die Google-Cloud-Konsole und das
-- OpenAI-Usage-Dashboard.
--
-- Zugriff: RLS an, alle Grants für anon/authenticated entzogen (Lektion
-- aus 0008/0009) -- nur service_role. Das Dashboard liest ausschließlich
-- über die Edge Function admin-dashboard, die den Aufrufer als Admin prüft
-- und dann admin_dashboard() unten aufruft.
-- ============================================================

create table if not exists public.api_usage_events (
  id bigint generated always as identity primary key,
  created_at timestamptz not null default now(),
  -- Welche Edge Function den Aufruf gemacht hat.
  function_name text not null,
  -- 'tts' | 'grading' | 'extraction' | 'question_generation'
  operation text not null,
  -- 'google_tts' | 'openai'
  provider text not null,
  -- Stimme (z.B. de-DE-Chirp3-HD-Despina) bzw. Modell (gpt-4o-mini).
  model text not null,
  -- Preisklasse: 'wavenet' | 'chirp3_hd' | Modellname bei OpenAI.
  price_class text not null,
  -- ok = bezahlter Aufruf erfolgreich; error = Anbieter-Fehler/Netzwerk;
  -- blocked = vom Google-Kostendeckel abgelehnt (kein Call an Google).
  status text not null check (status in ('ok', 'error', 'blocked')),
  http_status integer,
  characters integer not null default 0 check (characters >= 0),
  input_tokens integer not null default 0 check (input_tokens >= 0),
  cached_input_tokens integer not null default 0 check (cached_input_tokens >= 0),
  output_tokens integer not null default 0 check (output_tokens >= 0),
  estimated_cost_usd numeric(14, 8) not null default 0 check (estimated_cost_usd >= 0),
  -- Beim Löschen eines Accounts bleibt die Kostenzeile anonym erhalten.
  user_id uuid references auth.users(id) on delete set null,
  is_guest boolean not null default false,
  duration_ms integer
);

create index if not exists idx_api_usage_events_created_at on public.api_usage_events(created_at);

alter table public.api_usage_events enable row level security;
revoke all on public.api_usage_events from anon, authenticated, public;

-- ============================================================
-- admin_dashboard(): liefert alles, was das Dashboard anzeigt, als ein
-- JSON-Objekt. security definer (liest auth.users, rate_limit_counters,
-- cloud_spend_tracker und die Lerndaten ALLER Nutzer) -- deshalb darf NUR
-- service_role sie ausführen. Die Admin-Prüfung passiert davor in der Edge
-- Function admin-dashboard (ADMIN_USER_IDS).
--
-- Tage: Kosten nach Kalendertag in p_tz; Lerndaten nach Lerntag (Grenze
-- 04:00 Ortszeit, wie in der App: FSRSScheduler/LearningStats).
-- ============================================================

create or replace function public.admin_dashboard(
  p_days integer default 30,
  p_tz text default 'Europe/Berlin'
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_days integer := least(greatest(coalesce(p_days, 30), 1), 366);
  v_now timestamptz := now();
  v_today date := (now() at time zone p_tz)::date;
  v_learning_today date := ((now() at time zone p_tz) - interval '4 hours')::date;
  v_from timestamptz;
  v_prev_from timestamptz;
  v_month_start timestamptz;
  v_learning_from date;
begin
  -- Zeitraum = die letzten v_days Kalendertage inkl. heute.
  v_from := (v_today - (v_days - 1))::timestamp at time zone p_tz;
  v_prev_from := (v_today - (2 * v_days - 1))::timestamp at time zone p_tz;
  v_month_start := date_trunc('month', v_today::timestamp) at time zone p_tz;
  v_learning_from := v_learning_today - (v_days - 1);

  return jsonb_build_object(
    'generated_at', v_now,
    'period', jsonb_build_object(
      'days', v_days,
      'tz', p_tz,
      'from', v_from,
      'from_day', v_today - (v_days - 1),
      'to_day', v_today,
      'learning_from_day', v_learning_from,
      'learning_today', v_learning_today,
      'month_start', v_month_start,
      'month_days_elapsed', extract(day from v_today)::int,
      'month_days_total', extract(day from date_trunc('month', v_today::timestamp) + interval '1 month' - interval '1 day')::int
    ),

    -- ---------------- Kosten ----------------
    'measuring_since', (select min(created_at) from api_usage_events),

    'spend_guard', (
      select jsonb_build_object('total_usd', total_cost_usd, 'updated_at', updated_at)
      from cloud_spend_tracker where provider = 'google_cloud'
    ),

    'usage_totals', coalesce((
      select jsonb_agg(t order by t.cost_usd desc)
      from (
        select function_name, operation, provider, price_class,
               count(*) as calls,
               count(*) filter (where status = 'ok') as ok,
               count(*) filter (where status = 'error') as errors,
               count(*) filter (where status = 'blocked') as blocked,
               coalesce(sum(characters), 0) as characters,
               coalesce(sum(input_tokens), 0) as input_tokens,
               coalesce(sum(cached_input_tokens), 0) as cached_input_tokens,
               coalesce(sum(output_tokens), 0) as output_tokens,
               coalesce(sum(estimated_cost_usd), 0) as cost_usd,
               round(avg(duration_ms) filter (where status = 'ok')) as avg_duration_ms
        from api_usage_events
        where created_at >= v_from
        group by function_name, operation, provider, price_class
      ) t
    ), '[]'::jsonb),

    'usage_daily', coalesce((
      select jsonb_agg(d order by d.day)
      from (
        select (created_at at time zone p_tz)::date as day,
               provider, price_class, operation,
               count(*) as calls,
               count(*) filter (where status <> 'ok') as failed,
               coalesce(sum(characters), 0) as characters,
               coalesce(sum(input_tokens), 0) as input_tokens,
               coalesce(sum(cached_input_tokens), 0) as cached_input_tokens,
               coalesce(sum(output_tokens), 0) as output_tokens,
               coalesce(sum(estimated_cost_usd), 0) as cost_usd
        from api_usage_events
        where created_at >= v_from
        group by 1, provider, price_class, operation
      ) d
    ), '[]'::jsonb),

    'previous_period', coalesce((
      select jsonb_object_agg(provider, cost_usd)
      from (
        select provider, coalesce(sum(estimated_cost_usd), 0) as cost_usd
        from api_usage_events
        where created_at >= v_prev_from and created_at < v_from
        group by provider
      ) p
    ), '{}'::jsonb),

    'month_to_date', coalesce((
      select jsonb_agg(m)
      from (
        select provider, price_class,
               coalesce(sum(characters), 0) as characters,
               coalesce(sum(input_tokens + output_tokens), 0) as tokens,
               coalesce(sum(estimated_cost_usd), 0) as cost_usd
        from api_usage_events
        where created_at >= v_month_start and status = 'ok'
        group by provider, price_class
      ) m
    ), '[]'::jsonb),

    -- ---------------- Betrieb / Missbrauch ----------------
    'callers', (
      select jsonb_build_object(
        'guest_calls', count(*) filter (where is_guest),
        'user_calls', count(*) filter (where not is_guest),
        'distinct_users', count(distinct user_id)
      )
      from api_usage_events where created_at >= v_from
    ),

    -- Achtung: grade-answer, generate-questions und text-to-speech teilen
    -- sich pro Identität denselben Zähler (gleicher Schlüssel in
    -- rate_limit_counters) -- die Zahl ist die Summe aller drei.
    'rate_limits_24h', coalesce((
      select jsonb_agg(r order by r.requests desc)
      from (
        select identity,
               sum(request_count)::int as requests,
               max(request_count)::int as peak_hour,
               count(*)::int as active_hours
        from rate_limit_counters
        where window_start > v_now - interval '24 hours'
        group by identity
        order by requests desc
        limit 20
      ) r
    ), '[]'::jsonb),

    -- ---------------- Lernen (review_logs) ----------------
    'learning_daily', coalesce((
      select jsonb_agg(l order by l.day)
      from (
        select ((reviewed_at at time zone p_tz) - interval '4 hours')::date as day,
               count(*) as reviews,
               count(*) filter (where mode = 'sprechen') as sprechen,
               count(*) filter (where mode = 'tippen') as tippen,
               count(*) filter (where rating = 1) as r1,
               count(*) filter (where rating = 2) as r2,
               count(*) filter (where rating = 3) as r3,
               count(*) filter (where rating = 4) as r4,
               count(distinct flashcard_id) as cards,
               round(avg(deckung_prozent) filter (where mode = 'sprechen')::numeric, 1) as avg_deckung
        from review_logs
        where ((reviewed_at at time zone p_tz) - interval '4 hours')::date >= v_learning_from
        group by 1
      ) l
    ), '[]'::jsonb),

    'learning_summary', (
      select jsonb_build_object(
        'reviews', count(*),
        'sprechen', count(*) filter (where mode = 'sprechen'),
        'tippen', count(*) filter (where mode = 'tippen'),
        'cards', count(distinct flashcard_id),
        'avg_deckung', round(avg(deckung_prozent) filter (where mode = 'sprechen')::numeric, 1)
      )
      from review_logs
      where ((reviewed_at at time zone p_tz) - interval '4 hours')::date >= v_learning_from
    ),

    'ratings_by_mode', coalesce((
      select jsonb_agg(x)
      from (
        select mode, rating, count(*) as n
        from review_logs
        where ((reviewed_at at time zone p_tz) - interval '4 hours')::date >= v_learning_from
        group by mode, rating
      ) x
    ), '[]'::jsonb),

    -- Wochentag (1 = Montag) x Stunde, nach Ortszeit.
    'heatmap', coalesce((
      select jsonb_agg(h)
      from (
        select extract(isodow from reviewed_at at time zone p_tz)::int as dow,
               extract(hour from reviewed_at at time zone p_tz)::int as hour,
               count(*) as n
        from review_logs
        where ((reviewed_at at time zone p_tz) - interval '4 hours')::date >= v_learning_from
        group by 1, 2
      ) h
    ), '[]'::jsonb),

    -- Alle Lerntage des letzten Jahres, für die Serie (unabhängig vom Zeitraum).
    'review_days_365', coalesce((
      select jsonb_agg(day order by day)
      from (
        select distinct ((reviewed_at at time zone p_tz) - interval '4 hours')::date as day
        from review_logs
        where reviewed_at >= v_now - interval '370 days'
      ) s
    ), '[]'::jsonb),

    'active_learners', (
      select count(distinct user_id)
      from review_logs
      where ((reviewed_at at time zone p_tz) - interval '4 hours')::date >= v_learning_from
    ),

    -- ---------------- Bibliothek ----------------
    'library', (
      select jsonb_build_object(
        'folders', (select count(*) from folders),
        'subfolders', (select count(*) from subfolders),
        'cards', count(*),
        'learned', count(*) filter (where fsrs_stability is not null),
        'new', count(*) filter (where fsrs_stability is null),
        'due_now', count(*) filter (where fsrs_stability is not null and srs_due_at <= v_now),
        'due_7d', count(*) filter (where fsrs_stability is not null and srs_due_at <= v_now + interval '7 days'),
        -- case statt "and": SQL garantiert keine Kurzschluss-Auswertung,
        -- und jsonb_array_length wirft bei Nicht-Arrays.
        'with_kontrollpunkte', count(*) filter (
          where case when jsonb_typeof(kernelemente) = 'array' then jsonb_array_length(kernelemente) else 0 end > 0
        )
      )
      from flashcards
    ),

    'cards_created_daily', coalesce((
      select jsonb_agg(c order by c.day)
      from (
        select (created_at at time zone p_tz)::date as day, count(*) as n
        from flashcards
        where created_at >= v_from
        group by 1
      ) c
    ), '[]'::jsonb),

    -- ---------------- Nutzer ----------------
    'users', (
      select jsonb_build_object(
        'total', count(*),
        'new_in_period', count(*) filter (where created_at >= v_from)
      )
      from auth.users
    )
  );
end;
$$;

-- Postgres gibt EXECUTE standardmäßig an PUBLIC, Supabase zusätzlich an
-- anon/authenticated -- alles entziehen, nur service_role darf.
revoke all on function public.admin_dashboard(integer, text) from public, anon, authenticated;
grant execute on function public.admin_dashboard(integer, text) to service_role;
