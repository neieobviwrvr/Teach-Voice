// supabase/functions/_shared/serviceRest.ts
//
// Schlanker PostgREST-Zugriff mit dem service_role-Key (automatisch von
// Supabase als Secret bereitgestellt), gleiches Prinzip wie in rateLimit.ts.
//
// ACHTUNG: service_role umgeht Row Level Security. Wer diese Funktion für
// Nutzerdaten (folders/subfolders/flashcards) verwendet, MUSS jede Abfrage
// selbst explizit auf `user_id=eq.<id>` filtern und bei Inserts `user_id`
// selbst setzen -- siehe teach-mcp/index.ts.

export class ServiceRestError extends Error {
  constructor(public readonly status: number, public readonly body: string) {
    super(`PostgREST-Fehler (${status}): ${body}`);
  }
}

interface ServiceRestOptions {
  method?: "GET" | "POST" | "PATCH" | "DELETE";
  body?: unknown;
  /// Wert für den `Prefer`-Header, z.B. "return=representation".
  prefer?: string;
}

/// `path` ist alles nach `/rest/v1/`, inklusive Query-String. Werte, die in
/// den Query-String eingesetzt werden, müssen vorher validiert sein (UUIDs
/// per Zod, Hashes als Hex) -- hier wird bewusst nichts escaped.
export async function serviceRest<T>(path: string, options: ServiceRestOptions = {}): Promise<T> {
  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!supabaseUrl || !serviceRoleKey) {
    throw new Error("SUPABASE_URL/SUPABASE_SERVICE_ROLE_KEY fehlt.");
  }

  const headers: Record<string, string> = {
    apikey: serviceRoleKey,
    Authorization: `Bearer ${serviceRoleKey}`,
  };
  if (options.body !== undefined) headers["Content-Type"] = "application/json";
  if (options.prefer) headers["Prefer"] = options.prefer;

  const response = await fetch(`${supabaseUrl}/rest/v1/${path}`, {
    method: options.method ?? "GET",
    headers,
    body: options.body !== undefined ? JSON.stringify(options.body) : undefined,
  });

  const text = await response.text();
  if (!response.ok) {
    throw new ServiceRestError(response.status, text);
  }
  return (text ? JSON.parse(text) : null) as T;
}
