// supabase/functions/generate-questions/index.ts
//
// Generiert aus client-seitig extrahiertem PDF-Text (siehe
// PDFTextExtractor.swift) bis zu N Frage+Musterantwort-Paare für den
// PDF-Import in Teach (Voice). Bewusst eine EIGENE Function statt in
// grade-answer integriert: andere Aufgabe (Content-Erstellung statt
// Bewertung), eigener, unabhängiger Vertrag.
//
// Bewusst ZUSTANDSLOS, gleiches Prinzip wie grade-answer: kein DB-Zugriff,
// funktioniert identisch für Cloud- und Gastkarten. Der PDF-Inhalt selbst
// wird NIE hochgeladen/gespeichert – nur der bereits client-seitig
// extrahierte (und auf max. 80.000 Zeichen gekappte) Text geht hierher.
//
// WICHTIG: Der OpenAI-Key liegt ausschließlich hier als Supabase-Secret
// (`OPENAI_API_KEY`), nie im Client-Code oder Repo.

const OPENAI_MODEL = "gpt-4o-mini";
const MAX_QUESTIONS_CEILING = 25; // muss mit maxFlashcardsPerSubfolder (Models.swift) übereinstimmen

const CORS_HEADERS: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

interface GenerateRequest {
  text: string;
  maxQuestions: number;
}

interface GeneratedQuestion {
  frage: string;
  musterantwort: string;
}

interface GenerateResponse {
  fragen: GeneratedQuestion[];
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: CORS_HEADERS });
  }

  try {
    const body = (await req.json()) as GenerateRequest;

    if (!body.text?.trim()) {
      return jsonResponse({ error: "text ist erforderlich." }, 400);
    }

    // Serverseitig nochmal deckeln, unabhängig davon was der Client schickt.
    const requested = Math.floor(body.maxQuestions ?? 12);
    const maxQuestions = Math.min(Math.max(requested, 1), MAX_QUESTIONS_CEILING);

    const fragen = await generateQuestions(body.text, maxQuestions);
    const response: GenerateResponse = { fragen };
    return jsonResponse(response, 200);
  } catch (err) {
    console.error(err);
    const message = err instanceof Error ? err.message : "Unbekannter Fehler";
    return jsonResponse({ error: `Unerwarteter Fehler bei der Fragengenerierung: ${message}` }, 500);
  }
});

function jsonResponse(body: unknown, status: number): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS_HEADERS, "Content-Type": "application/json" },
  });
}

async function callOpenAI(prompt: string): Promise<string> {
  const apiKey = Deno.env.get("OPENAI_API_KEY");
  if (!apiKey) throw new Error("OPENAI_API_KEY ist nicht als Secret gesetzt.");

  const response = await fetch("https://api.openai.com/v1/chat/completions", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${apiKey}`,
    },
    body: JSON.stringify({
      model: OPENAI_MODEL,
      messages: [{ role: "user", content: prompt }],
      temperature: 0.3,
      response_format: { type: "json_object" },
    }),
  });

  if (!response.ok) {
    const errText = await response.text();
    throw new Error(`OpenAI-Fehler (${response.status}): ${errText}`);
  }

  const json = await response.json();
  return json.choices[0].message.content as string;
}

async function generateQuestions(text: string, maxQuestions: number): Promise<GeneratedQuestion[]> {
  const prompt = `Du bekommst einen Auszug aus Vorlesungsfolien (aus einem PDF extrahiert – daher ggf.
mit unsauberen Zeilenumbrüchen/Leerzeichen aus Tabellen-Layouts; ignoriere solche Formatierungsreste,
sie sind keine inhaltliche Aussage). Der Text kann durch "--- Seite N ---"-Marker in Seiten gegliedert
sein und wurde ggf. am Ende gekappt, falls das Dokument sehr lang war.

Identifiziere bis zu ${maxQuestions} eigenständige, prüfungsrelevante Kernaussagen/Konzepte aus dem
GESAMTEN Text. WICHTIG: Verteile deine Auswahl über das komplette Dokument (alle Seitenbereiche),
nicht nur über die ersten Seiten – Modelle neigen dazu, den Anfang zu bevorzugen, das soll hier
NICHT passieren. Wenn weniger als ${maxQuestions} wirklich eigenständige, wichtige Konzepte
vorhanden sind, gib entsprechend WENIGER zurück – erfinde nichts und fülle nicht künstlich auf, nur
um die Zahl zu erreichen.

Erstelle für jedes Konzept EINE Prüfungsfrage (Stil "Was ist...", "Erkläre...", "Nenne...", passend
zum jeweiligen Konzept) und eine prägnante, inhaltlich korrekte Musterantwort dazu (2-4 Sätze,
kein bloßes Stichwort).

Text:
${text}

Antworte NUR mit einem JSON-Objekt exakt dieser Form:
{"fragen": [{"frage": "...", "musterantwort": "..."}, ...]}`;

  const raw = await callOpenAI(prompt);
  const parsed = JSON.parse(raw);
  const list = parsed.fragen;
  const isValid =
    Array.isArray(list) &&
    list.every(
      (e: unknown) =>
        typeof e === "object" &&
        e !== null &&
        typeof (e as Record<string, unknown>).frage === "string" &&
        typeof (e as Record<string, unknown>).musterantwort === "string"
    );
  if (!isValid) {
    throw new Error("Unerwartetes Format vom Modell.");
  }
  return (list as GeneratedQuestion[]).slice(0, maxQuestions);
}
