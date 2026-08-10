# Teach (Voice)

iOS-App (SwiftUI) für sprachbasiertes Karteikarten-Lernen an der Uni:
- **TTS**: Frage wird über `AVSpeechSynthesizer` (nativ, offline, kostenlos) vom Gerät vorgelesen.
- **STT**: Antwort wird per **Whisper-base** (lokal, on-device via [WhisperKit](https://github.com/argmaxinc/WhisperKit)/CoreML) transkribiert – kein Server-Roundtrip für die Spracherkennung.
- **Backend**: [Supabase](https://supabase.com) (Postgres + Auth) – Ordner, Unterordner und Karteikarten sind je Nutzer isoliert (Row Level Security).

## Lernmodi

Drei bewusst getrennte Modi, je nach Anwendungsfall:

- **Detail** (Button in einem Unterordner): visuell, zeigt KI-Feedback (Deckung, fehlende Kernelemente, Musterantwort) und lässt dich per Buttons selbst einschätzen (richtig/teilweise/falsch) – ein Tap navigiert direkt zur nächsten Karte. Die KI-Einschätzung ist nur ein vorbelegter Vorschlag.
- **Hands-free (Voice only)** (Button auf dem Homescreen): komplett sprachgesteuertes Menü (`HandsFreeStudyView`) – die App fragt selbst per TTS, welchen Unterordner man lernen will, zählt alle Unterordner auf, hört per Mikrofon zu (lokaler Zahl-/Namensabgleich, kein GPT-Call, siehe Memory `handsfree-voice-menu-folder-matching`). Danach: Frage vorlesen → 1,5s Pause → Mikrofon öffnet automatisch → Aufnahme endet nach 3s Stille NACH dem ersten erkannten Sprechen (eine Denkpause vor dem ersten Wort zählt bewusst nicht mit, passt sich sonst an Umgebungslautstärke an) oder per "Lösung abgeben" → Transkription+Bewertung → Ton + Vibration (richtig/falsch; "teilweise" bekommt bewusst keinen Ton, nur 1s Extra-Stille) → Musterantwort erscheint zusätzlich auf dem Display → 2,5s Pause → nächste Frage. Am Ende: Statistik wird **gleichzeitig vorgelesen und angezeigt**, Weiterlernen läuft per Ja/Nein-Sprachabfrage (mit Retry + sichtbarem Pop-up-Fallback bei Unklarheit); zusätzlich ein "Anderen Unterordner wählen"-Button und "Zurück zum Homescreen".
- **Hands-free lernen (Eigenbewertung)** (zweiter Homescreen-Button, `HandsFreeSelfAssessmentStudyView`): Frage/Aufnahme laufen automatisch wie bei Voice-only, aber nach der Bewertung erscheinen die drei Selbsteinschätzungs-Buttons und die Schleife wartet auf einen Tap (kein Ton) – die Selbsteinschätzung ist das maßgebliche Spaced-Repetition-Signal; auch hier erscheint die Musterantwort nach der Bewertung zusätzlich auf dem Display. Unterordner-Auswahl und Rundenabschluss laufen bewusst über das **sichtbare Pop-up** (inkl. "Alle Unterordner lernen"-Option mit Kartenanzahl) statt über ein Sprachmenü, da man hier ohnehin pro Frage antippen muss; die Statistik wird trotzdem zusätzlich vorgelesen.

Alle drei Modi enden mit einem **Statistik-Screen** (X von Y richtig, aufklappbare Detailliste pro Karte via `SessionSummaryView`).

## Bewertungs-Strenge (Normal / Tryhard)

Vor jeder Lernsession (Detail wie Hands-free) wählt man `Core/GradingStrictness.swift`: **Normal** (≥65% Deckung = richtig, ≥45% = teilweise) oder **Tryhard** (≥85% / ≥65%, nur präzise vollständige Antworten zählen). Bewusst **pro Session frei wählbar, nicht global fix** (Simons Entscheidung) – das bedeutet, dieselbe Karte kann je nach gewähltem Modus unterschiedlich in die Spaced-Repetition-Box einsortiert werden. Diese eine Einstellung steuert einheitlich: die Selbsteinschätzungs-Vorbelegung im Detail-Modus, den Erfolgs-/Fehler-Ton im Hands-free-Modus, und das Spaced-Repetition-Signal in beiden Modi.

## Spaced Repetition

Einfaches 5-Stufen-Box-System (`Core/SpacedRepetition.swift`), Intervalle 0/1/3/7/14 Tage: richtig = eine Stufe hoch, teilweise = Stufe bleibt gleich, falsch = zurück auf Stufe 1. Signalquelle je Karte:

- **Detail-Modus**: immer die Selbsteinschätzung des Users (maßgeblich, nicht die KI).
- **Hands-free-Modus** (keine Selbsteinschätzung möglich): GPTs `deckung_prozent`, gemappt über `GradingStrictness` auf dasselbe 3-Stufen-Schema.

Der Hands-free-Modus sortiert Karten nach Fälligkeit (fällige/überfällige zuerst, dann nie bewertete, dann noch nicht fällige) – ausschließlich Reihenfolge, keine Karte wird ausgeschlossen. Der Detail-Modus bleibt unsortiert (Original-Reihenfolge).

## Struktur

- Ordner (Ober-Ordner, umbenennbar) → Unterordner (umbenennbar) → Karteikarten (Frage + Antwort, nachträglich bearbeitbar).
- **Harte Limits für die Startphase** (ausdrücklich vorläufig, siehe `Models.swift`): max. **1 Ober-Ordner** pro Nutzer, max. **2 Unterordner** pro Ober-Ordner, max. **10 Karteikarten** pro Unterordner. Jeweils per DB-Trigger (Cloud) und Repository-Check (Gastmodus) durchgesetzt, siehe `supabase/migrations/0003_tighter_limits.sql`.
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
  Views/                            # Auth, Folders, Flashcards, StudyView (Lernmodus)
.github/workflows/build-ipa.yml     # Manueller (workflow_dispatch) macOS-Runner-Build -> unsignierte IPA
supabase/migrations/0001_init.sql   # DB-Schema, RLS, 20-Karten-Limit
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

Grundgerüst steht: Auth (E-Mail/Passwort), Ordner → Unterordner → Karteikarten (max. 20/Unterordner) mit Supabase-Anbindung,
TTS-Vorlesen der Frage, STT-Lernmodus mit lokalem Whisper-base. Noch ungetestet, da kein Mac zum Kompilieren verfügbar war –
der erste echte Build läuft über die GitHub-Actions-Pipeline, ausgelöst auf explizites Kommando.
