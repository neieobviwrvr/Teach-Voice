// supabase/functions/grade-answer/index.ts
//
// Bewertet eine gesprochene (STT-transkribierte) Antwort inhaltlich gegen die
// Musterantwort einer Karteikarte, via GPT-4o-mini. Nicht wortwörtlich,
// sondern sinngemäß, und mit Nachsicht gegenüber Spracherkennungsfehlern.
//
// Bewusst ZUSTANDSLOS (kein Supabase-DB-Zugriff hier): funktioniert damit
// identisch für Cloud-Karten (E-Mail-Login) UND rein lokale Gastkarten, die
// serverseitig gar nicht existieren. Lazy-Caching der Kernelemente lebt beim
// Aufrufer (Client): der schickt `kernelemente` nur mit, wenn sein eigener
// Hash der Musterantwort noch zum letzten Cache passt; sonst lässt er hier
// (kostenpflichtig) neu extrahieren und cacht das Ergebnis selbst weg
// (Supabase-Spalten im Cloud-Modus, lokale JSON-Datei im Gastmodus).
//
// WICHTIG: Der OpenAI-Key liegt ausschließlich hier als Supabase-Secret
// (`OPENAI_API_KEY`), nie im Client-Code oder Repo.

// ---------------------------------------------------------------------------
// Vorläufige Annahmen – noch nicht final bestätigt (siehe Projekt-Historie).
// Deshalb als benannte Konstanten statt tief im Code verstreut, damit sie
// leicht anpassbar bleiben, ohne die Prompt-Logik durchsuchen zu müssen.
// ---------------------------------------------------------------------------
const OPENAI_MODEL = "gpt-4o-mini";
const THRESHOLD_RICHTIG = 65; // % Kernelement-Deckung ab der "richtig" gilt
const THRESHOLD_TEILWEISE = 45; // % Deckung ab der "teilweise" gilt (darunter: "falsch")

const CORS_HEADERS: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

interface GradeRequest {
  question: string;
  answer: string; // Musterantwort, nur für die Extraktion gebraucht
  kernelemente?: string[] | null; // vom Client gecacht, falls Hash noch passt
  sttText: string;
}

interface GradingResult {
  kernelemente_getroffen: number;
  deckung_prozent: number;
  getroffene_elemente: string[];
  fehlende_elemente: string[];
  urteil: "richtig" | "teilweise" | "falsch";
  kurzes_feedback: string;
}

