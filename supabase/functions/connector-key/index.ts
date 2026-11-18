// supabase/functions/connector-key/index.ts
//
// Verwaltet den persönlichen Schlüssel für den Claude-Konnektor (`teach-mcp`)
// des aufrufenden Users. Aufgerufen aus der App (Profil -> KI-Konnektor).
//
//   GET    -> Status: gibt es einen aktiven Schlüssel? (nur Präfix + Daten)
//   POST   -> neuen Schlüssel erzeugen. Sperrt einen alten aktiven Schlüssel.
//             Der Klartext-Schlüssel steht NUR in dieser einen Antwort.
//   DELETE -> aktiven Schlüssel sperren.
//
// Alle drei Antworten haben dieselbe Form (`StatusResponse`), damit die App
// nur ein einziges Antwort-Modell braucht.
//
// Sicherheit: wie delete-account wird das Caller-Token ECHT über GoTrue
// verifiziert (`GET /auth/v1/user`), nicht nur dekodiert -- sonst könnte
// jemand mit einem gefälschten Token einen Schlüssel für fremde Daten
// erzeugen. Die Tabelle selbst ist für anon/authenticated komplett gesperrt
// (siehe 0012_connector_keys.sql), Zugriff nur über service_role.

import { displayPrefix, generateConnectorKey, hashConnectorKey } from "../_shared/connectorKey.ts";
import { ServiceRestError, serviceRest } from "../_shared/serviceRest.ts";

const CORS_HEADERS: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "GET, POST, DELETE, OPTIONS",
};

interface KeyRow {
  key_prefix: string;
  created_at: string;
  last_used_at: string | null;
}

interface StatusResponse {
  active: boolean;
  key_prefix: string | null;
  created_at: string | null;
  last_used_at: string | null;
  connector_url: string;
  /// Nur direkt nach POST gesetzt, sonst immer null.
  key: string | null;
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: CORS_HEADERS });
  }
  if (req.method !== "GET" && req.method !== "POST" && req.method !== "DELETE") {
    return jsonResponse({ error: "Nur GET, POST oder DELETE erlaubt." }, 405);
  }

  try {
    const supabaseUrl = Deno.env.get("SUPABASE_URL");
    if (!supabaseUrl) {
      console.error("connector-key: SUPABASE_URL fehlt.");
      return jsonResponse({ error: "Server-Konfiguration unvollständig." }, 500);
    }
    const connectorUrl = `${supabaseUrl}/functions/v1/teach-mcp`;

    const userId = await verifyCaller(req, supabaseUrl);
    if (!userId) {
      return jsonResponse({ error: "Sitzung ungültig oder abgelaufen. Bitte neu anmelden und erneut versuchen." }, 401);
    }

    if (req.method === "GET") {
      const rows = await serviceRest<KeyRow[]>(
        `connector_keys?user_id=eq.${userId}&revoked_at=is.null&select=key_prefix,created_at,last_used_at`
      );
      return jsonResponse(statusFrom(rows[0] ?? null, connectorUrl, null), 200);
    }

    if (req.method === "DELETE") {
      await revokeActiveKey(userId);
      return jsonResponse(statusFrom(null, connectorUrl, null), 200);
    }

    // POST: alten Schlüssel sperren, neuen erzeugen.
    await revokeActiveKey(userId);
    const key = generateConnectorKey();
    const inserted = await serviceRest<KeyRow[]>("connector_keys?select=key_prefix,created_at,last_used_at", {
      method: "POST",
      body: { user_id: userId, key_hash: await hashConnectorKey(key), key_prefix: displayPrefix(key) },
      prefer: "return=representation",
    });
    return jsonResponse(statusFrom(inserted[0] ?? null, connectorUrl, key), 201);
  } catch (err) {
    // 409 = der Unique-Index "ein aktiver Schlüssel pro Nutzer" hat
    // gegriffen, d.h. zwei POSTs liefen gleichzeitig.
    if (err instanceof ServiceRestError && err.status === 409) {
      return jsonResponse({ error: "Es wurde gerade gleichzeitig ein Schlüssel erzeugt. Bitte erneut versuchen." }, 409);
    }
    console.error("connector-key:", err);
    return jsonResponse({ error: "Konnektor-Schlüssel konnte nicht verarbeitet werden." }, 500);
  }
});

/// Gleiche Prüfung wie in delete-account: liefert die echte User-ID nur, wenn
/// GoTrue das Token als gültig bestätigt.
async function verifyCaller(req: Request, supabaseUrl: string): Promise<string | null> {
  const authHeader = req.headers.get("authorization");
  if (!authHeader?.startsWith("Bearer ")) return null;
  const callerToken = authHeader.slice("Bearer ".length).trim();

  const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
  if (!anonKey) throw new Error("SUPABASE_ANON_KEY fehlt.");

  const whoami = await fetch(`${supabaseUrl}/auth/v1/user`, {
    headers: { apikey: anonKey, Authorization: `Bearer ${callerToken}` },
  });
  if (!whoami.ok) return null;
  const body = await whoami.json();
  return typeof body?.id === "string" ? body.id : null;
}

async function revokeActiveKey(userId: string): Promise<void> {
  await serviceRest<null>(`connector_keys?user_id=eq.${userId}&revoked_at=is.null`, {
    method: "PATCH",
    body: { revoked_at: new Date().toISOString() },
    prefer: "return=minimal",
  });
}

function statusFrom(row: KeyRow | null, connectorUrl: string, key: string | null): StatusResponse {
  return {
    active: row !== null,
    key_prefix: row?.key_prefix ?? null,
    created_at: row?.created_at ?? null,
    last_used_at: row?.last_used_at ?? null,
    connector_url: connectorUrl,
    key,
  };
}

function jsonResponse(body: unknown, status: number): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS_HEADERS, "Content-Type": "application/json" },
  });
}
