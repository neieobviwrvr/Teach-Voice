// supabase/functions/teach-mcp/index.ts
//
// MCP-Server ("Konnektor") für Claude: Claude kann darüber die Teach-
// Bibliothek eines Nutzers ansehen und neue Ordner, Unterordner und
// Karteikarten anlegen. Die App liest die Karten danach ganz normal aus Supabase.
//
// v1 kann bewusst nur LESEN und NEU ANLEGEN (Simons Entscheidung): kein
// Ändern, kein Löschen -- ein Fehler der KI kann so nichts kaputtmachen.
//
// Anmeldung: persönlicher Schlüssel (`tvk_…`), den die App über die Edge
// Function `connector-key` erzeugt. Hauptweg ist der "persönliche
// Claude-Link" `…/functions/v1/teach-mcp/tvk_…`: der Schlüssel steckt im
// Pfad, weil Claude beim Hinzufügen eigener Konnektoren in normalen Konten
// keine Request-Header anbietet (nur Beta für einzelne Organisationen). Der
// Link ist damit so geheim wie ein Passwort -- Zapier & Co. machen es genauso.
// Weiter akzeptiert: `?key=tvk_…`, `Authorization: Bearer tvk_…` und
// `X-Teach-Key` (z.B. für Claude Code oder die API). Hier wird nur der
// SHA-256-Hash in `connector_keys` nachgeschlagen (siehe
// 0012_connector_keys.sql). Für fremde Nutzer / ChatGPT später: OAuth über
// Supabases OAuth-2.1-Server statt Schlüssel.
//
// Die Request-URL wird deshalb NIE geloggt. Bekannter, akzeptierter
// Nachteil: Supabase selbst protokolliert Aufrufpfade in den Function-Logs
// des Projekts (nur für den Projekt-Owner sichtbar).
//
// Deploy NUR mit verify_jwt = false (siehe supabase/config.toml), weil der
// Schlüssel kein JWT ist -- sonst lehnt das Supabase-Gateway jede Anfrage ab.
//
// SICHERHEIT: Datenzugriff läuft über service_role (umgeht RLS). Deshalb
// filtert hier JEDE Abfrage explizit auf `user_id=eq.<userId>`, jeder Insert
// setzt `user_id` selbst, und vor jedem Schreiben wird geprüft, dass Ordner/
// Unterordner diesem Nutzer gehören. Neue Tools müssen das genauso machen.
//
// Gastmodus wird nicht unterstützt: Gast-Daten liegen nur auf dem iPhone.

import "jsr:@supabase/functions-js/edge-runtime.d.ts";

import { createMcpHandler, McpServer } from "npm:@modelcontextprotocol/server@^2.4.0";
import { z } from "npm:zod@^4.3.6";

import { CONNECTOR_KEY_PREFIX, hashConnectorKey, looksLikeConnectorKey } from "../_shared/connectorKey.ts";
import { checkRateLimit } from "../_shared/rateLimit.ts";
import { serviceRest } from "../_shared/serviceRest.ts";

// Keine Mengen-Limits für Ordner/Unterordner/Karten mehr (Simons Entscheidung
// fürs MVP, siehe 0013_remove_limits.sql). Nur die Anzahl Karten PRO AUFRUF
// ist gedeckelt, damit ein einzelner Request überschaubar groß bleibt --
// mehr Karten legt Claude einfach mit mehreren Aufrufen an.
const MAX_CARDS_PER_CALL = 50;

// Frage <= MAX_TEXT_LENGTH in text-to-speech (sonst nicht vorlesbar),
// Antwort <= MAX_ANSWER_LENGTH in grade-answer (sonst nicht bewertbar).
const MAX_QUESTION_LENGTH = 2_000;
const MAX_ANSWER_LENGTH = 5_000;
const MAX_NAME_LENGTH = 100;

// Zählt JEDE MCP-Anfrage (auch initialize/tools/list, die Claude zu Beginn
// jedes Chats schickt). Kein OpenAI-Kostenrisiko hier, nur DB-Zugriffe --
// deshalb großzügiger als grade-answer. Eigener Bucket ("connector:"), damit
// Konnektor-Nutzung nicht das Bewertungs-Kontingent der App aufbraucht.
const RATE_LIMIT_MAX_PER_HOUR = 200;

