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

/// `true` = Anfrage erlaubt, `false` = Limit für dieses Stunden-Fenster
/// erreicht. Bei technischen Problemen (z.B. Secret fehlt, DB nicht
/// erreichbar) wird bewusst "fail open" entschieden – ein Konfigurations-
/// fehler soll nicht sofort die ganze App für alle legitimen User lahmlegen,
/// nur weil der Abuse-Schutz selbst kurz klemmt.
export async function checkRateLimit(identity: string, maxRequestsPerHour: number): Promise<boolean> {
  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!supabaseUrl || !serviceRoleKey) {
    console.error("Rate-Limiting nicht konfiguriert (SUPABASE_URL/SERVICE_ROLE_KEY fehlt) – lasse Anfrage durch.");
    return true;
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
      return true;
    }

    return (await response.json()) as boolean;
  } catch (err) {
    console.error("Rate-Limit-Check-Fehler:", err);
    return true;
  }
}
