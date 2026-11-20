// supabase/functions/_shared/apiPricing.ts
//
// Listenpreise der bezahlten APIs an EINER Stelle: text-to-speech nutzt sie
// für den Kostendeckel (cloudSpendGuard.ts), usageLog.ts für die geschätzten
// Kosten in api_usage_events, admin-dashboard zeigt sie im Dashboard an.
//
// Stand 2026-11-19, laut den offiziellen Preisseiten:
//   - Google Cloud TTS: WaveNet $4, Chirp 3: HD $30 pro 1 Mio. Zeichen.
//     Das monatliche Freikontingent ist hier BEWUSST nicht eingerechnet
//     (lieber zu hoch schätzen, gleiches Prinzip wie der Kostendeckel).
//   - OpenAI gpt-4o-mini: $0.15 Input, $0.075 gecachter Input, $0.60 Output
//     pro 1 Mio. Token.
// Ändert ein Anbieter seine Preise, hier anpassen. Alte Zeilen in
// api_usage_events behalten den damals geschätzten Betrag.

export type TtsPriceClass = "wavenet" | "chirp3_hd";

export const TTS_PRICE_PER_MILLION_CHARS_USD: Record<TtsPriceClass, number> = {
  wavenet: 4,
  chirp3_hd: 30,
};

export interface TokenPrices {
  input: number;
  cachedInput: number;
  output: number;
}

export const OPENAI_PRICE_PER_MILLION_TOKENS_USD: Record<string, TokenPrices> = {
  "gpt-4o-mini": { input: 0.15, cachedInput: 0.075, output: 0.6 },
};

export interface OpenAIUsage {
  inputTokens: number;
  cachedInputTokens: number;
  outputTokens: number;
}

/// Liest das `usage`-Objekt einer Chat-Completions-Antwort. `prompt_tokens`
/// enthält die gecachten Token bereits mit.
export function parseOpenAIUsage(json: unknown): OpenAIUsage {
  const usage = (json as { usage?: Record<string, unknown> } | null)?.usage ?? {};
  const details = (usage.prompt_tokens_details ?? {}) as Record<string, unknown>;
  const toCount = (value: unknown) => (typeof value === "number" && Number.isFinite(value) && value > 0 ? Math.round(value) : 0);
  const inputTokens = toCount(usage.prompt_tokens);
  return {
    inputTokens,
    cachedInputTokens: Math.min(toCount(details.cached_tokens), inputTokens),
    outputTokens: toCount(usage.completion_tokens),
  };
}

/// Geschätzte Kosten eines OpenAI-Aufrufs. Unbekanntes Modell -> 0 (die Token
/// stehen trotzdem in api_usage_events und lassen sich nachrechnen).
export function openAICostUsd(model: string, usage: OpenAIUsage): number {
  const prices = Object.hasOwn(OPENAI_PRICE_PER_MILLION_TOKENS_USD, model) ? OPENAI_PRICE_PER_MILLION_TOKENS_USD[model] : undefined;
  if (!prices) return 0;
  const uncachedInput = usage.inputTokens - usage.cachedInputTokens;
  return (uncachedInput * prices.input + usage.cachedInputTokens * prices.cachedInput + usage.outputTokens * prices.output) / 1_000_000;
}
