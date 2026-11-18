-- ============================================================
-- Persönliche Schlüssel für den Claude-Konnektor (Edge Function `teach-mcp`).
--
-- Simon erzeugt in der App (Profil -> KI-Konnektor) einen Schlüssel und
-- trägt ihn in Claude als Request-Header ein. `teach-mcp` sucht den Hash
-- hier nach und weiß dadurch, in wessen Bibliothek Claude schreiben darf.
--
-- Gespeichert wird NUR der SHA-256-Hash, nie der Klartext-Schlüssel. Der
-- Klartext wird beim Erzeugen genau einmal an die App zurückgegeben (Edge
-- Function `connector-key`) und ist danach nicht mehr rekonstruierbar.
--
-- Zugriff ausschließlich über den service_role-Key der Edge Functions.
-- Lehre aus 0009_fix_rate_limit_table_grants.sql: Supabase vergibt an neue
-- Tabellen standardmäßig volle Grants an anon/authenticated. Deshalb hier
-- doppelt abgesichert: RLS an (ohne Policies = niemand außer service_role
-- sieht etwas) UND alle Grants entzogen.
-- ============================================================

create table if not exists public.connector_keys (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  key_hash text not null unique,
  key_prefix text not null,
  created_at timestamptz not null default now(),
  last_used_at timestamptz,
  revoked_at timestamptz
);

-- Höchstens EIN aktiver Schlüssel pro Nutzer. Ein neuer Schlüssel sperrt den
-- alten (siehe connector-key), gesperrte Einträge bleiben zur Nachvollzieh-
-- barkeit stehen.
create unique index if not exists idx_connector_keys_one_active_per_user
  on public.connector_keys(user_id)
  where revoked_at is null;

alter table public.connector_keys enable row level security;

revoke all on public.connector_keys from anon, authenticated, public;
