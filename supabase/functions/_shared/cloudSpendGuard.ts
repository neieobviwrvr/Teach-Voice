// supabase/functions/_shared/cloudSpendGuard.ts
//
// Haelt die Google-Cloud-Ausgaben strikt unter einer festen Obergrenze --
// Simons ausdrueckliche Vorgabe: "AUF GARKEINEN FALL" das ~260-Euro-
// Testguthaben ueberschreiten.
//
// Bewusst ein SELBST GEBAUTER, SOFORT wirksamer Vorab-Check statt sich auf
// Googles eigene Budget-Alerts zu verlassen -- die sind nur
// Benachrichtigungen mit spuerbarer Verzoegerung (teils Stunden), kein
// echter Stopp. Dieser Check laeuft VOR jedem einzelnen bezahlten Call,
// atomar (siehe add_cloud_spend in 0010_cloud_spend_guard.sql), nicht
// danach -- kann also nie "nachtraeglich" ueberschritten werden.
//
// CEILING_USD ist BEWUSST WEIT unter den echten ~280 USD Gegenwert von
// 260 Euro angesetzt: die hier berechneten "estimatedCostUsd"-Werte sind
// nur eine grobe Naeherung (Zeichenanzahl * bekannter Preis pro Zeichen),
// kein exakter Preis von Google, und der Umrechnungskurs Euro/Dollar
// schwankt. Diese grosse Sicherheitsmarge ist Absicht, nicht Schaetzfehler.
//
// Deckt ALLE Google-Cloud-TTS-Calls ab (aktuell text-to-speech/WaveNet,
// spaeter ggf. auch Gemini-TTS) -- beide haengen am selben Google-Cloud-
// Billing-Konto und damit am selben Guthaben, daher ein gemeinsamer
// "google_cloud"-Zaehler statt getrennter pro Function.
const CEILING_USD = 20;
const GOOGLE_CLOUD_PROVIDER = "google_cloud";

/// `true` = Call ist erlaubt (und der geschaetzte Betrag wurde bereits
/// reserviert/verbucht). `false` = entweder die Grenze wuerde ueberschritten,
/// ODER die Pruefung selbst ist technisch fehlgeschlagen -- FAIL CLOSED
/// (gleiches Prinzip wie beim Rate-Limiting in rateLimit.ts): laeuft der
/// Schutzmechanismus selbst kaputt, soll das NICHT automatisch "unbegrenzt
/// bezahlte Calls" bedeuten.
export async function checkAndReserveGoogleCloudSpend(estimatedCostUsd: number): Promise<boolean> {
  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!supabaseUrl || !serviceRoleKey) {
    console.error("Spend-Guard nicht konfiguriert (SUPABASE_URL/SERVICE_ROLE_KEY fehlt) -- lehne Call ab (fail closed).");
    return false;
  }

  try {
    const response = await fetch(`${supabaseUrl}/rest/v1/rpc/add_cloud_spend`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        apikey: serviceRoleKey,
        Authorization: `Bearer ${serviceRoleKey}`,
      },
      body: JSON.stringify({
        p_provider: GOOGLE_CLOUD_PROVIDER,
        p_amount_usd: estimatedCostUsd,
        p_ceiling_usd: CEILING_USD,
      }),
    });

    if (!response.ok) {
      console.error("Spend-Guard-Check fehlgeschlagen:", response.status, await response.text());
      return false;
    }

    const rows = (await response.json()) as Array<{ allowed: boolean; new_total: number }>;
    const allowed = rows?.[0]?.allowed;
    if (allowed !== true) {
      console.error(`Google-Cloud-Ausgabendeckel erreicht (Grenze: $${CEILING_USD}) -- Call verweigert.`);
    }
    return allowed === true;
  } catch (err) {
    console.error("Spend-Guard-Fehler:", err);
    return false;
  }
}
