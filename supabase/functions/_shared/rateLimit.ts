// supabase/functions/_shared/rateLimit.ts
//
// Gemeinsame Rate-Limiting-Logik für grade-answer und generate-questions.
// Identität: bevorzugt die User-ID aus einem echten JWT (eingeloggt), sonst
// Fallback auf die Client-IP (Gastmodus – alle Gäste teilen sich denselben
// öffentlichen anon-Key, daher keine feinere Unterscheidung möglich).
//
// Nutzt den service_role-Key (automatisch von Supabase als Secret
// bereitgestellt, kein manuelles Setup nötig), um die reine Zähler-Tabelle
// unabhängig von RLS zu lesen/schreiben – die Tabelle enthält keine
// Nutzdaten, nur Zählwerte pro Identität/Stunde.

export async function resolveIdentity(req: Request): Promise<string> {
  const authHeader = req.headers.get("authorization");
  const userId = extractUserId(authHeader);
  if (userId) return `user:${userId}`;

  const forwardedFor = req.headers.get("x-forwarded-for");
  const ip = forwardedFor?.split(",")[0]?.trim() || req.headers.get("x-real-ip") || "unknown";
  return `ip:${ip}`;
}

/// Liest NUR das `sub`-Claim aus dem JWT-Payload, ohne Signaturprüfung –
/// für die reine Bucket-Zuordnung beim Rate-Limiting ausreichend (im
/// schlimmsten Fall landet jemand in einem falschen Bucket, das umgeht aber
/// keine andere Sicherheitsgrenze). Der anon-Key selbst hat kein `sub`-Feld
/// und fällt dadurch automatisch auf die IP-basierte Identität zurück.
function extractUserId(authHeader: string | null): string | null {
  if (!authHeader?.startsWith("Bearer ")) return null;
  const token = authHeader.slice("Bearer ".length).trim();
  const parts = token.split(".");
  if (parts.length !== 3) return null;
  try {
    const base64 = parts[1].replace(/-/g, "+").replace(/_/g, "/");
    const payload = JSON.parse(atob(base64));
    return typeof payload.sub === "string" ? payload.sub : null;
  } catch {
    return null;
  }
}

/// "ok" = Anfrage erlaubt. "rate_limited" = echtes Limit erreicht (429).
/// "unavailable" = die Prüfung selbst ist technisch fehlgeschlagen (Secret
/// fehlt, DB nicht erreichbar, unerwarteter Fehler) – FAIL CLOSED (Simons
/// ausdrücklicher Wunsch): läuft die Schutzmaßnahme selbst kaputt, soll das
/// NICHT automatisch "unbegrenzt GPT-Calls" bedeuten, sondern die Anfrage
/// wird abgelehnt, bis die Prüfung wieder funktioniert. Getrennt von
/// "rate_limited" gehalten, damit ein technischer Fehler nicht fälschlich
/// als "du hast zu viel angefragt" beim User ankommt.
export type RateLimitOutcome = "ok" | "rate_limited" | "unavailable";

const GLOBAL_GUEST_IDENTITY = "global:all-guests";

/// Prüft das Pro-Identität-Limit UND – nur für anonyme (IP-basierte)
/// Anfragen – zusätzlich einen GLOBALEN Deckel über ALLE Gäste zusammen.
/// Grund: ein reiner Pro-IP-Zähler lässt sich durch IP-Wechsel (VPN, Mobilfunk-
/// Wechsel) umgehen – ein client-mitgeschicktes "Geräte-ID"-Merkmal würde das
/// NICHT lösen, da ein Angreifer eine solche ID genauso frei erfinden/rotieren
/// könnte. Der globale Deckel ist dagegen serverseitig unabhängig von jedem
/// Client-Signal und fängt verteilten Missbrauch über viele IPs auf, auch
/// wenn er einzelne, tatsächlich verschiedene legitime Gäste nicht mehr
/// unterscheiden kann – bewusster Kompromiss für anonymen Zugriff ohne Login.
export async function checkRateLimit(
  identity: string,
  maxRequestsPerHour: number,
  globalGuestMaxRequestsPerHour?: number
): Promise<RateLimitOutcome> {
  const perIdentity = await checkSingleLimit(identity, maxRequestsPerHour);
  if (perIdentity !== "ok") return perIdentity;

  if (identity.startsWith("ip:") && globalGuestMaxRequestsPerHour) {
    return checkSingleLimit(GLOBAL_GUEST_IDENTITY, globalGuestMaxRequestsPerHour);
  }

  return "ok";
}

async function checkSingleLimit(identity: string, maxRequestsPerHour: number): Promise<RateLimitOutcome> {
  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!supabaseUrl || !serviceRoleKey) {
    console.error("Rate-Limiting nicht konfiguriert (SUPABASE_URL/SERVICE_ROLE_KEY fehlt) – lehne Anfrage ab (fail closed).");
    return "unavailable";
  }

  try {
    const response = await fetch(`${supabaseUrl}/rest/v1/rpc/check_and_increment_rate_limit`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        apikey: serviceRoleKey,
        Authorization: `Bearer ${serviceRoleKey}`,
      },
      body: JSON.stringify({ p_identity: identity, p_max_requests: maxRequestsPerHour }),
    });

    if (!response.ok) {
      console.error("Rate-Limit-Check fehlgeschlagen:", response.status, await response.text());
      return "unavailable";
    }

    const allowed = (await response.json()) as boolean;
    return allowed ? "ok" : "rate_limited";
  } catch (err) {
    console.error("Rate-Limit-Check-Fehler:", err);
    return "unavailable";
  }
}
