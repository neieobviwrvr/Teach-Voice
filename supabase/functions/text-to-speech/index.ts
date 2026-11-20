// supabase/functions/text-to-speech/index.ts
//
// Wandelt Text in gesprochenes Audio um, über Google Cloud Text-to-Speech
// (WaveNet- oder Chirp-3-HD-Stimme aus einer festen Liste, mit wählbarem
// Sprechtempo, siehe ALLOWED_VOICES). Grund für den Wechsel weg von reinem on-device Apple-TTS:
// Simon hat empirisch bestätigt (siehe Chat-Historie), dass viele User real
// nur Apples Standard-Kompaktstimme zur Verfügung haben -- Enhanced/Premium-
// Stimmen erfordern manuellen Download in den Systemeinstellungen (oft
// hunderte MB), was im Prüfungsstress niemand macht, und Siri-Stimmen sind für
// Drittanbieter-Apps grundsätzlich gesperrt (0 von 181 vom System gemeldeten
// Stimmen bei Simons Test). Google Cloud TTS (WaveNet) hat dagegen ein
// production-taugliches Freikontingent (1 Mio. Zeichen/Monat, siehe
// Chat-Historie -- offiziell durch Googles "Always Free"-Bedingungen UND die
// "Training Restriction" in den Service Specific Terms belegt, nicht nur
// vermutet) und danach $4/1 Mio. Zeichen.
//
// Bewusst ZUSTANDSLOS wie grade-answer/generate-questions: kein DB-Zugriff,
// funktioniert identisch für Cloud- und Gastkarten. Caching passiert
// CLIENT-seitig (AudioFileCache.swift, Hash aus Text+Stimme) -- gleiches
// Lazy-Caching-Prinzip wie bei den Kernelementen: dieselbe Frage wird bei
// Spaced Repetition oft wiederholt vorgelesen, aber nur beim ersten Mal
// tatsächlich synthetisiert.
//
// WICHTIG: Der Google-Cloud-API-Key liegt ausschließlich hier als
// Supabase-Secret (GOOGLE_TTS_API_KEY), nie im Client-Code oder Repo.
//
// Missbrauchsschutz: Rate-Limiting + serverseitige Längen-Obergrenze, gleiches
// Prinzip wie in grade-answer/generate-questions -- der öffentliche anon-Key
// steckt in jeder IPA, ohne Gegenmaßnahmen könnte jemand diese Function
// beliebig oft aufrufen.

import { checkRateLimit, resolveIdentity } from "../_shared/rateLimit.ts";
import { checkAndReserveGoogleCloudSpend } from "../_shared/cloudSpendGuard.ts";
import { TTS_PRICE_PER_MILLION_CHARS_USD, type TtsPriceClass } from "../_shared/apiPricing.ts";
import { logApiUsage, type UsageStatus } from "../_shared/usageLog.ts";

const GOOGLE_TTS_URL = "https://texttospeech.googleapis.com/v1/text:synthesize";
const LANGUAGE_CODE = "de-DE";

// Erlaubte Stimmen (Simon wählt in der App unter Profil -> Vorlesestimme).
// Bewusst eine feste Liste statt beliebiger Namen: so kann niemand mit dem
// öffentlichen anon-Key teure Stimmklassen (z.B. Studio) anfordern, und der
// Kostendeckel kennt für jede Stimme den richtigen Preis. MUSS zur Liste in
// Sources/TeachVoice/Core/CloudVoice.swift passen.
//   - WaveNet: ältere Generation, $4 / 1 Mio. Zeichen (bisherige Standardstimme).
//     Für de-DE gibt es nur noch -G (weiblich) und -H (männlich).
//   - Chirp 3: HD: neueste, sehr natürliche Generation, $30 / 1 Mio. Zeichen
//     (laut Googles Preisseite, Stand der Änderung). Format
//     `de-DE-Chirp3-HD-<Name>`, Tempo per speakingRate (0.25-2.0) möglich.
// Die Preise selbst stehen in _shared/apiPricing.ts (auch fürs Dashboard).
const ALLOWED_VOICES: Record<string, TtsPriceClass> = {
  "de-DE-Wavenet-G": "wavenet",
  "de-DE-Wavenet-H": "wavenet",
  "de-DE-Chirp3-HD-Despina": "chirp3_hd",
  "de-DE-Chirp3-HD-Aoede": "chirp3_hd",
  "de-DE-Chirp3-HD-Kore": "chirp3_hd",
  "de-DE-Chirp3-HD-Leda": "chirp3_hd",
  "de-DE-Chirp3-HD-Zephyr": "chirp3_hd",
  "de-DE-Chirp3-HD-Sulafat": "chirp3_hd",
  "de-DE-Chirp3-HD-Charon": "chirp3_hd",
  "de-DE-Chirp3-HD-Puck": "chirp3_hd",
  "de-DE-Chirp3-HD-Fenrir": "chirp3_hd",
  "de-DE-Chirp3-HD-Schedar": "chirp3_hd",
  "de-DE-Chirp3-HD-Umbriel": "chirp3_hd",
};
// Ältere App-Versionen schicken keine Stimme mit -> bisherige Stimme.
const DEFAULT_VOICE = "de-DE-Wavenet-G";
// Sprechtempo (1.0 = normal). Bewusst enger als Googles Spanne, damit aus
// der App nichts Unbrauchbares angefordert werden kann.
const MIN_SPEAKING_RATE = 0.5;
const MAX_SPEAKING_RATE = 1.5;

