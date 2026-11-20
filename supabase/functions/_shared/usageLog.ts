// supabase/functions/_shared/usageLog.ts
//
// Schreibt eine Zeile pro bezahltem API-Aufruf in api_usage_events
// (supabase/migrations/0016_api_usage.sql) -- die Datenquelle für die
// Kosten im internen Dashboard (dashboard/, Edge Function admin-dashboard).
//
// Zwei Regeln, die das hier tragen:
//   1. Das Protokollieren darf den eigentlichen Aufruf NIE blockieren,
//      verlangsamen oder scheitern lassen. Deshalb wird nicht gewartet: der
//      Insert läuft per EdgeRuntime.waitUntil im Hintergrund weiter, nachdem
//      die Antwort schon raus ist; Fehler landen nur im Function-Log.
//   2. Keine Inhalte und keine IP-Adressen: nur Mengen, Preisklasse, Status
//      und die User-ID (aus dem vom Gateway geprüften JWT, siehe
//      rateLimit.ts/resolveIdentity). Gäste werden nur als is_guest markiert.

import { serviceRest } from "./serviceRest.ts";

// Von der Supabase Edge Runtime bereitgestellt (Background Tasks); fehlt
// z.B. in lokalen Tests -- dann läuft das Promise einfach ohne waitUntil.
declare const EdgeRuntime: { waitUntil(promise: Promise<unknown>): void } | undefined;

export type UsageStatus = "ok" | "error" | "blocked";

export interface ApiUsageEvent {
  functionName: "text-to-speech" | "grade-answer" | "generate-questions";
  operation: "tts" | "grading" | "extraction" | "question_generation";
  provider: "google_tts" | "openai";
  /// Stimme bzw. Modell.
  model: string;
  priceClass: string;
  status: UsageStatus;
  httpStatus?: number | null;
  characters?: number;
  inputTokens?: number;
  cachedInputTokens?: number;
  outputTokens?: number;
  estimatedCostUsd?: number;
  /// Ergebnis von resolveIdentity(): "user:<uuid>" oder "ip:<adresse>".
  identity: string;
  durationMs?: number;
}

const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export function logApiUsage(event: ApiUsageEvent): void {
  const userIdCandidate = event.identity.startsWith("user:") ? event.identity.slice("user:".length) : null;
  const userId = userIdCandidate && UUID_PATTERN.test(userIdCandidate) ? userIdCandidate : null;

  const row = {
    function_name: event.functionName,
    operation: event.operation,
    provider: event.provider,
    model: event.model,
    price_class: event.priceClass,
    status: event.status,
    http_status: event.httpStatus ?? null,
    characters: Math.max(0, Math.round(event.characters ?? 0)),
    input_tokens: Math.max(0, Math.round(event.inputTokens ?? 0)),
    cached_input_tokens: Math.max(0, Math.round(event.cachedInputTokens ?? 0)),
    output_tokens: Math.max(0, Math.round(event.outputTokens ?? 0)),
    estimated_cost_usd: Math.max(0, event.estimatedCostUsd ?? 0),
    user_id: userId,
    is_guest: userId === null,
    duration_ms: event.durationMs !== undefined ? Math.max(0, Math.round(event.durationMs)) : null,
  };

  const task = serviceRest("api_usage_events", { method: "POST", body: row, prefer: "return=minimal" })
    .catch((err) => console.error("Kostenprotokoll (api_usage_events) fehlgeschlagen:", err));

  try {
    if (typeof EdgeRuntime !== "undefined" && EdgeRuntime?.waitUntil) {
      EdgeRuntime.waitUntil(task);
    }
  } catch (err) {
    console.error("EdgeRuntime.waitUntil fehlgeschlagen:", err);
  }
}
