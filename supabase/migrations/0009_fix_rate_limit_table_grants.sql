-- ============================================================
-- SICHERHEITSFIX: rate_limit_counters war öffentlich lesbar UND schreibbar.
--
-- Beim Anlegen der Tabelle in 0008 wurde RLS bewusst nicht aktiviert (die
-- Tabelle sollte nur vom service_role-Key der Edge Functions angesprochen
-- werden). Übersehen wurde dabei: Supabase vergibt an neu angelegte Tabellen
-- standardmäßig volle Grants (SELECT/INSERT/UPDATE/DELETE/TRUNCATE/...) an
-- die Rollen `anon` und `authenticated` – OHNE aktives RLS bedeutet das:
-- JEDER mit dem öffentlichen anon-Key konnte über die normale REST-API
-- (`/rest/v1/rate_limit_counters`) alle Zähler lesen UND beliebig
-- zurücksetzen/löschen. Damit ließ sich das gesamte Rate-Limiting aus 0008
-- trivial umgehen (eigenen Zähler vor jedem Missbrauchs-Versuch löschen).
--
-- Live verifiziert: vor diesem Fix lieferte ein GET mit dem anon-Key echte
-- Daten (200), danach "permission denied" (401) – während der Zugriff der
-- Edge Functions über service_role (bypasst Grants/RLS ohnehin) unverändert
-- funktioniert.
-- ============================================================

revoke all on public.rate_limit_counters from anon, authenticated, public;