const MAX_TEXT_LENGTH = 2_000; // weit mehr als jede Karteikarten-Frage/Ansage braucht
// TTS wird pro vorgelesenem Text aufgerufen (nicht nur pro Bewertung wie bei
// grade-answer) -- durch client-seitiges Caching bleibt das in der Praxis
// deutlich niedriger, aber das Limit muss die Kappe VOR Cache-Aufbau abdecken.
const RATE_LIMIT_MAX_PER_HOUR = 300;
const RATE_LIMIT_GLOBAL_GUEST_MAX_PER_HOUR = 1200;

const CORS_HEADERS: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

interface TTSRequest {
  text: string;
  voice?: string;
  speakingRate?: number;
}

interface TTSResponse {
  // Base64-kodiertes MP3, wie von Google TTS selbst geliefert -- unverändert
  // durchgereicht, der Client dekodiert es direkt.
  audioContent: string;
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: CORS_HEADERS });
  }

  try {
    const identity = await resolveIdentity(req);
    const rateLimitOutcome = await checkRateLimit(identity, RATE_LIMIT_MAX_PER_HOUR, RATE_LIMIT_GLOBAL_GUEST_MAX_PER_HOUR);
    if (rateLimitOutcome === "rate_limited") {
      return jsonResponse({ error: "Zu viele Anfragen. Bitte kurz warten und erneut versuchen." }, 429);
    }
    if (rateLimitOutcome === "unavailable") {
      return jsonResponse({ error: "Sprachausgabe vorübergehend nicht verfügbar (Sicherheitsprüfung fehlgeschlagen). Bitte in Kürze erneut versuchen." }, 503);
    }

    const body = (await req.json()) as TTSRequest;
    if (!body.text?.trim()) {
      return jsonResponse({ error: "text ist erforderlich." }, 400);
    }
    if (body.text.length > MAX_TEXT_LENGTH) {
      return jsonResponse({ error: `text darf maximal ${MAX_TEXT_LENGTH} Zeichen haben.` }, 400);
    }

    const voice = typeof body.voice === "string" ? body.voice : DEFAULT_VOICE;
    // Object.hasOwn statt Index-Zugriff: sonst würden Namen wie "toString"
    // geerbte Eigenschaften treffen.
    const priceClass = Object.hasOwn(ALLOWED_VOICES, voice) ? ALLOWED_VOICES[voice] : undefined;
    if (priceClass === undefined) {
      return jsonResponse({ error: `Unbekannte Stimme "${voice}".` }, 400);
    }
    const pricePerChar = TTS_PRICE_PER_MILLION_CHARS_USD[priceClass] / 1_000_000;
    const speakingRate = body.speakingRate ?? 1;
    if (typeof speakingRate !== "number" || !Number.isFinite(speakingRate) ||
        speakingRate < MIN_SPEAKING_RATE || speakingRate > MAX_SPEAKING_RATE) {
      return jsonResponse({ error: `speakingRate muss zwischen ${MIN_SPEAKING_RATE} und ${MAX_SPEAKING_RATE} liegen.` }, 400);
    }

    // Harter, sofort wirksamer Ausgaben-Deckel -- Simons ausdrückliche
    // Vorgabe, das Google-Cloud-Testguthaben auf gar keinen Fall zu
    // überschreiten. Läuft VOR dem eigentlichen (bezahlten) Google-Call und
    // rechnet mit dem Preis der gewählten Stimmklasse.
    const estimatedCost = body.text.length * pricePerChar;
    const text = body.text.trim();
    // Kostenprotokoll fürs Dashboard (_shared/usageLog.ts) -- blockiert nie.
    const logUsage = (status: UsageStatus, startedAt?: number) =>
      logApiUsage({
        functionName: "text-to-speech",
        operation: "tts",
        provider: "google_tts",
        model: voice,
        priceClass,
        status,
        characters: text.length,
        estimatedCostUsd: status === "ok" ? text.length * pricePerChar : 0,
        identity,
        durationMs: startedAt !== undefined ? Date.now() - startedAt : undefined,
      });

    const spendAllowed = await checkAndReserveGoogleCloudSpend(estimatedCost);
    if (!spendAllowed) {
      logUsage("blocked");
      return jsonResponse({ error: "Cloud-Sprachausgabe momentan pausiert (internes Budget-Limit erreicht)." }, 503);
    }

    const startedAt = Date.now();
    let audioContent: string;
    try {
      audioContent = await synthesize(text, voice, speakingRate);
    } catch (err) {
      logUsage("error", startedAt);
      throw err;
    }
    logUsage("ok", startedAt);
    const response: TTSResponse = { audioContent };
    return jsonResponse(response, 200);
  } catch (err) {
    console.error(err);
    const message = err instanceof Error ? err.message : "Unbekannter Fehler";
    return jsonResponse({ error: `Unerwarteter Fehler bei der Sprachausgabe: ${message}` }, 500);
  }
});

function jsonResponse(body: unknown, status: number): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS_HEADERS, "Content-Type": "application/json" },
  });
}

async function synthesize(text: string, voice: string, speakingRate: number): Promise<string> {
  const apiKey = Deno.env.get("GOOGLE_TTS_API_KEY");
  if (!apiKey) throw new Error("GOOGLE_TTS_API_KEY ist nicht als Secret gesetzt.");

  const response = await fetch(`${GOOGLE_TTS_URL}?key=${apiKey}`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      input: { text },
      voice: { languageCode: LANGUAGE_CODE, name: voice },
      audioConfig: { audioEncoding: "MP3", speakingRate },
    }),
  });

  if (!response.ok) {
    const errText = await response.text();
    throw new Error(`Google-TTS-Fehler (${response.status}): ${errText}`);
  }

  const json = await response.json();
  if (typeof json.audioContent !== "string") {
    throw new Error("Unerwartetes Antwortformat von Google TTS.");
  }
  return json.audioContent as string;
}
