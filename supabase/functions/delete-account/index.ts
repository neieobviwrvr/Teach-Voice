// supabase/functions/delete-account/index.ts
//
// Löscht den EIGENEN Account des aufrufenden Users unwiderruflich, inklusive
// aller seiner Ordner/Unterordner/Karteikarten. Braucht dafür die GoTrue
// Admin-API (`DELETE /auth/v1/admin/users/{id}`), die nur mit dem
// `service_role`-Key funktioniert -- deshalb zwingend eine Edge Function
// (der Client besitzt/darf diesen Key nie besitzen, siehe rateLimit.ts).
//
// Sicherheitskritisch (im Unterschied zu rateLimit.ts's `resolveIdentity`,
// die das JWT nur DEKODIERT, ohne Signatur zu prüfen -- dort reicht das,
// weil im schlimmsten Fall nur ein falscher Rate-Limit-Bucket getroffen
// wird): hier MUSS das Token echt verifiziert werden, sonst könnte jemand
// mit einem manipulierten Token behaupten, ein anderer User zu sein, und
// dessen Account löschen. Verifikation läuft über GoTrue selbst
// (`GET /auth/v1/user` mit dem Caller-Token) -- liefert die echte User-ID nur
// zurück, wenn das Token tatsächlich gültig ist.
//
// Cascade: `folders.user_id references auth.users(id) on delete cascade`
// (siehe supabase/migrations/0001_init.sql) -- ein einziges Admin-Delete des
// auth.users-Eintrags räumt dadurch automatisch auch alle Ordner, Unterordner
// und Karteikarten des Users mit ab, kein manuelles Aufräumen nötig.

const CORS_HEADERS: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: CORS_HEADERS });
  }
  if (req.method !== "POST") {
    return jsonResponse({ error: "Nur POST erlaubt." }, 405);
  }

  try {
    const authHeader = req.headers.get("authorization");
    if (!authHeader?.startsWith("Bearer ")) {
      return jsonResponse({ error: "Kein gültiger Token." }, 401);
    }
    const callerToken = authHeader.slice("Bearer ".length).trim();

    const supabaseUrl = Deno.env.get("SUPABASE_URL");
    const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
    const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
    if (!supabaseUrl || !anonKey || !serviceRoleKey) {
      console.error("delete-account: SUPABASE_URL/ANON_KEY/SERVICE_ROLE_KEY fehlt.");
      return jsonResponse({ error: "Server-Konfiguration unvollständig." }, 500);
    }

    // Token-Echtheit + eigene User-ID über GoTrue selbst verifizieren --
    // NICHT einfach das `sub`-Claim ungeprüft aus dem JWT lesen (siehe
    // Datei-Kopf-Kommentar).
    const whoami = await fetch(`${supabaseUrl}/auth/v1/user`, {
      headers: { apikey: anonKey, Authorization: `Bearer ${callerToken}` },
    });
    if (!whoami.ok) {
      return jsonResponse({ error: "Sitzung ungültig oder abgelaufen. Bitte neu anmelden und erneut versuchen." }, 401);
    }
    const whoamiBody = await whoami.json();
    const userId = whoamiBody?.id as string | undefined;
    if (!userId) {
      return jsonResponse({ error: "Konnte den Account nicht ermitteln." }, 400);
    }

    const deleteResp = await fetch(`${supabaseUrl}/auth/v1/admin/users/${userId}`, {
      method: "DELETE",
      headers: { apikey: serviceRoleKey, Authorization: `Bearer ${serviceRoleKey}` },
    });
    if (!deleteResp.ok) {
      const text = await deleteResp.text();
      console.error("delete-account: Admin-Delete fehlgeschlagen", deleteResp.status, text);
      return jsonResponse({ error: "Account konnte nicht gelöscht werden." }, 500);
    }

    return jsonResponse({ deleted: true }, 200);
  } catch (err) {
    console.error(err);
    const message = err instanceof Error ? err.message : "Unbekannter Fehler";
    return jsonResponse({ error: `Unerwarteter Fehler beim Löschen: ${message}` }, 500);
  }
});

function jsonResponse(body: unknown, status: number): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS_HEADERS, "Content-Type": "application/json" },
  });
}