// `last_used_at` nur alle paar Minuten schreiben statt bei jeder Anfrage.
const LAST_USED_UPDATE_INTERVAL_MS = 5 * 60 * 1000;

const SERVER_INSTRUCTIONS = `Teach (Voice) ist eine Karteikarten-App fürs Lernen per Sprache: Die App liest die Frage vor, der Nutzer antwortet laut, und eine KI bewertet die Antwort danach, wie viele Kernpunkte der Musterantwort genannt wurden.

Struktur: Ordner (z.B. ein Fach) -> Unterordner (z.B. ein Thema oder Kapitel) -> Karteikarten (Frage + Musterantwort). Es gibt keine Mengen-Limits.

Ablauf:
1. list_library aufrufen, um Ordner, Unterordner und IDs zu sehen.
2. Fehlt der passende Ordner, mit create_folder anlegen. Fehlt das passende Thema, mit create_subfolder einen Unterordner anlegen.
3. Vor dem Ergänzen eines bestehenden Unterordners list_flashcards aufrufen, um Doppelungen zu vermeiden.
4. Mit add_flashcards die Karten anlegen (höchstens ${MAX_CARDS_PER_CALL} pro Aufruf, bei mehr einfach mehrere Aufrufe).

Der Konnektor kann keine bestehenden Karten ändern oder löschen. Das geht nur in der App.`;

const CARD_STYLE_GUIDE = `So entstehen gute Karten für Teach:
- Frage: eine klare, eigenständige Frage, die sich gut vorlesen lässt (keine Tabellen, keine Formelnotation, Abkürzungen ausschreiben).
- Musterantwort: prägnante Kernpunkte statt Fließtext, meist 1-3 Sätze oder bis zu 5 Aufzählungspunkte. Jeder Punkt sollte eine einzelne, prüfbare Aussage sein, denn bewertet wird, wie viele davon der Nutzer nennt.
- Formatierung: nur **fett** und Zeilen, die mit "- " beginnen (Aufzählung). Keine Überschriften, Nummerierungen, Links oder Tabellen.
- Sprache: die Sprache des Nutzers, normalerweise Deutsch.`;

Deno.serve(async (req: Request) => {
  // Kein CORS: Claude ruft den Konnektor serverseitig aus der Anthropic-Cloud
  // auf, nicht aus einem Browser.
  try {
    // Schlüssel aus Pfad/Query herauslösen. Der MCP-Handler bekommt danach
    // eine bereinigte Kopie des Requests mit der Basis-URL wie vorher, damit
    // der Schlüssel nirgends weitergereicht oder zurückgegeben wird.
    const { key: urlKey, cleanedUrl } = splitKeyFromUrl(req.url);
    const userId = await authenticate(extractHeaderKey(req) ?? urlKey);
    if (!userId) {
      return jsonResponse(
        { error: "Ungültiger oder gesperrter Teach-Konnektor-Schlüssel. Erzeuge in der App unter Profil -> KI-Konnektor einen neuen." },
        401
      );
    }

    const rateLimitOutcome = await checkRateLimit(`connector:${userId}`, RATE_LIMIT_MAX_PER_HOUR);
    if (rateLimitOutcome === "rate_limited") {
      return jsonResponse({ error: "Zu viele Anfragen an den Teach-Konnektor. Bitte etwas später erneut versuchen." }, 429);
    }
    if (rateLimitOutcome === "unavailable") {
      return jsonResponse({ error: "Teach-Konnektor vorübergehend nicht verfügbar (Sicherheitsprüfung fehlgeschlagen)." }, 503);
    }

    // Pro Anfrage ein frischer Server (Edge Functions sind zustandslos), mit
    // der geprüften User-ID fest eingebaut. Ältere MCP-Clients (2025er
    // Protokoll mit `initialize`) bedient createMcpHandler standardmäßig mit
    // (`legacy: 'stateless'`).
    const handler = createMcpHandler(() => buildServer(userId));
    return await handler.fetch(await withUrl(req, cleanedUrl));
  } catch (err) {
    console.error("teach-mcp:", err);
    return jsonResponse({ error: "Teach-Konnektor vorübergehend nicht verfügbar." }, 503);
  }
});

