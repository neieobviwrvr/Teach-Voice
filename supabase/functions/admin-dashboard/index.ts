// supabase/functions/admin-dashboard/index.ts
//
// Datenquelle des internen Kosten- und Analytics-Dashboards (dashboard/
// im Repo, eine statische Seite, unabhängig von der iOS-App).
//
// Sicherheitsmodell (Simons Vorgabe: nur er darf es sehen, NIE ein
// service_role- oder API-Key im Browser):
//   1. Das Dashboard meldet sich mit einem normalen Teach-Konto an
//      (GoTrue, öffentlicher anon-Key) und schickt dessen Access-Token.
//   2. verify_jwt bleibt an (Standard, siehe config.toml): das Gateway lässt
//      nur gültige Supabase-JWTs durch.
//   3. Hier wird das Token zusätzlich über GoTrue selbst verifiziert
//      (`GET /auth/v1/user`, wie delete-account) und die echte User-ID gegen
//      das Secret ADMIN_USER_IDS (kommagetrennte UUIDs) geprüft. Fehlt das
//      Secret oder passt die ID nicht -> 403. Fail closed.
//   4. Erst danach liest die Function mit service_role (nur hier auf dem
//      Server) über die SQL-Funktion admin_dashboard()
//      (0016_api_usage.sql), die ausschließlich service_role ausführen darf.
//
// Nur lesend. Gibt nur Aggregate zurück -- keine Karteninhalte. Die
// Identitäten aus rate_limit_counters (User-IDs, Gast-IPs der letzten 24 h)
// sind fürs Missbrauchs-Monitoring bewusst enthalten.

import { serviceRest, ServiceRestError } from "../_shared/serviceRest.ts";
import { CEILING_USD as GOOGLE_CLOUD_CEILING_USD } from "../_shared/cloudSpendGuard.ts";
import { OPENAI_PRICE_PER_MILLION_TOKENS_USD, TTS_PRICE_PER_MILLION_CHARS_USD } from "../_shared/apiPricing.ts";

const TIME_ZONE = "Europe/Berlin";
const DEFAULT_DAYS = 30;
const MAX_DAYS = 366;

// Muss zu den RATE_LIMIT_MAX_PER_HOUR-Konstanten der Functions passen --
// nur zur Einordnung im Dashboard.
const RATE_LIMITS_PER_HOUR = {
  "grade-answer": 150,
  "generate-questions": 40,
  "text-to-speech": 300,
  "teach-mcp": 200,
};

const CORS_HEADERS: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "GET, OPTIONS",
};

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: CORS_HEADERS });
  }
  if (req.method !== "GET") {
    return jsonResponse({ error: "Nur GET erlaubt." }, 405);
  }

  try {
    const authHeader = req.headers.get("authorization");
    if (!authHeader?.startsWith("Bearer ")) {
      return jsonResponse({ error: "Nicht angemeldet." }, 401);
    }
    const callerToken = authHeader.slice("Bearer ".length).trim();

    const supabaseUrl = Deno.env.get("SUPABASE_URL");
    const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
    if (!supabaseUrl || !anonKey) {
      console.error("admin-dashboard: SUPABASE_URL/SUPABASE_ANON_KEY fehlt.");
      return jsonResponse({ error: "Server-Konfiguration unvollständig." }, 500);
    }

    // Token echt verifizieren -- NICHT nur das sub-Claim dekodieren.
    const whoami = await fetch(`${supabaseUrl}/auth/v1/user`, {
      headers: { apikey: anonKey, Authorization: `Bearer ${callerToken}` },
    });
    if (!whoami.ok) {
      return jsonResponse({ error: "Sitzung ungültig oder abgelaufen. Bitte neu anmelden." }, 401);
    }
    const userId = ((await whoami.json())?.id as string | undefined)?.toLowerCase();

    const adminIds = (Deno.env.get("ADMIN_USER_IDS") ?? "")
      .split(",")
      .map((id) => id.trim().toLowerCase())
      .filter((id) => id.length > 0);
    if (!userId || !adminIds.includes(userId)) {
      return jsonResponse({ error: "Dieses Konto hat keinen Zugang zum Dashboard." }, 403);
    }

    const requestedDays = Number(new URL(req.url).searchParams.get("days") ?? DEFAULT_DAYS);
    const days = Number.isFinite(requestedDays) ? Math.min(Math.max(Math.round(requestedDays), 1), MAX_DAYS) : DEFAULT_DAYS;

    let data: unknown;
    try {
      data = await serviceRest<unknown>("rpc/admin_dashboard", {
        method: "POST",
        body: { p_days: days, p_tz: TIME_ZONE },
      });
    } catch (err) {
      // 404 = SQL-Funktion fehlt -> Migration 0016 noch nicht angewendet.
      if (err instanceof ServiceRestError && err.status === 404) {
        return jsonResponse({ error: "Migration 0016_api_usage.sql ist noch nicht angewendet." }, 503);
      }
      throw err;
    }

    return jsonResponse({
      data,
      config: {
        time_zone: TIME_ZONE,
        google_cloud_ceiling_usd: GOOGLE_CLOUD_CEILING_USD,
        tts_price_per_million_chars_usd: TTS_PRICE_PER_MILLION_CHARS_USD,
        openai_price_per_million_tokens_usd: OPENAI_PRICE_PER_MILLION_TOKENS_USD,
        rate_limits_per_hour: RATE_LIMITS_PER_HOUR,
      },
    }, 200);
  } catch (err) {
    console.error("admin-dashboard:", err);
    return jsonResponse({ error: "Unerwarteter Fehler beim Laden der Dashboard-Daten." }, 500);
  }
});

function jsonResponse(body: unknown, status: number): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS_HEADERS, "Content-Type": "application/json", "Cache-Control": "no-store" },
  });
}
