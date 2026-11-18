// supabase/functions/_shared/connectorKey.ts
//
// Erzeugen und Hashen der persönlichen Konnektor-Schlüssel (siehe
// supabase/migrations/0012_connector_keys.sql). Genutzt von `connector-key`
// (Erzeugen) und `teach-mcp` (Prüfen).

export const CONNECTOR_KEY_PREFIX = "tvk_";

/// 32 Zufallsbytes = 256 Bit, base64url ohne Padding -> immer 43 Zeichen.
const KEY_BODY_LENGTH = 43;
const KEY_PATTERN = new RegExp(`^${CONNECTOR_KEY_PREFIX}[A-Za-z0-9_-]{${KEY_BODY_LENGTH}}$`);

export function generateConnectorKey(): string {
  const bytes = new Uint8Array(32);
  crypto.getRandomValues(bytes);
  return CONNECTOR_KEY_PREFIX + base64UrlEncode(bytes);
}

/// Schneller Formatcheck VOR dem DB-Lookup -- offensichtlich kaputte oder
/// fremde Header verursachen so gar nicht erst eine Datenbankabfrage.
export function looksLikeConnectorKey(value: string): boolean {
  return KEY_PATTERN.test(value);
}

/// SHA-256 als Hex. Reicht hier (statt bcrypt & Co.), weil der Schlüssel
/// 256 Bit echten Zufall enthält -- es gibt nichts, was man per Wörterbuch
/// oder Brute Force erraten könnte.
export async function hashConnectorKey(key: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(key));
  return Array.from(new Uint8Array(digest))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

/// Die ersten Zeichen, damit die App "tvk_AbCdEf…" anzeigen kann, ohne den
/// ganzen Schlüssel zu kennen.
export function displayPrefix(key: string): string {
  return key.slice(0, CONNECTOR_KEY_PREFIX.length + 6);
}

function base64UrlEncode(bytes: Uint8Array): string {
  let binary = "";
  for (const b of bytes) binary += String.fromCharCode(b);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}
