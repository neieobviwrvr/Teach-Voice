# Teach (Voice)

iOS-App (SwiftUI) für sprachbasiertes Karteikarten-Lernen an der Uni:
- **TTS**: Frage wird über `AVSpeechSynthesizer` (nativ, offline, kostenlos) vom Gerät vorgelesen.
- **STT**: Antwort wird per **Whisper-base** (lokal, on-device via [WhisperKit](https://github.com/argmaxinc/WhisperKit)/CoreML) transkribiert – kein Server-Roundtrip für die Spracherkennung.
- **Backend**: [Supabase](https://supabase.com) (Postgres + Auth) – Ordner, Unterordner und Karteikarten sind je Nutzer isoliert (Row Level Security).

## Lernmodi

Zwei bewusst getrennte Modi, je nach Anwendungsfall:

- **Detail** (Button in einem Unterordner): visuell, zeigt KI-Feedback (Deckung, fehlende Kernelemente, Musterantwort) und lässt dich am Ende per Buttons selbst einschätzen (richtig/teilweise/falsch) – die KI-Einschätzung ist nur ein vorbelegter Vorschlag.
- **Hands-free** (Button auf dem Homescreen): rein audio-getrieben über alle Karten aller Unterordner hinweg. Frage wird vorgelesen → nach 1,5s öffnet sich automatisch das Mikrofon → Aufnahme endet nach 5s Stille (kürzere Sprechpausen zählen nicht) → automatische Transkription + Bewertung → kurzer Erfolgs-/Fehler-Ton (kein gesprochenes Feedback) → nächste Frage, bis zum Ende. Kein Antippen nötig außer optional zum Abbrechen. Nutzt eine eigene, großzügigere 50%-Schwelle für richtig/falsch (statt der 65%/40%-Dreistufigkeit im Detail-Modus), da hier binär entschieden werden muss.

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
