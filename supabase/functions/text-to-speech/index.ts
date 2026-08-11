// supabase/functions/text-to-speech/index.ts
//
// Wandelt Text in gesprochenes Audio um, über Google Cloud Text-to-Speech
// (WaveNet-Stimmen). Grund für den Wechsel weg von reinem on-device Apple-TTS:
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

const GOOGLE_TTS_URL = "https://texttospeech.googleapis.com/v1/text:synthesize";
// WaveNet (nicht Standard, nicht Neural2) -- das ist die Stufe, die im
// Google-Cloud-Freikontingent (1 Mio. Zeichen/Monat) steckt. Konkrete Stimme
// (A-F, verschiedene Personas) noch nicht final durch Anhören bestätigt --
// bewusst als eigene Konstante, leicht austauschbar ohne den Rest anzufassen.
const VOICE_NAME = "de-DE-Wavenet-F";
const LANGUAGE_CODE = "de-DE";

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

    const audioContent = await synthesize(body.text.trim());
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

async function synthesize(text: string): Promise<string> {
  const apiKey = Deno.env.get("GOOGLE_TTS_API_KEY");
  if (!apiKey) throw new Error("GOOGLE_TTS_API_KEY ist nicht als Secret gesetzt.");

  const response = await fetch(`${GOOGLE_TTS_URL}?key=${apiKey}`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      input: { text },
      voice: { languageCode: LANGUAGE_CODE, name: VOICE_NAME },
      audioConfig: { audioEncoding: "MP3" },
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
