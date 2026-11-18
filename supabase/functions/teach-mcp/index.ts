// supabase/functions/teach-mcp/index.ts
//
// MCP-Server ("Konnektor") für Claude: Claude kann darüber die Teach-
// Bibliothek eines Nutzers ansehen und neue Unterordner + Karteikarten
// anlegen. Die App liest die Karten danach ganz normal aus Supabase.
//
// v1 kann bewusst nur LESEN und NEU ANLEGEN (Simons Entscheidung): kein
// Ändern, kein Löschen -- ein Fehler der KI kann so nichts kaputtmachen.
//
// Anmeldung: persönlicher Schlüssel (`tvk_…`), den die App über die Edge
// Function `connector-key` erzeugt und den man in Claude als Request-Header
// `Authorization: Bearer tvk_…` einträgt. Hier wird nur sein SHA-256-Hash in
// `connector_keys` nachgeschlagen (siehe 0012_connector_keys.sql). Für fremde
// Nutzer / ChatGPT später: OAuth über Supabases OAuth-2.1-Server statt Schlüssel.
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

import { hashConnectorKey, looksLikeConnectorKey } from "../_shared/connectorKey.ts";
import { checkRateLimit } from "../_shared/rateLimit.ts";
import { ServiceRestError, serviceRest } from "../_shared/serviceRest.ts";

// Limits -- müssen mit Models.swift (`maxFlashcardsPerSubfolder`,
// `maxFlashcardsPerFolder`) und dem DB-Trigger `enforce_flashcard_limit`
// (0007_unlimited_subfolders.sql) übereinstimmen. Der Trigger bleibt die
// letzte Instanz; die Zahlen hier sind für verständliche Meldungen an Claude.
const MAX_FLASHCARDS_PER_SUBFOLDER = 25;
const MAX_FLASHCARDS_PER_FOLDER = 50;

// Frage <= MAX_TEXT_LENGTH in text-to-speech (sonst nicht vorlesbar),
// Antwort <= MAX_ANSWER_LENGTH in grade-answer (sonst nicht bewertbar).
const MAX_QUESTION_LENGTH = 2_000;
const MAX_ANSWER_LENGTH = 5_000;
const MAX_SUBFOLDER_NAME_LENGTH = 100;

// Zählt JEDE MCP-Anfrage (auch initialize/tools/list, die Claude zu Beginn
// jedes Chats schickt). Kein OpenAI-Kostenrisiko hier, nur DB-Zugriffe --
// deshalb großzügiger als grade-answer. Eigener Bucket ("connector:"), damit
// Konnektor-Nutzung nicht das Bewertungs-Kontingent der App aufbraucht.
const RATE_LIMIT_MAX_PER_HOUR = 200;

// `last_used_at` nur alle paar Minuten schreiben statt bei jeder Anfrage.
const LAST_USED_UPDATE_INTERVAL_MS = 5 * 60 * 1000;

