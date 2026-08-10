# Teach (Voice)

iOS-App (SwiftUI) für sprachbasiertes Karteikarten-Lernen an der Uni:
- **TTS**: Frage wird über `AVSpeechSynthesizer` (nativ, offline, kostenlos) vom Gerät vorgelesen.
- **STT**: Antwort wird per **Whisper-base** (lokal, on-device via [WhisperKit](https://github.com/argmaxinc/WhisperKit)/CoreML) transkribiert – kein Server-Roundtrip für die Spracherkennung.
- **Backend**: [Supabase](https://supabase.com) (Postgres + Auth) – Ordner, Unterordner und Karteikarten sind je Nutzer isoliert (Row Level Security).

## Lernmodi

Zwei bewusst getrennte Modi, je nach Anwendungsfall:

- **Detail** (Button in einem Unterordner): visuell, zeigt KI-Feedback (Deckung, fehlende Kernelemente, Musterantwort) und lässt dich am Ende per Buttons selbst einschätzen (richtig/teilweise/falsch) – die KI-Einschätzung ist nur ein vorbelegter Vorschlag.
- **Hands-free** (Button auf dem Homescreen → Pop-up mit allen Unterordnern + "Alle Unterordner"-Option inkl. Kartenanzahl): rein audio-getrieben. Frage wird vorgelesen → nach 1,5s öffnet sich automatisch das Mikrofon → Aufnahme endet nach 5s Stille (Schwelle passt sich an die Umgebungslautstärke an) oder per "Lösung abgeben"-Fallback-Button → automatische Transkription + Bewertung → kurzer Ton + haptischer Puls (2x bei richtig, 1x bei falsch) → nächste Frage. Kein Antippen nötig außer optional zum Abbrechen. Nutzt eine eigene 50%-Schwelle nur für das unmittelbare Ton-Feedback (getrennt von der 65%/45%-Schwelle für die Spaced-Repetition-Einordnung).

Beide Modi enden mit einem **Statistik-Screen** (X von Y richtig, aufklappbare Detailliste pro Karte) und den Optionen "Unterordner wiederholen" oder "Anderen Unterordner wählen".

## Spaced Repetition

Einfaches 5-Stufen-Box-System (`Core/SpacedRepetition.swift`), Intervalle 0/1/3/7/14 Tage: richtig = eine Stufe hoch, teilweise = Stufe bleibt gleich, falsch = zurück auf Stufe 1. Signalquelle je Karte:

- **Detail-Modus**: immer die Selbsteinschätzung des Users (maßgeblich, nicht die KI).
- **Hands-free-Modus** (keine Selbsteinschätzung möglich): GPTs `deckung_prozent`, gemappt auf dasselbe 3-Stufen-Schema (≥65% richtig, 45–64% teilweise, <45% falsch).

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
