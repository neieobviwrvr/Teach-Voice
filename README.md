# Teach (Voice)

iOS-App (SwiftUI) für sprachbasiertes Karteikarten-Lernen an der Uni:
- **TTS**: Frage wird primär mit einer Google-Cloud-WaveNet-Stimme vorgelesen (Edge Function `text-to-speech`, mit hartem Ausgabendeckel). Ohne Netz oder bei Problemen springt `AVSpeechSynthesizer` ein (nativ, offline, kostenlos).
- **STT**: Antwort wird per **Whisper-base** (lokal, on-device via [WhisperKit](https://github.com/argmaxinc/WhisperKit)/CoreML) transkribiert – kein Server-Roundtrip für die Spracherkennung.
- **Backend**: [Supabase](https://supabase.com) (Postgres + Auth) – Ordner, Unterordner und Karteikarten sind je Nutzer isoliert (Row Level Security).

## Lernmodi

Zwei Modi (Simons MVP-Entscheidung). Gestartet wird über den „Lernen“-Button auf dem Homescreen (Mindmap-Pille für einen Unterordner oder „Ganzer Ordner“), über „Ganzen Ordner lernen“ in einem Ordner oder über „Lernen“ in einem Unterordner. Danach fragt ein Dialog den Modus ab (`Views/Study/StudyLauncher.swift`):

- **Sprechen** (`VoiceStudyView`, früher „Hands-free mit Eigenbewertung“): Frage wird vorgelesen → Signalton → Mikrofon geht von selbst an → Aufnahme endet nach **8 s Stille** nach dem ersten Wort (Denkpausen davor zählen nicht; Sicherheitsnetz 90 s) oder per „Fertig“ → Whisper transkribiert → KI prüft die Kernthemen → ist die Antwort laut Zielnote nicht richtig, wird eine **Kurzlösung** (1–2 Sätze, Schwerpunkt auf dem, was gefehlt hat) vorgelesen und groß angezeigt, die ganze Musterantwort lässt sich aufklappen → man tippt Falsch/Teilweise/Richtig (der KI-Vorschlag ist hervorgehoben) → nächste Frage. Wird nichts erkannt oder ist die KI nicht erreichbar, sieht man die Musterantwort und bewertet selbst – die Karte geht nicht verloren.
- **Tippen (Anki-Stil)** (`AnkiStudyView`): Frage lesen (optional vorlesen lassen) → „Antwort zeigen“ → Falsch/Teilweise/Richtig. Kein Mikrofon, keine KI, keine Kosten.

Beide Modi enden mit einem **Statistik-Screen** (`Views/Study/SessionSummaryView.swift`): wie viele Karten auf Anhieb richtig/teilweise/falsch waren, wie viele Wiederholungen nötig waren, Detailliste, „Alle Karten nochmal üben“.

## Bewertung im Sprach-Modus (Zielnote)

Die KI (`grade-answer`) zerlegt die Musterantwort in Kernthemen und prüft jedes **sinngemäß** – andere Worte, umgangssprachlich statt Fachbegriff und Erkennungsfehler von Whisper zählen trotzdem. Heraus kommt, wie viel Prozent der Kernthemen getroffen wurden.

Die **Zielnote** (Profil → „Bewertung im Sprach-Modus“, `Core/Zielnote.swift`, Standard 2,3) legt fest, ab wie viel Prozent eine Antwort als richtig gilt: linear 15 Prozentpunkte pro Notenstufe (1,0 → 95 %, 2,0 → 80 %, 3,0 → 65 %, 4,0 → 50 %), „teilweise“ jeweils 20 Punkte darunter. Sie steuert den hervorgehobenen KI-Vorschlag und ob die Kurzlösung vorgelesen wird. Wie großzügig die Kernthemen erkannt werden, ändert sie nicht.

## Spaced Repetition

Einfaches 5-Stufen-Box-System (`Core/SpacedRepetition.swift`), Intervalle 0/1/3/7/14 Tage: richtig = eine Stufe hoch, teilweise = Stufe bleibt gleich, falsch = zurück auf Stufe 1. Signal ist in beiden Modi immer die **Selbsteinschätzung** (im Sprach-Modus von der KI nur vorgeschlagen).

Eine Session (`Core/StudyQueue.swift`) fragt nur **fällige und neue** Karten ab (ist nichts fällig, werden alle geübt). Landet eine Karte nach der Bewertung in Box 1 (0 Tage), kommt sie **in derselben Session hinten wieder dran**, bis sie sitzt.

## KI-Konnektor (Claude)

Claude kann über einen eigenen MCP-Konnektor (Edge Function `supabase/functions/teach-mcp`) direkt Ordner, Unterordner und Karteikarten in die eigene Teach-Bibliothek schreiben, z.B. „Mach mir 10 Karten zu Kapitel 3 in den Unterordner Sozialpsychologie“. Die App zeigt die neuen Karten beim nächsten Laden an (auch automatisch beim Zurückwechseln in die App).

- **Einrichten**: In der App unter Profil → KI-Konnektor einen persönlichen Schlüssel erzeugen. In Claude unter Einstellungen → Konnektoren einen eigenen Konnektor mit der angezeigten URL anlegen und als Request-Header `Authorization: Bearer <Schlüssel>` eintragen. Im kostenlosen Claude-Abo ist ein eigener Konnektor möglich.
- **Was Claude darf**: Bibliothek und vorhandene Karten lesen, neue Ordner, Unterordner und Karten anlegen (höchstens 50 Karten pro Aufruf). Ändern oder Löschen geht bewusst nur in der App.
- **Nur mit Konto**: Gast-Karten liegen ausschließlich auf dem iPhone, dort kommt der Konnektor nicht hin.
- **Sicherheit**: Gespeichert wird nur ein Hash des Schlüssels (`connector_keys`, siehe `supabase/migrations/0012_connector_keys.sql`). Ein neuer Schlüssel ersetzt den alten, gesperrte Schlüssel wirken sofort. Für fremde Nutzer oder ChatGPT ist später OAuth statt Schlüssel vorgesehen.

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
supabase/functions/                 # Edge Functions (grade-answer, text-to-speech, teach-mcp, …)
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
