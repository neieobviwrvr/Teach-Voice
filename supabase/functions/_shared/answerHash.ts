// supabase/functions/_shared/answerHash.ts
//
// Hash der Musterantwort, unter dem die Kontrollpunkte einer Karte
// gespeichert werden (`flashcards.kernelemente_source_hash`). MUSS exakt zu
// `Sources/TeachVoice/Core/TextHash.swift` passen: SHA-256 über die
// getrimmte Antwort als UTF-8, klein geschriebenes Hex. Nur dann erkennt die
// App die von Claude mitgelieferten Kontrollpunkte als gültig und schickt
// sie bei der Bewertung mit, statt sie neu extrahieren zu lassen.

export async function answerHash(answer: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(answer.trim()));
  return Array.from(new Uint8Array(digest))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}