interface GradeResponse {
  // Immer die tatsächlich verwendeten Kernelemente – entweder die vom Client
  // mitgeschickten (Cache-Hit) oder frisch extrahierte (Cache-Miss). Der
  // Client persistiert diese nach jedem Call einfach idempotent weg.
  kernelemente: string[];
  result: GradingResult;
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: CORS_HEADERS });
  }

  try {
    const body = (await req.json()) as GradeRequest;

    if (!body.question?.trim() || !body.answer?.trim() || !body.sttText?.trim()) {
      return jsonResponse({ error: "question, answer und sttText sind erforderlich." }, 400);
    }

    let kernelemente = body.kernelemente ?? null;
    if (!kernelemente || kernelemente.length === 0) {
      kernelemente = await extractKernelemente(body.question, body.answer);
    }

    const result = await gradeAnswer(body.question, kernelemente, body.sttText);

    const response: GradeResponse = { kernelemente, result };
    return jsonResponse(response, 200);
  } catch (err) {
    console.error(err);
    const message = err instanceof Error ? err.message : "Unbekannter Fehler";
    return jsonResponse({ error: `Unerwarteter Fehler bei der Bewertung: ${message}` }, 500);
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
      temperature: 0,
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

async function extractKernelemente(question: string, answer: string): Promise<string[]> {
  const prompt = `Du zerlegst die Musterantwort einer Uni-Karteikarte in Kernelemente – die
zentralen inhaltlichen Aussagen, die eine gute Antwort abdecken sollte.

WICHTIG zur Granularität (das ist der häufigste Fehler): Fasse eng zusammengehörige
Gedanken zu EINEM Element zusammen, statt sie in Einzelteile zu zerlegen. Trenne nur,
wenn ein Teil auch ohne den anderen für sich alleine eine eigenständige, unabhängig
richtige oder falsche Aussage wäre – nicht schon, weil ein Satz mehrere Adjektive,
Präzisierungen oder ein Beispiel zu EINEM Gedanken enthält. Im Zweifel lieber ein
Element zu breit fassen als zu fein aufsplitten.

Faustregel: eine kurze Definitionsantwort (1-2 Sätze) ergibt meist 1-2 Elemente,
eine mehrteilige Erklärung oder echte Aufzählung entsprechend mehr.

Beispiel: Frage "Was ist Working Memory?", Musterantwort "Working Memory ist ein
kurzfristiges Speichersystem, das Informationen aktiv festhält und gleichzeitig
verarbeitet, z.B. beim Kopfrechnen." → richtig sind 2 Elemente ("kurzfristiges
Speichersystem, das Informationen aktiv festhält", "verarbeitet Informationen
gleichzeitig, z.B. beim Kopfrechnen") – NICHT 4, indem "kurzfristig", "festhält",
"verarbeitet" und das Beispiel einzeln aufgesplittet werden.

Frage: ${question}
Musterantwort: ${answer}

Antworte NUR mit einem JSON-Objekt der Form {"kernelemente": ["Element 1", "Element 2", ...]}.`;

  const raw = await callOpenAI(prompt);
  const parsed = JSON.parse(raw);
  const list = parsed.kernelemente;
  if (!Array.isArray(list) || list.some((e: unknown) => typeof e !== "string")) {
    throw new Error("Unerwartetes Extraktions-Format vom Modell.");
  }
  return list as string[];
}

async function gradeAnswer(
  question: string,
  kernelemente: string[],
  sttText: string
): Promise<GradingResult> {
  const prompt = `Du bewertest die gesprochene Antwort einer/eines Studierenden auf eine
Uni-Karteikartenfrage. Die Antwort wurde per Spracherkennung (Whisper) transkribiert –
behandle Formulierung, Füllwörter und leichte Erkennungsfehler DEUTLICH nachsichtiger
als bei einer geschriebenen Antwort. Es zählt der Inhalt, nicht der exakte Wortlaut.

Wichtig zu Erkennungsfehlern: Whisper verhört sich manchmal bei einzelnen Fachbegriffen
und gibt dann ein lautlich ähnliches, aber unsinniges Kunstwort aus (z.B. "Lernenghebung"
statt "Lernumgebung", oder "Verstärkungsplan" verhört als "Verstärkungsplarm"). Wenn ein
Wort im Transkript keinen Sinn ergibt, aber phonetisch klar erkennbar einem erwarteten
Fachbegriff aus den Kernelementen ähnelt, zähle es trotzdem als korrekt getroffen – gehe
im Zweifel davon aus, dass die/der Studierende das richtige Wort gesagt hat und nur die
Spracherkennung es falsch verschriftlicht hat.

Wichtig zur Großzügigkeit (das ist der häufigste Fehler): Ein Kernelement gilt bereits
als GETROFFEN, wenn der zentrale Gedanke sinngemäß erkennbar ist – auch wenn die
Formulierung stark von der Musterantwort abweicht (andere Worte, andere Reihenfolge,
umgangssprachlich statt Fachbegriff), ein untergeordnetes Detail oder Beispiel fehlt,
oder nur knapp statt ausführlich auf den Punkt eingegangen wird. Werte ein Element nur
als FEHLEND, wenn der Kerngedanke selbst nicht erkennbar ist – nicht schon, weil ein
einzelnes Fachwort oder Nebendetail fehlt. Bei einem Grenzfall zwischen "getroffen" und
"nicht getroffen" entscheide GROSSZÜGIG zugunsten der/des Studierenden.

Wichtig zu "deckung_prozent" bei mehrteiligen Kernelementen: Manche Kernelemente bündeln
mehrere eigenständige Teilaussagen (z.B. zwei Fakten, die man unabhängig voneinander
wissen oder nicht wissen kann, nicht nur einen Kerngedanken mit einem Nebendetail). Wird
davon nur ein Teil korrekt genannt, zähle dieses Element NICHT einfach binär als
"fehlend" – rechne den getroffenen Teilaspekt anteilig in "deckung_prozent" ein (z.B.
zählt ein zur Hälfte abgedecktes Element mit halbem Gewicht statt mit vollem Gewicht als
verfehlt). "deckung_prozent" soll die tatsächliche inhaltliche Gesamtabdeckung
widerspiegeln, nicht nur ein starres (Anzahl komplett getroffen) / (Anzahl gesamt).

Frage: ${question}

Kernelemente der Musterantwort (jedes einzeln auf sinngemäßes Vorkommen prüfen):
${kernelemente.map((e, i) => `${i + 1}. ${e}`).join("\n")}

Gesprochene Antwort (STT-Transkript): ${sttText}

Antworte NUR mit einem JSON-Objekt exakt dieser Form:
{
  "kernelemente_getroffen": <Zahl>,
  "deckung_prozent": <Zahl 0-100>,
  "getroffene_elemente": ["..."],
  "fehlende_elemente": ["..."],
  "urteil": "richtig" | "teilweise" | "falsch",
  "kurzes_feedback": "<max. 1 Satz auf Deutsch an den/die Studierende(n)>"
}

Urteil-Schwellen: ab ${THRESHOLD_RICHTIG}% Deckung "richtig", ab ${THRESHOLD_TEILWEISE}% "teilweise", darunter "falsch".`;

  const raw = await callOpenAI(prompt);
  const parsed = JSON.parse(raw) as GradingResult;

  // Serverseitige Absicherung: Urteil unabhängig vom Modell-Output aus
  // deckung_prozent neu ableiten, falls sich das Modell nicht exakt an die
  // vorgegebenen Schwellen gehalten hat.
  const pct = Number(parsed.deckung_prozent) || 0;
  const urteil: GradingResult["urteil"] =
    pct >= THRESHOLD_RICHTIG ? "richtig" : pct >= THRESHOLD_TEILWEISE ? "teilweise" : "falsch";

  return { ...parsed, deckung_prozent: pct, urteil };
}