// MARK: - Anmeldung

interface ConnectorKeyRow {
  id: string;
  user_id: string;
  last_used_at: string | null;
}

/// Liefert die User-ID zum Schlüssel oder `null`, wenn er fehlt, falsch oder
/// gesperrt ist.
async function authenticate(key: string | null): Promise<string | null> {
  if (!key || !looksLikeConnectorKey(key)) return null;

  const keyHash = await hashConnectorKey(key);
  const rows = await serviceRest<ConnectorKeyRow[]>(
    `connector_keys?key_hash=eq.${keyHash}&revoked_at=is.null&select=id,user_id,last_used_at`
  );
  const row = rows[0];
  if (!row) return null;

  const lastUsed = row.last_used_at ? Date.parse(row.last_used_at) : 0;
  if (Date.now() - lastUsed > LAST_USED_UPDATE_INTERVAL_MS) {
    try {
      await serviceRest<null>(`connector_keys?id=eq.${row.id}`, {
        method: "PATCH",
        body: { last_used_at: new Date().toISOString() },
        prefer: "return=minimal",
      });
    } catch (err) {
      // Nur Komfort-Anzeige in der App -- darf die Anfrage nicht scheitern lassen.
      console.error("teach-mcp: last_used_at konnte nicht aktualisiert werden", err);
    }
  }
  return row.user_id;
}

/// Schlüssel aus den Headern: `X-Teach-Key` oder `Authorization: Bearer tvk_…`
/// (aus Toleranz auch ohne "Bearer "). Nur ein `tvk_…`-Wert zählt, damit z.B.
/// ein fremdes Bearer-Token eines Clients den Schlüssel aus der URL nicht
/// verdrängt.
function extractHeaderKey(req: Request): string | null {
  const explicit = req.headers.get("x-teach-key")?.trim();
  if (explicit?.startsWith(CONNECTOR_KEY_PREFIX)) return explicit;

  const auth = req.headers.get("authorization")?.trim();
  if (!auth) return null;
  const value = auth.toLowerCase().startsWith("bearer ") ? auth.slice("bearer ".length).trim() : auth;
  return value.startsWith(CONNECTOR_KEY_PREFIX) ? value : null;
}

/// Löst einen Schlüssel aus der URL heraus -- als Pfad-Segment
/// (`…/teach-mcp/tvk_…`, so steht der persönliche Claude-Link in der App)
/// oder als `?key=tvk_…` -- und liefert die URL ohne ihn zurück.
function splitKeyFromUrl(rawUrl: string): { key: string | null; cleanedUrl: string } {
  const url = new URL(rawUrl);
  let key: string | null = null;

  const segments = url.pathname.split("/");
  const keyIndex = segments.findIndex((segment) => segment.startsWith(CONNECTOR_KEY_PREFIX));
  if (keyIndex !== -1) {
    key = safeDecode(segments[keyIndex]);
    segments.splice(keyIndex, 1);
    url.pathname = segments.join("/") || "/";
  }

  const queryKey = url.searchParams.get("key")?.trim();
  if (queryKey) {
    key = key ?? queryKey;
    url.searchParams.delete("key");
  }

  return { key, cleanedUrl: url.toString() };
}

/// Kopie des Requests mit anderer URL. Der Body wird gepuffert statt als
/// Stream weitergereicht (MCP-Nachrichten sind klein), damit die Kopie in
/// jeder Runtime ohne `duplex`-Sonderoption funktioniert.
async function withUrl(req: Request, url: string): Promise<Request> {
  if (url === req.url) return req;
  const hasBody = req.method !== "GET" && req.method !== "HEAD";
  return new Request(url, {
    method: req.method,
    headers: req.headers,
    body: hasBody ? await req.arrayBuffer() : undefined,
    signal: req.signal,
  });
}

