# Teach (Voice)

iOS-App (SwiftUI) für sprachbasiertes Karteikarten-Lernen an der Uni:
- **TTS**: Frage wird über `AVSpeechSynthesizer` (nativ, offline, kostenlos) vom Gerät vorgelesen.
- **STT**: Antwort wird per **Whisper-base** (lokal, on-device via [WhisperKit](https://github.com/argmaxinc/WhisperKit)/CoreML) transkribiert – kein Server-Roundtrip für die Spracherkennung.
- **Backend**: [Supabase](https://supabase.com) (Postgres + Auth) – Ordner, Unterordner und Karteikarten sind je Nutzer isoliert (Row Level Security).

## Struktur

- Ordner (Ober-Ordner) → Unterordner (umbenennbar) → Karteikarten (Frage + Antwort), max. 20 Karten pro Unterordner.
- Auth: E-Mail + Passwort über Supabase Auth.

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