const SERVER_INSTRUCTIONS = `Teach (Voice) ist eine Karteikarten-App fürs Lernen per Sprache: Die App liest die Frage vor, der Nutzer antwortet laut, und eine KI bewertet die Antwort danach, wie viele Kernpunkte der Musterantwort genannt wurden.

Struktur: Ordner -> Unterordner -> Karteikarten (Frage + Musterantwort). Limits: höchstens ${MAX_FLASHCARDS_PER_SUBFOLDER} Karten pro Unterordner und ${MAX_FLASHCARDS_PER_FOLDER} pro Ordner (über alle Unterordner zusammen). Ordner selbst kann dieser Konnektor nicht anlegen.

Ablauf:
1. list_library aufrufen, um Ordner, Unterordner, IDs und freie Plätze zu sehen.
2. Bei Bedarf mit create_subfolder einen neuen Unterordner anlegen.
3. Vor dem Ergänzen eines bestehenden Unterordners list_flashcards aufrufen, um Doppelungen zu vermeiden.
4. Mit add_flashcards die Karten anlegen.

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
    const userId = await authenticate(req);
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
    return await handler.fetch(req);
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
/// gesperrt ist. Akzeptiert `Authorization: Bearer tvk_…` (so steht es in der
/// App-Anleitung), aus Toleranz auch ohne "Bearer " oder als `X-Teach-Key`.
async function authenticate(req: Request): Promise<string | null> {
  const key = extractKey(req);
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

function extractKey(req: Request): string | null {
  const explicit = req.headers.get("x-teach-key")?.trim();
  if (explicit) return explicit;

  const auth = req.headers.get("authorization")?.trim();
  if (!auth) return null;
  return auth.toLowerCase().startsWith("bearer ") ? auth.slice("bearer ".length).trim() : auth;
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
        "Zeigt alle Ordner und Unterordner des Nutzers mit IDs, Kartenanzahl und freien Plätzen. Immer zuerst aufrufen, bevor Karten angelegt werden.",
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
        const folderFree = Math.max(0, MAX_FLASHCARDS_PER_FOLDER - folderTotal);
        return {
          id: folder.id,
          name: folder.name,
          karten_gesamt: folderTotal,
          freie_plaetze_im_ordner: folderFree,
          unterordner: own.map((s) => {
            const count = cardsPerSubfolder.get(s.id) ?? 0;
            return {
              id: s.id,
              name: s.name,
              karten: count,
              // Effektiv frei: Unterordner- UND Ordner-Limit gelten beide.
              freie_plaetze: Math.min(Math.max(0, MAX_FLASHCARDS_PER_SUBFOLDER - count), folderFree),
            };
          }),
        };
      });

      if (ordner.length === 0) {
        return textResult({
          ordner: [],
          hinweis: "Der Nutzer hat noch keinen Ordner. Ordner lassen sich nur in der App anlegen.",
        });
      }
      return textResult({
        ordner,
        limits: { karten_pro_unterordner: MAX_FLASHCARDS_PER_SUBFOLDER, karten_pro_ordner: MAX_FLASHCARDS_PER_FOLDER },
      });
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
        freie_plaetze: await freeSlots(userId, subfolder, cards.length),
      });
    })
  );

  // --- Neu anlegen ---------------------------------------------------------

  server.registerTool(
    "create_subfolder",
    {
      title: "Unterordner anlegen",
      description: "Legt in einem bestehenden Ordner einen neuen, leeren Unterordner an und gibt seine ID zurück.",
      inputSchema: z.object({
        folder_id: z.uuid().describe("ID des Ordners aus list_library"),
        name: z.string().trim().min(1).max(MAX_SUBFOLDER_NAME_LENGTH).describe("Name des neuen Unterordners"),
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
        freie_plaetze: await freeSlots(userId, created, 0),
      });
    })
  );

  server.registerTool(
    "add_flashcards",
    {
      title: "Karteikarten anlegen",
      description: `Legt neue Karteikarten in einem Unterordner an (1-${MAX_FLASHCARDS_PER_SUBFOLDER} pro Aufruf). Passt die Menge nicht in die freien Plätze, wird nichts angelegt. Fragen, die es im Unterordner schon gibt, werden übersprungen.\n\n${CARD_STYLE_GUIDE}`,
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
          .max(MAX_FLASHCARDS_PER_SUBFOLDER),
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

      const free = await freeSlots(userId, subfolder, existingCards.length);
      if (toInsert.length === 0) {
        return textResult({ angelegt: 0, uebersprungen_weil_schon_vorhanden: skipped, freie_plaetze: free });
      }
      if (toInsert.length > free) {
        return errorResult(
          `Nichts angelegt: ${toInsert.length} neue Karten passen nicht, im Unterordner "${subfolder.name}" sind nur noch ${free} Plätze frei ` +
            `(höchstens ${MAX_FLASHCARDS_PER_SUBFOLDER} pro Unterordner und ${MAX_FLASHCARDS_PER_FOLDER} pro Ordner). ` +
            `Lege höchstens ${free} Karten an oder nutze einen anderen Unterordner.`
        );
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

      try {
        await serviceRest<null>("flashcards", { method: "POST", body: rows, prefer: "return=minimal" });
      } catch (err) {
        // Der Limit-Trigger meldet sich mit "Maximal …" (z.B. wenn parallel
        // in der App Karten dazugekommen sind). Der Insert ist atomar: es
        // wurde dann gar nichts gespeichert.
        if (err instanceof ServiceRestError && err.body.includes("Maximal")) {
          return errorResult(`Nichts angelegt: ${extractDbMessage(err.body)}`);
        }
        throw err;
      }

      return textResult({
        angelegt: toInsert.length,
        unterordner: subfolder.name,
        karten_im_unterordner: existingCards.length + toInsert.length,
        freie_plaetze: free - toInsert.length,
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

/// Freie Plätze im Unterordner, wenn er aktuell `subfolderCount` Karten hat:
/// das Minimum aus Unterordner-Limit und Ordner-Gesamtlimit.
async function freeSlots(userId: string, subfolder: SubfolderRow, subfolderCount: number): Promise<number> {
  const siblings = await serviceRest<{ id: string }[]>(
    `subfolders?folder_id=eq.${subfolder.folder_id}&user_id=eq.${userId}&select=id`
  );
  let folderTotal = 0;
  if (siblings.length > 0) {
    const ids = siblings.map((s) => s.id).join(",");
    const folderCards = await serviceRest<{ subfolder_id: string }[]>(
      `flashcards?user_id=eq.${userId}&subfolder_id=in.(${ids})&select=subfolder_id`
    );
    folderTotal = folderCards.length;
  }
  const subfolderFree = MAX_FLASHCARDS_PER_SUBFOLDER - subfolderCount;
  const folderFree = MAX_FLASHCARDS_PER_FOLDER - folderTotal;
  return Math.max(0, Math.min(subfolderFree, folderFree));
}

function normalize(text: string): string {
  return text.trim().replace(/\s+/g, " ").toLowerCase();
}

/// PostgREST liefert Fehler als JSON mit `message` -- nur die lesbare
/// Trigger-Meldung an Claude weitergeben.
function extractDbMessage(body: string): string {
  try {
    const parsed = JSON.parse(body);
    if (typeof parsed?.message === "string") return parsed.message;
  } catch {
    // kein JSON
  }
  return "Karten-Limit erreicht.";
}

function jsonResponse(body: unknown, status: number): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}
