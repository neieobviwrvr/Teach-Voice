# Teach (Voice)

iOS-App (SwiftUI) für sprachbasiertes Karteikarten-Lernen an der Uni:
- **TTS**: Frage wird primär mit einer Google-Cloud-WaveNet-Stimme vorgelesen (Edge Function `text-to-speech`, mit hartem Ausgabendeckel). Ohne Netz oder bei Problemen springt `AVSpeechSynthesizer` ein (nativ, offline, kostenlos).
- **STT**: Antwort wird per **Whisper-base** (lokal, on-device via [WhisperKit](https://github.com/argmaxinc/WhisperKit)/CoreML) transkribiert – kein Server-Roundtrip für die Spracherkennung.
- **Backend**: [Supabase](https://supabase.com) (Postgres + Auth) – Ordner, Unterordner und Karteikarten sind je Nutzer isoliert (Row Level Security).

## Lernmodi

Zwei Modi (Simons MVP-Entscheidung). Gestartet wird über den „Lernen“-Button auf dem Homescreen (Mindmap-Pille für einen Unterordner oder „Ganzer Ordner“), über „Ganzen Ordner lernen“ in einem Ordner oder über „Lernen“ in einem Unterordner. Danach fragt ein Dialog den Modus ab (`Views/Study/StudyLauncher.swift`):

- **Sprechen** (`VoiceStudyView`, früher „Hands-free mit Eigenbewertung“): Frage wird vorgelesen → Signalton → Mikrofon geht von selbst an → Aufnahme endet nach **8 s Stille** nach dem ersten Wort (Denkpausen davor zählen nicht; Sicherheitsnetz 90 s) oder per „Fertig“. Wer länger nachdenken will, **hält den Kreis unten gedrückt**: Solange gehalten wird, läuft das Mikrofon ohne 8-Sekunden-Grenze weiter (bis 5 min), der Kreis lässt sich dabei über das Display ziehen, und **Loslassen wertet sofort aus** (kurzes Antippen zählt nicht). Ziehst du den Kreis an einen **Bildschirmrand** (egal welcher), wird er rot. Lässt du dort los, wird die Karte **übersprungen und die Lösung gezeigt**: Die Karte dreht sich, zählt als falsch, und mit „Weiter“ geht es zur nächsten Frage. Weißt du nicht, worum es geht, **tippst du auf die Frage**: Die Karte dreht sich um und zeigt die Antwort mit Falsch/Teilweise/Richtig, ohne Aufnahme und ohne KI. Die Frage wird dabei zu Ende vorgelesen, bis du bewertest. **„Überspringen“** (statt „Beenden“, in beiden Modi) wertet die Karte als falsch und macht sofort weiter, beendet wird über den Zurück-Pfeil → Whisper transkribiert → KI prüft die Kernthemen → ist die Antwort laut Zielnote nicht richtig, wird eine **Kurzlösung** (1–2 Sätze, Schwerpunkt auf dem, was gefehlt hat) vorgelesen und groß angezeigt, die ganze Musterantwort lässt sich aufklappen → man tippt Falsch/Teilweise/Richtig (der KI-Vorschlag ist hervorgehoben) → nächste Frage. Wird nichts erkannt oder ist die KI nicht erreichbar, sieht man die Musterantwort und bewertet selbst – die Karte geht nicht verloren.
- **Tippen (Anki-Stil)** (`AnkiStudyView`, Vorbild Anki/StudyFlash): oben die Zähler Neu · Nochmal · Wiederholen, Karte antippen zum Umdrehen, dann **Nochmal / Schwer / Gut / Einfach** – jeder Button zeigt, wann FSRS die Karte bei dieser Bewertung wieder bringt. Kein Mikrofon, keine KI, keine Kosten.

Beim Start wählst du für beide Modi: **Spaced Repetition** (nur fällige und neue Karten) oder **alle Karten am Stück**. Beide Modi arbeiten mit denselben Karten und demselben FSRS-Lernstand – eine Bewertung im Sprach-Modus zählt genauso für den Tipp-Modus und umgekehrt.

Beide Modi enden mit einem **Statistik-Screen** (`Views/Study/SessionSummaryView.swift`): wie viele Karten auf Anhieb richtig/teilweise/falsch waren, wie viele Wiederholungen nötig waren, Detailliste, „Alle Karten nochmal üben“.

## Bewertung im Sprach-Modus (Zielnote)

Jede Karte hat **Kontrollpunkte**: die Aussagen, die eine vollständig richtige Antwort enthalten muss. Karten, die Claude über den Konnektor anlegt, bringen sie **verpflichtend** mit (Claude legt sie beim Schreiben fest, ohne Überschneidungen). Nur bei selbst geschriebenen oder per PDF importierten Karten leitet GPT sie einmalig selbst ab.

Die KI (`grade-answer`) prüft **jeden Kontrollpunkt einzeln** – getroffen, teilweise oder fehlt – und muss dafür eine Stelle aus der gesprochenen Antwort zitieren. Sinngemäß reicht: andere Worte, umgangssprachlich statt Fachbegriff und Erkennungsfehler von Whisper zählen trotzdem, und eine Aussage kann mehrere Punkte erfüllen. Die Prozentzahl rechnet der Server aus den Einzelurteilen aus (teilweise = halber Punkt), und die App zeigt die Punkte als Checkliste. Die Kurzlösung nennt nur, was gefehlt hat.

Die **Zielnote** (Profil → „Bewertung im Sprach-Modus“, `Core/Zielnote.swift`, Standard 2,3) legt fest, ab wie viel Prozent eine Antwort als richtig gilt: linear 15 Prozentpunkte pro Notenstufe (1,0 → 95 %, 2,0 → 80 %, 3,0 → 65 %, 4,0 → 50 %), „teilweise“ jeweils 20 Punkte darunter. Sie steuert den hervorgehobenen KI-Vorschlag und ob die Kurzlösung vorgelesen wird. Wie großzügig die Kontrollpunkte erkannt werden, ändert sie nicht.

## Spaced Repetition

**FSRS-6** (`Core/FSRS.swift`) – derselbe Algorithmus wie in Anki, 1:1 nach der offiziellen Referenzimplementierung (py-fsrs) und per Tests gegen Referenzwerte abgesichert. FSRS merkt sich pro Karte **Stabilität** (nach wie vielen Tagen du sie mit 90 % Wahrscheinlichkeit noch weißt) und **Schwierigkeit** und plant die nächste Wiederholung genau dann, wenn die Abrufwahrscheinlichkeit auf 90 % fällt. Signal ist in beiden Modi die **Selbsteinschätzung**: Falsch = Again, Teilweise = Hard, Richtig = Good (im Sprach-Modus schlägt die KI sie nur vor). Die Buttons zeigen, wann die Karte bei der jeweiligen Bewertung wiederkommt.

Eine Lernrunde (`Core/StudyQueue.swift`) fragt nur **fällige und neue** Karten ab (ist nichts fällig, werden alle geübt). Falsche Karten kommen **in derselben Runde hinten wieder dran**, bis sie sitzen. Ein Lerntag beginnt um 4 Uhr (wie in Anki).

**Prüfungstermin** (optional, pro Ordner, in der Ordner-Ansicht): Würde eine Karte erst nach der Prüfung wieder fällig, zieht die App die Wiederholung auf die Hälfte der verbleibenden Tage vor – jede Karte kommt vorher noch mindestens einmal dran, und die Abstände werden zur Prüfung hin kürzer.

## Statistik und Lernverlauf

In jedem Ordner und Unterordner gibt es **Statistik** (`Views/Study/StatisticsView.swift`, Berechnung in `Core/LearningStats.swift`):

- **Fortschritt:** „87 von 141 Karten gelernt, 54 noch neu“.
- **Wie viel du gerade weißt:** FSRS schätzt für jede gelernte Karte die Abrufwahrscheinlichkeit *jetzt*. Gemittelt über alle Karten (neue zählen als 0 %) und nur über die gelernten.
- **Fällig:** heute und in den nächsten 7 Tagen.
- **Prüfung** (mit Prüfungstermin): „Am Prüfungstag voraussichtlich 78 % abrufbar, wenn du nach Plan wiederholst“, dazu der Wert ohne weiteres Lernen.
- **Lernverlauf:** Lerntage, Serie, Bewertungen pro Tag (Diagramm der letzten 14 Tage).

Dafür wird jede Bewertung in `review_logs` protokolliert (Gastmodus: lokal im Snapshot). Das ist zugleich die Datengrundlage, um FSRS später auf das persönliche Gedächtnis zu trainieren.

**Kein Lernstand geht verloren:** Jede Bewertung wird sofort nach dem Tippen erst auf dem iPhone vorgemerkt und dann im Hintergrund gespeichert (`Core/PendingReviewQueue.swift`). Ohne Netz bleibt sie vorgemerkt und wird nachgeholt, sobald wieder Netz da ist; solange zeigt die App „… wird nachgeholt“.

## KI-Konnektor (Claude)

Claude kann über einen eigenen MCP-Konnektor (Edge Function `supabase/functions/teach-mcp`) direkt Ordner, Unterordner und Karteikarten in die eigene Teach-Bibliothek schreiben, z.B. „Mach mir 10 Karten zu Kapitel 3 in den Unterordner Sozialpsychologie“. Die App zeigt die neuen Karten beim nächsten Laden an (auch automatisch beim Zurückwechseln in die App).

- **Einrichten (einmalig)**: In der App unter Profil → KI-Konnektor den **persönlichen Claude-Link** erzeugen und kopieren (`…/functions/v1/teach-mcp/tvk_…`, der Schlüssel steckt im Link). In Claude unter Einstellungen → Konnektoren → „Eigenen Konnektor hinzufügen“ den Link als URL einfügen, sonst nichts. Danach reicht in jedem Chat „Schreib mir Karten zu X in Teach“. Im kostenlosen Claude-Abo ist ein eigener Konnektor möglich. Request-Header bietet Claude dort nur als Beta für einzelne Organisationen an, deshalb der Link; `Authorization: Bearer tvk_…` wird trotzdem weiter akzeptiert (z.B. für Claude Code).
- **Was Claude darf**: Bibliothek und vorhandene Karten lesen, neue Ordner, Unterordner und Karten anlegen (höchstens 50 Karten pro Aufruf, jede Karte mit Kontrollpunkten) und bei bestehenden Karten die Kontrollpunkte nachrüsten (`set_kontrollpunkte`, z.B. „Ergänze für alle Karten ohne Kontrollpunkte die Kontrollpunkte“). Frage und Antwort ändern oder Karten löschen geht bewusst nur in der App.
- **Nur mit Konto**: Gast-Karten liegen ausschließlich auf dem iPhone, dort kommt der Konnektor nicht hin.
- **Sicherheit**: Gespeichert wird nur ein Hash des Schlüssels (`connector_keys`, siehe `supabase/migrations/0012_connector_keys.sql`). Der Link ist so geheim wie ein Passwort; die App merkt ihn sich nur im Keychain des iPhones. Ein neuer Link ersetzt den alten, gesperrte Links wirken sofort. Für fremde Nutzer oder ChatGPT ist später OAuth statt Schlüssel vorgesehen.

## Internes Dashboard (Kosten & Analytics)

Eine eigene Webseite in [`dashboard/`](dashboard), unabhängig von der App und nur für Simon. Sie zeigt:

- **Kosten**: Google Cloud TTS in Dollar und Zeichen pro Stimmklasse (WaveNet, Chirp 3 HD), OpenAI in Token und Dollar pro Funktion (Bewertung, Extraktion, PDF-Import), Kosten pro bewerteter Antwort, Hochrechnung für den Monat, Freikontingent und den Stand des 20-$-Google-Deckels. Zeitraum 7, 30, 90 Tage oder 1 Jahr.
- **Betrieb und Missbrauch**: Fehlerquote, Gast-Aufrufe, vom Deckel blockierte Aufrufe, Extraktions-Quote und die Rate-Limit-Zähler der letzten 24 Stunden (ersetzt die manuelle SQL-Abfrage).
- **Lernen** (aus `review_logs`): Bewertungen pro Lerntag nach Modus, Notenverteilung, Ø Deckung im Sprach-Modus, Lerntage, Serie, eine Heatmap nach Wochentag und Uhrzeit sowie den Stand der Bibliothek (neu, gelernt, fällig, mit Kontrollpunkten).

**Öffnen:** `node dashboard/serve.mjs` starten, dann http://127.0.0.1:5180 aufrufen und mit dem normalen Teach-Konto anmelden. Unter http://127.0.0.1:5180/?demo gibt es erfundene Beispieldaten ohne Login.

**Schutz:** Im Browser liegt nur der öffentliche anon-Key (derselbe wie in der App). Daten liefert ausschließlich die Edge Function `admin-dashboard`. Sie prüft das Login-Token über GoTrue und lässt nur User-IDs aus dem Secret `ADMIN_USER_IDS` durch. Die SQL-Funktion `admin_dashboard()` darf nur `service_role` ausführen, und zwar nur auf dem Server. Ein service_role- oder API-Schlüssel kommt nie in den Browser.

**Woher die Kosten kommen:** aus einer eigenen Messung. `text-to-speech`, `grade-answer` und `generate-questions` schreiben nach jedem bezahlten Aufruf eine Zeile in `api_usage_events`: Zeichen bzw. Token, Preisklasse, geschätzte Kosten und Status. Inhalte und IP-Adressen werden nicht gespeichert. Siehe `supabase/migrations/0016_api_usage.sql` und `supabase/functions/_shared/usageLog.ts`; die Preise stehen zentral in `_shared/apiPricing.ts`. Das Freikontingent ist nicht abgezogen. Die offiziellen Zahlen bleiben die Google-Cloud-Konsole und das OpenAI-Usage-Dashboard. Kosten aus der Zeit vor dem Deploy lassen sich nicht nachträglich aufschlüsseln, dafür gibt es nur die Gesamtsumme des Deckels.

**Einrichten (einmalig, nur auf ausdrückliches Kommando):**

1. Migration anwenden: `supabase db query --linked --file supabase/migrations/0016_api_usage.sql`
2. Functions deployen: `supabase functions deploy text-to-speech grade-answer generate-questions admin-dashboard --project-ref rvpisoibtqxxxpgjdhff`
3. Eigene User-ID freischalten: `supabase secrets set ADMIN_USER_IDS=<user-id> --project-ref rvpisoibtqxxxpgjdhff`. Fehlt die ID noch, zeigt das Dashboard sie nach dem Login an. Mehrere IDs werden mit Komma getrennt.

## Struktur

- Ordner (Ober-Ordner, umbenennbar) → Unterordner (umbenennbar) → Karteikarten (Frage + Antwort, nachträglich bearbeitbar).
- **Keine Mengen-Limits** (MVP, vorerst nur für Simon): beliebig viele Ordner, Unterordner und Karten. Die früheren DB-Trigger entfernt `supabase/migrations/0013_remove_limits.sql`. Längen-Obergrenzen für Fragen/Antworten in den Edge Functions bleiben.
- Auth: **E-Mail + Passwort** (Supabase) **oder Gastzugang** (rein lokal, kein Konto, kein Server-Roundtrip).
  Sign in with Apple/Google folgt später (siehe Task #9) – aktuell bewusst nicht eingebaut.

### Gastzugang vs. Cloud-Login

`LibraryStore` kennt nur das `LibraryRepository`-Protokoll, nicht die konkrete Datenquelle:

| Modus | Repository | Speicherort |
|---|---|---|
| E-Mail-Login | `RemoteLibraryRepository` | Supabase (Postgres, RLS-geschützt, geräteübergreifend) |
| Gastzugang | `LocalLibraryRepository` | JSON-Datei im App-Sandbox-Verzeichnis, verlässt das Gerät nie |

`RootView` schaltet das Repository je nach `AuthManager`-Zustand (`isAuthenticated` / `isGuest`) um.

## Supabase

- Projekt-Ref: `rvpisoibtqxxxpgjdhff`
- Schema/Migrationen: [`supabase/migrations`](supabase/migrations)
- RLS ist auf allen Tabellen aktiv – jeder Nutzer sieht ausschließlich eigene Daten.

## Build

Es wird kein lokaler Mac verwendet. Die IPA wird über eine GitHub-Actions-Workflow (macOS-Runner, `xcodebuild`) **unsigniert** gebaut; [Sideloadly](https://sideloadly.io/) übernimmt die Signierung mit der eigenen Apple-ID beim Installieren.

⚠️ **Builds werden ausschließlich auf explizites Kommando ausgelöst, nie automatisch.**

## Projektstruktur

```
project.yml                        # XcodeGen-Spezifikation (erzeugt TeachVoice.xcodeproj)
Sources/TeachVoice/
  TeachVoiceApp.swift               # App-Einstiegspunkt
  Core/                             # Config, Keychain, Auth (REST gegen Supabase GoTrue), PostgREST-Client
  Models/                           # Folder, Subfolder, Flashcard (Codable)
  Stores/LibraryStore.swift         # CRUD-Logik + lokaler State für die Views
  Services/                         # SpeechService (TTS), AudioRecorder, WhisperTranscriber (STT)
  Views/                            # Auth, Folders, Flashcards, Profile, Study (Sprach- und Anki-Modus)
.github/workflows/build-ipa.yml     # Manueller (workflow_dispatch) macOS-Runner-Build -> unsignierte IPA
supabase/migrations/                # DB-Schema, RLS, eine Migration pro Änderung
supabase/functions/                 # Edge Functions (grade-answer, text-to-speech, teach-mcp, admin-dashboard, …)
dashboard/                          # Internes Kosten- und Analytics-Dashboard (statische Seite + node serve.mjs)
```

Es gibt bewusst **keine Auth-/Datenbank-SDK-Abhängigkeit** (kein `supabase-swift`) – Auth und CRUD laufen über schlanke,
selbst geschriebene REST-Aufrufe gegen GoTrue/PostgREST. Das hält die SPM-Abhängigkeiten (und damit die
Fehlerquellen beim ersten CI-Build) gering. Die einzige externe Abhängigkeit ist [WhisperKit](https://github.com/argmaxinc/WhisperKit) für lokales Whisper-base-STT.

## Lokal öffnen (falls doch mal ein Mac zur Verfügung steht)

```bash
brew install xcodegen
xcodegen generate
open TeachVoice.xcodeproj
```

## Status

MVP-Umfang: Karten entstehen per Claude-Konnektor (oder in der App bzw. per PDF-Import), liegen pro Nutzer in Supabase, sind
in der App bearbeitbar/löschbar und werden im Sprach- oder Anki-Modus mit Spaced Repetition abgefragt. Gebaut wird nur über
die GitHub-Actions-Pipeline (kein lokaler Mac), ausgelöst auf explizites Kommando. Neue Migrationen und Edge Functions
werden ebenfalls nur auf Kommando angewendet bzw. deployt.
