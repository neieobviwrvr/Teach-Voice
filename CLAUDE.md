# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Working with the project owner

Address the project owner as **Simon** in every substantial response or question (not every single short reply, but any real answer or question deserves it). This is an explicit standing instruction from Simon himself, not a stylistic guess.

## What this is

Teach (Voice): a native SwiftUI iOS app for voice-based flashcard studying. The question is read aloud via on-device TTS, the user answers out loud, the answer is transcribed on-device (Whisper) and then graded for semantic correctness against a written model answer via a cloud LLM call. Folders → subfolders → flashcards, backed by Supabase, with an offline-only guest mode as an alternative to logging in.

There is **no local Mac/Xcode available in this dev environment** — the app has never been compiled locally. The only way to actually build it is the GitHub Actions workflow described below.

## Commands

There is no local build/test/lint loop in this environment (Windows, no Xcode). What exists:

- **Regenerate the Xcode project** from `project.yml` (requires macOS + [XcodeGen](https://github.com/yonaskolb/XcodeGen)): `xcodegen generate`, then `open TeachVoice.xcodeproj`. The `.xcodeproj` itself is generated, not checked in.
- **No test target is configured yet** in `project.yml` — there are no unit tests to run.
- **No linter is configured** (no SwiftLint config in the repo).
- **Apply a Supabase migration**: files in `supabase/migrations/*.sql` are applied by hand via the Supabase Management API (`POST /v1/projects/{ref}/database/query` with a personal access token), not via `supabase db push`. Project ref: `rvpisoibtqxxxpgjdhff`.
- **Deploy the Edge Function**: `supabase login --token <PAT>` → `supabase link --project-ref rvpisoibtqxxxpgjdhff` → `supabase functions deploy grade-answer --project-ref rvpisoibtqxxxpgjdhff`. Set its secret with `supabase secrets set OPENAI_API_KEY=... --project-ref rvpisoibtqxxxpgjdhff`.
- **Build the IPA**: GitHub Actions workflow `.github/workflows/build-ipa.yml`, trigger type `workflow_dispatch` only.

**Never trigger the IPA build or deploy the Edge Function/migrations proactively.** Only do so on the user's explicit, in-the-moment command — this is a standing rule for this project, not a one-off preference.

## Architecture

### Repository abstraction (the central pattern in this codebase)

`LibraryStore` (an `ObservableObject`, injected into views via `@EnvironmentObject`) is the only thing views talk to for folder/subfolder/flashcard CRUD. It knows nothing about where data actually lives — it delegates every operation to a `LibraryRepository` protocol (`Core/LibraryRepository.swift`), which has two implementations:

- `RemoteLibraryRepository` — Supabase-backed, used when logged in by email/password. Talks to PostgREST directly (see below).
- `LocalLibraryRepository` — on-device only, used in guest mode. Persists a JSON snapshot to the app's Application Support directory; nothing ever leaves the device.

`RootView` owns the decision of which repository is active, switching it via `LibraryStore.useRepository(_:)` based on `AuthManager.isAuthenticated` / `AuthManager.isGuest`. Adding a new data-bearing feature almost always means adding a method to `LibraryRepository` and implementing it in *both* repositories — guest mode is not a second-class afterthought, it's meant to stay at parity with cloud mode.

### No Supabase SDK

Auth (`Core/AuthManager.swift`) and data access (`Core/SupabaseRestClient.swift`) are both hand-rolled REST clients against Supabase's GoTrue and PostgREST HTTP APIs — the `supabase-swift` SPM package is deliberately not used. This was a choice to minimize Swift Package Manager dependency surface, since the first real compile of this project happens blind on a CI runner with no chance to iterate locally first. The only external SPM dependency in `project.yml` is [WhisperKit](https://github.com/argmaxinc/WhisperKit).

Session tokens are stored in the Keychain (`Core/Keychain.swift`), not `UserDefaults`.

### STT/TTS

- TTS: `Services/SpeechService.swift` wraps `AVSpeechSynthesizer` — native, offline, no API calls.
- STT: `Services/WhisperTranscriber.swift` wraps WhisperKit, which downloads and runs the Whisper **base** model on-device (CoreML) on first use. Recording itself goes through `Services/AudioRecorder.swift` (16kHz mono WAV, the format WhisperKit expects).

### Answer grading (the other major subsystem)

`StudyView` sends the STT transcript to `Services/GradingService.swift`, which calls the Supabase Edge Function `supabase/functions/grade-answer/index.ts` (Deno/TypeScript, GPT-4o-mini). Two things about this function are load-bearing and easy to break if "simplified" later:

1. **It is deliberately stateless** — it never touches the Supabase database. It takes `question` + `answer` (model answer) + optional cached `kernelemente` (atomic claims already extracted from the model answer) + the STT transcript, and returns the claims used plus a grading verdict. This is what lets grading work identically for cloud flashcards *and* guest (local-only, never-in-Supabase) flashcards — a stateful, DB-reading function would only work for the former.
2. **The extraction cache lives client-side, not in the function.** The client hashes the model answer text (`Core/TextHash.swift`, SHA-256) and compares it to the last hash it cached alongside the extracted claims (`Flashcard.kernelemente` / `kernelemente_source_hash` — Supabase columns for cloud cards via `RemoteLibraryRepository.updateFlashcardGradingCache`, plain struct fields for guest cards via `LocalLibraryRepository`). Only on a cache miss does the client omit `kernelemente` from the request, which makes the function do the (paid) extraction call. This lazy caching is what keeps the OpenAI request count down given how tight the API rate limits are on a fresh account tier.

The OpenAI API key exists only as a Supabase Edge Function secret (`OPENAI_API_KEY`) — never in client code or in this repo. Grading judgment thresholds (65% claim coverage = "richtig", 40% = "teilweise", below = "falsch") are named constants at the top of `index.ts`, explicitly still provisional/tunable, and are re-validated server-side from `deckung_prozent` regardless of what the model claims its own verdict is.

`gpt-4o-mini` is used deliberately despite not appearing on OpenAI's current "flagship models" pricing table — it's still fully supported (own model page, unchanged pricing, generous Tier-1 rate limits) and just isn't part of the newest marketing lineup. Don't "helpfully" swap it for a GPT-5.x model without checking with the user first.

### Data model / RLS

`folders` → `subfolders` → `flashcards` (question/answer text), one Postgres migration per change under `supabase/migrations/`. Every table has Row Level Security scoped to `auth.uid() = user_id`.

**Hard limits, deliberately tight for the current starting phase** (Simon called these explicit starting values, not a final ceiling — expect them to loosen later): max 1 folder per user, max 2 subfolders per folder, max 10 flashcards per subfolder. Named constants in `Models.swift` (`maxFoldersPerUser`, `maxSubfoldersPerFolder`, `maxFlashcardsPerSubfolder`). Each is enforced *twice* — a Postgres trigger (`enforce_folder_limit` / `enforce_subfolder_limit` / `enforce_flashcard_limit`, cloud mode, see `supabase/migrations/0003_tighter_limits.sql`) and an equivalent check inside `LocalLibraryRepository` (guest mode) — keep both sides in sync if any of these limits change. `LibraryStore` also does a client-side pre-check for immediate UI feedback before ever calling the repository.

Both folders and subfolders are renameable (context menu / swipe in their list views); flashcards are editable in place (tap opens `AddFlashcardSheet` pre-filled, reusing the same sheet used for creation). Editing a flashcard's model answer is exactly the case the STT-grading lazy-cache (`kernelemente_source_hash`) exists to catch — no extra invalidation code needed, the next review just naturally misses the cache and re-extracts.

### CI / distribution

There is no Apple Developer account and no signing certificate anywhere in this project. `.github/workflows/build-ipa.yml` builds an **unsigned** archive on a macOS runner and manually zips the `.app` into an IPA structure; [Sideloadly](https://sideloadly.io/) re-signs it with the user's own Apple ID at install time. Don't add code-signing/export-options logic — that's a solved-differently problem here, not a missing piece.

### Deployment target

`project.yml` targets iOS 17.0. This isn't arbitrary — `ContentUnavailableView` and the two-parameter `onChange(of:)` overload are used throughout the views and both require iOS 17. Lowering the deployment target back to 16 would break the build.