function safeDecode(value: string): string {
  try {
    return decodeURIComponent(value);
  } catch {
    return value;
  }
}

// MARK: - Tools

interface FolderRow {
  id: string;
  name: string;
}

interface SubfolderRow {
  id: string;
  folder_id: string;
  name: string;
}

interface CardRow {
  subfolder_id: string;
  question: string;
  answer: string;
}

type ToolResult = {
  content: { type: "text"; text: string }[];
  isError?: boolean;
};

function textResult(data: unknown): ToolResult {
  return { content: [{ type: "text", text: JSON.stringify(data, null, 2) }] };
}

function errorResult(message: string): ToolResult {
  return { content: [{ type: "text", text: message }], isError: true };
}

/// Unerwartete technische Fehler als lesbares Tool-Ergebnis an Claude statt
/// als Absturz der ganzen Anfrage.
function safe<A>(fn: (args: A) => Promise<ToolResult>): (args: A) => Promise<ToolResult> {
  return async (args: A) => {
    try {
      return await fn(args);
    } catch (err) {
      console.error("teach-mcp tool:", err);
      return errorResult("Technischer Fehler beim Zugriff auf die Teach-Datenbank. Es wurde nichts gespeichert. Bitte später erneut versuchen.");
    }
  };
}

function buildServer(userId: string): McpServer {
  const server = new McpServer({ name: "teach-voice", version: "1.0.0" }, { instructions: SERVER_INSTRUCTIONS });

  // --- Lesen ---------------------------------------------------------------

  server.registerTool(
    "list_library",
    {
      title: "Teach-Bibliothek anzeigen",
      description:
        "Zeigt alle Ordner und Unterordner des Nutzers mit IDs und Kartenanzahl. Immer zuerst aufrufen, bevor Ordner oder Karten angelegt werden.",
      annotations: { readOnlyHint: true, openWorldHint: false },
    },
    safe(async () => {
      const [folders, subfolders, cards] = await Promise.all([
        serviceRest<FolderRow[]>(`folders?user_id=eq.${userId}&select=id,name&order=position.asc,created_at.asc`),
        serviceRest<SubfolderRow[]>(
          `subfolders?user_id=eq.${userId}&select=id,folder_id,name&order=position.asc,created_at.asc`
        ),
        serviceRest<{ subfolder_id: string }[]>(`flashcards?user_id=eq.${userId}&select=subfolder_id`),
      ]);

      const cardsPerSubfolder = new Map<string, number>();
      for (const card of cards) {
        cardsPerSubfolder.set(card.subfolder_id, (cardsPerSubfolder.get(card.subfolder_id) ?? 0) + 1);
      }

      const ordner = folders.map((folder) => {
        const own = subfolders.filter((s) => s.folder_id === folder.id);
        const folderTotal = own.reduce((sum, s) => sum + (cardsPerSubfolder.get(s.id) ?? 0), 0);
        return {
          id: folder.id,
          name: folder.name,
          karten_gesamt: folderTotal,
          unterordner: own.map((s) => ({
            id: s.id,
            name: s.name,
            karten: cardsPerSubfolder.get(s.id) ?? 0,
          })),
        };
      });

      if (ordner.length === 0) {
        return textResult({
          ordner: [],
          hinweis: "Der Nutzer hat noch keinen Ordner. Lege mit create_folder einen an.",
        });
      }
      return textResult({ ordner });
    })
  );

  server.registerTool(
    "list_flashcards",
    {
      title: "Karteikarten eines Unterordners anzeigen",
      description:
        "Zeigt alle Fragen und Musterantworten eines Unterordners. Vor dem Ergänzen eines bestehenden Unterordners aufrufen, um Doppelungen zu vermeiden.",
      inputSchema: z.object({
        subfolder_id: z.uuid().describe("ID des Unterordners aus list_library"),
      }),
      annotations: { readOnlyHint: true, openWorldHint: false },
    },
    safe(async ({ subfolder_id }: { subfolder_id: string }) => {
      const subfolder = await ownedSubfolder(userId, subfolder_id);
      if (!subfolder) return errorResult("Unterordner nicht gefunden. Rufe list_library auf, um die gültigen IDs zu sehen.");

      const cards = await cardsIn(userId, subfolder_id);
      return textResult({
        unterordner: subfolder.name,
        karten: cards.map((c, i) => ({ nr: i + 1, frage: c.question, antwort: c.answer })),
      });
    })
  );

  // --- Neu anlegen ---------------------------------------------------------

  server.registerTool(
    "create_folder",
    {
      title: "Ordner anlegen",
      description:
        "Legt einen neuen, leeren Ober-Ordner an (z.B. für ein Fach) und gibt seine ID zurück. Vorher mit list_library prüfen, ob es einen passenden Ordner schon gibt.",
      inputSchema: z.object({
        name: z.string().trim().min(1).max(MAX_NAME_LENGTH).describe("Name des neuen Ordners"),
      }),
      annotations: { readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false },
    },
    safe(async ({ name }: { name: string }) => {
      // Doppelte Namen abfangen, z.B. wenn Claude nach einem Timeout erneut
      // versucht -- sonst entstehen zwei gleichnamige Ordner.
      const existing = await serviceRest<FolderRow[]>(`folders?user_id=eq.${userId}&select=id,name`);
      const duplicate = existing.find((f) => normalize(f.name) === normalize(name));
      if (duplicate) {
        return errorResult(
          `Es gibt bereits einen Ordner "${duplicate.name}" (id ${duplicate.id}). Nutze ihn mit create_subfolder oder wähle einen anderen Namen.`
        );
      }

      // `position` bleibt beim DB-Default 0 wie beim Anlegen in der App: die
      // App sortiert nach `position, created_at`, der neue Ordner steht also hinten.
      const inserted = await serviceRest<FolderRow[]>("folders?select=id,name", {
        method: "POST",
        body: { user_id: userId, name },
        prefer: "return=representation",
      });
      const created = inserted[0];
      return textResult({ angelegt: true, ordner: { id: created.id, name: created.name } });
    })
  );

  server.registerTool(
    "create_subfolder",
    {
      title: "Unterordner anlegen",
      description: "Legt in einem bestehenden Ordner einen neuen, leeren Unterordner an und gibt seine ID zurück.",
      inputSchema: z.object({
        folder_id: z.uuid().describe("ID des Ordners aus list_library"),
        name: z.string().trim().min(1).max(MAX_NAME_LENGTH).describe("Name des neuen Unterordners"),
      }),
      annotations: { readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false },
    },
    safe(async ({ folder_id, name }: { folder_id: string; name: string }) => {
      const folders = await serviceRest<FolderRow[]>(`folders?id=eq.${folder_id}&user_id=eq.${userId}&select=id,name`);
      const folder = folders[0];
      if (!folder) return errorResult("Ordner nicht gefunden. Rufe list_library auf, um die gültigen IDs zu sehen.");

      // Doppelte Namen abfangen, z.B. wenn Claude nach einem Timeout erneut
      // versucht -- sonst entstehen zwei gleichnamige Unterordner.
      const existing = await serviceRest<SubfolderRow[]>(
        `subfolders?folder_id=eq.${folder_id}&user_id=eq.${userId}&select=id,folder_id,name`
      );
      const duplicate = existing.find((s) => normalize(s.name) === normalize(name));
      if (duplicate) {
        return errorResult(
          `Im Ordner "${folder.name}" gibt es bereits einen Unterordner "${duplicate.name}" (id ${duplicate.id}). Nutze ihn mit add_flashcards oder wähle einen anderen Namen.`
        );
      }

      const inserted = await serviceRest<SubfolderRow[]>("subfolders?select=id,folder_id,name", {
        method: "POST",
        body: { folder_id, user_id: userId, name },
        prefer: "return=representation",
      });
      const created = inserted[0];
      return textResult({
        angelegt: true,
        ordner: folder.name,
        unterordner: { id: created.id, name: created.name },
      });
    })
  );

  server.registerTool(
    "add_flashcards",
    {
      title: "Karteikarten anlegen",
      description: `Legt neue Karteikarten in einem Unterordner an (1-${MAX_CARDS_PER_CALL} pro Aufruf, für mehr einfach mehrmals aufrufen). Fragen, die es im Unterordner schon gibt, werden übersprungen.\n\n${CARD_STYLE_GUIDE}`,
      inputSchema: z.object({
        subfolder_id: z.uuid().describe("ID des Unterordners aus list_library oder create_subfolder"),
        cards: z
          .array(
            z.object({
              question: z.string().trim().min(1).max(MAX_QUESTION_LENGTH).describe("Die Frage, die die App vorliest"),
              answer: z.string().trim().min(1).max(MAX_ANSWER_LENGTH).describe("Die Musterantwort als Kernpunkte"),
            })
          )
          .min(1)
          .max(MAX_CARDS_PER_CALL),
      }),
      annotations: { readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false },
    },
    safe(async ({ subfolder_id, cards }: { subfolder_id: string; cards: { question: string; answer: string }[] }) => {
      const subfolder = await ownedSubfolder(userId, subfolder_id);
      if (!subfolder) return errorResult("Unterordner nicht gefunden. Rufe list_library auf, um die gültigen IDs zu sehen.");

      const existingCards = await cardsIn(userId, subfolder_id);

      // Doppelte Fragen überspringen: gegen den Bestand UND innerhalb des
      // Aufrufs. Schützt vor Duplikaten, wenn Claude einen Aufruf wiederholt.
      const seen = new Set(existingCards.map((c) => normalize(c.question)));
      const toInsert: { question: string; answer: string }[] = [];
      const skipped: string[] = [];
      for (const card of cards) {
        const key = normalize(card.question);
        if (seen.has(key)) {
          skipped.push(card.question);
        } else {
          seen.add(key);
          toInsert.push(card);
        }
      }

      if (toInsert.length === 0) {
        return textResult({ angelegt: 0, uebersprungen_weil_schon_vorhanden: skipped });
      }

      // Die App sortiert nach `position, created_at`. Alle Karten eines
      // Bulk-Inserts hätten sonst denselben Zeitstempel (now() = Beginn der
      // Transaktion) und damit keine feste Reihenfolge -- deshalb pro Karte
      // 1 ms Abstand. `position` bleibt 0 wie bei Karten aus der App.
      // `kernelemente`/`srs_*` bleiben leer: der Bewertungs-Cache füllt sich
      // beim ersten Lernen von selbst.
      const base = Date.now();
      const rows = toInsert.map((card, i) => ({
        subfolder_id,
        user_id: userId,
        question: card.question,
        answer: card.answer,
        created_at: new Date(base + i).toISOString(),
      }));

      // Der Insert ist atomar: schlägt er fehl, ist gar nichts gespeichert
      // (`safe` meldet das dann lesbar an Claude).
      await serviceRest<null>("flashcards", { method: "POST", body: rows, prefer: "return=minimal" });

      return textResult({
        angelegt: toInsert.length,
        unterordner: subfolder.name,
        karten_im_unterordner: existingCards.length + toInsert.length,
        uebersprungen_weil_schon_vorhanden: skipped,
        hinweis: "In der App erscheinen die Karten beim nächsten Öffnen des Unterordners oder nach Runterziehen der Liste.",
      });
    })
  );

  return server;
}

// MARK: - Datenzugriff (immer mit user_id-Filter, siehe Datei-Kopf)

async function ownedSubfolder(userId: string, subfolderId: string): Promise<SubfolderRow | null> {
  const rows = await serviceRest<SubfolderRow[]>(
    `subfolders?id=eq.${subfolderId}&user_id=eq.${userId}&select=id,folder_id,name`
  );
  return rows[0] ?? null;
}

async function cardsIn(userId: string, subfolderId: string): Promise<CardRow[]> {
  return await serviceRest<CardRow[]>(
    `flashcards?subfolder_id=eq.${subfolderId}&user_id=eq.${userId}&select=subfolder_id,question,answer&order=position.asc,created_at.asc`
  );
}

function normalize(text: string): string {
  return text.trim().replace(/\s+/g, " ").toLowerCase();
}

function jsonResponse(body: unknown, status: number): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}
