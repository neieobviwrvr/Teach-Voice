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
- **Unit tests** live in `Tests/TeachVoiceTests` (XCTest target `TeachVoiceTests` in `project.yml`). They can't run locally here; `build-ipa.yml` runs them on every CI build (`build-for-testing` + `test-without-building`) before archiving.
- **No linter is configured** (no SwiftLint config in the repo).
- **Apply a Supabase migration**: files in `supabase/migrations/*.sql` are applied by hand via the Supabase Management API (`POST /v1/projects/{ref}/database/query` with a personal access token), not via `supabase db push`. Project ref: `rvpisoibtqxxxpgjdhff`.
- **Deploy the Edge Function**: `supabase login --token <PAT>` → `supabase link --project-ref rvpisoibtqxxxpgjdhff` → `supabase functions deploy grade-answer --project-ref rvpisoibtqxxxpgjdhff`. Set its secret with `supabase secrets set OPENAI_API_KEY=... --project-ref rvpisoibtqxxxpgjdhff`.
- **Deploy the Claude connector**: `supabase functions deploy connector-key --project-ref rvpisoibtqxxxpgjdhff` and `supabase functions deploy teach-mcp --project-ref rvpisoibtqxxxpgjdhff`. `teach-mcp` **must** run with `verify_jwt = false` (set in `supabase/config.toml`; `--no-verify-jwt` is the equivalent flag), because its `tvk_…` keys are not JWTs — with JWT verification on, the Supabase gateway rejects every Claude request. Needs migration `0012_connector_keys.sql` applied first.
- **Build the IPA**: GitHub Actions workflow `.github/workflows/build-ipa.yml`, trigger type `workflow_dispatch` only.
- **Check for abuse/anomalies on `grade-answer`/`generate-questions`**: no automated alerting exists (deliberately not built yet — would need a monitoring service, a bigger decision Simon hasn't greenlit). Manual check via the Management API's `database/query` endpoint against `public.rate_limit_counters`, e.g. `select identity, request_count, window_start from public.rate_limit_counters where window_start > now() - interval '24 hours' order by request_count desc limit 20;` — a normal identity should never be anywhere near the per-hour caps (150 for grade-answer, 40 for generate-questions, see the `RATE_LIMIT_MAX_PER_HOUR` constants in each function); anything close to those, or an unusually high `global:all-guests` count, is worth investigating. Complement with a look at the OpenAI usage dashboard for cost spikes.

**Never trigger the IPA build or deploy the Edge Functions/migrations proactively.** Only do so on the user's explicit, in-the-moment command — this is a standing rule for this project, not a one-off preference.

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

- TTS: primary voice is Google Cloud WaveNet via the Edge Function `supabase/functions/text-to-speech` (`Services/CloudSpeechService.swift`, protected by a hard spend cap, see `_shared/cloudSpendGuard.ts`). `Services/SpeechService.swift` (`AVSpeechSynthesizer`, native, offline) is the fallback when the cloud voice is unavailable.
- STT: `Services/WhisperTranscriber.swift` wraps WhisperKit, which downloads and runs the Whisper **base** model on-device (CoreML) on first use. Recording itself goes through `Services/AudioRecorder.swift` (16kHz mono WAV, the format WhisperKit expects).

### Answer grading (the other major subsystem)

`StudyView` sends the STT transcript to `Services/GradingService.swift`, which calls the Supabase Edge Function `supabase/functions/grade-answer/index.ts` (Deno/TypeScript, GPT-4o-mini). Two things about this function are load-bearing and easy to break if "simplified" later:

1. **It is deliberately stateless** — it never touches the Supabase database. It takes `question` + `answer` (model answer) + optional cached `kernelemente` (atomic claims already extracted from the model answer) + the STT transcript, and returns the claims used plus a grading verdict. This is what lets grading work identically for cloud flashcards *and* guest (local-only, never-in-Supabase) flashcards — a stateful, DB-reading function would only work for the former.
2. **The extraction cache lives client-side, not in the function.** The client hashes the model answer text (`Core/TextHash.swift`, SHA-256) and compares it to the last hash it cached alongside the extracted claims (`Flashcard.kernelemente` / `kernelemente_source_hash` — Supabase columns for cloud cards via `RemoteLibraryRepository.updateFlashcardGradingCache`, plain struct fields for guest cards via `LocalLibraryRepository`). Only on a cache miss does the client omit `kernelemente` from the request, which makes the function do the (paid) extraction call. This lazy caching is what keeps the OpenAI request count down given how tight the API rate limits are on a fresh account tier.

The OpenAI API key exists only as a Supabase Edge Function secret (`OPENAI_API_KEY`) — never in client code or in this repo. Grading judgment thresholds (65% claim coverage = "richtig", 40% = "teilweise", below = "falsch") are named constants at the top of `index.ts`, explicitly still provisional/tunable, and are re-validated server-side from `deckung_prozent` regardless of what the model claims its own verdict is.

`gpt-4o-mini` is used deliberately despite not appearing on OpenAI's current "flagship models" pricing table — it's still fully supported (own model page, unchanged pricing, generous Tier-1 rate limits) and just isn't part of the newest marketing lineup. Don't "helpfully" swap it for a GPT-5.x model without checking with the user first.

### Data model / RLS

`folders` → `subfolders` → `flashcards` (question/answer text), one Postgres migration per change under `supabase/migrations/`. Every table has Row Level Security scoped to `auth.uid() = user_id`.

**Hard limits, deliberately tight for the current starting phase** (Simon called these explicit starting values, not a final ceiling — expect them to loosen later): max 2 folders per user (raised from 1 so Simon could test the top-left folder-picker dropdown on `FolderListView`), **unlimited subfolders per folder**, max 25 flashcards per subfolder, and — the actual brake now that subfolder count is unlimited — max 50 flashcards per folder *in total, summed across all of its subfolders*. Named constants in `Models.swift` (`maxFoldersPerUser`, `maxFlashcardsPerSubfolder`, `maxFlashcardsPerFolder`; `maxSubfoldersPerFolder` no longer exists, removed on purpose). Each is enforced *twice* (and the card limits are additionally mirrored as constants in `supabase/functions/teach-mcp/index.ts` for readable messages to Claude — keep all three in sync) — a Postgres trigger (`enforce_folder_limit` / `enforce_flashcard_limit`, cloud mode, see `supabase/migrations/0003_tighter_limits.sql`, `0005_raise_flashcard_limit.sql`, `0007_unlimited_subfolders.sql`, `0011_raise_folder_limit.sql`) and an equivalent check inside `LocalLibraryRepository` (guest mode) — keep both sides in sync if any of these limits change. `LibraryStore` also does a client-side pre-check for immediate UI feedback before ever calling the repository; for the folder-wide total this requires `LibraryStore.loadAllFlashcards(for:)` to have run first (loads every subfolder's cards, not just visited ones), otherwise the client-side number can undercount — the server/repository side remains the actual authority.

Both folders and subfolders are renameable (context menu / swipe in their list views); flashcards are editable in place (tap opens `AddFlashcardSheet` pre-filled, reusing the same sheet used for creation). Editing a flashcard's model answer is exactly the case the STT-grading lazy-cache (`kernelemente_source_hash`) exists to catch — no extra invalidation code needed, the next review just naturally misses the cache and re-extracts.

### Claude connector (`teach-mcp`)

A remote MCP server on Supabase Edge Functions that lets the user's own Claude read their library and create subfolders + flashcards (e.g. "make 10 cards on chapter 3 in subfolder X"). The app has no server part; it just shows the new rows on its next load (list views also reload when the app returns to the foreground via `scenePhase`).

- **v1 is read + create only** (Simon's decision): tools `list_library`, `list_flashcards`, `create_subfolder`, `add_flashcards`. No edit/delete tools — don't add them without asking.
- **Auth = personal key, not OAuth** (Simon's decision for the testing phase). The app (`Views/Profile/ConnectorView.swift` → `Services/ConnectorKeyService.swift`) calls the Edge Function `connector-key` (GET status / POST new key / DELETE revoke; caller token verified via GoTrue like `delete-account`). Keys are `tvk_` + 256 random bits; only the SHA-256 hash is stored in `public.connector_keys` (`0012_connector_keys.sql`, RLS on + all grants revoked, service_role only). One active key per user. The user pastes the key into Claude as request header `Authorization: Bearer tvk_…`. Switching to Supabase's OAuth 2.1 server is the planned path once other users or ChatGPT should use the connector.
- **service_role bypasses RLS**, so every query in `teach-mcp` filters `user_id=eq.<id>` explicitly, every insert sets `user_id`, and folder/subfolder ownership is checked before writing. Any new tool must follow the same rule.
- **Cloud-only**: guest data never leaves the device, so the connector can't reach it; `ProfileView` only offers it in `.cloud` mode.
- `add_flashcards` inserts atomically, skips questions that already exist in the subfolder, rejects batches that don't fit the free slots, and spaces `created_at` by 1 ms per card so the app's `position, created_at` ordering stays stable. Length caps mirror `text-to-speech` (question) and `grade-answer` (answer) so every card stays speakable and gradable.
- Rate limit: 200 MCP requests/hour per user in its own bucket (`connector:<userId>`) via `_shared/rateLimit.ts`. No OpenAI cost: Claude writes the cards, the connector only stores them.

### CI / distribution

There is no Apple Developer account and no signing certificate anywhere in this project. `.github/workflows/build-ipa.yml` builds an **unsigned** archive on a macOS runner and manually zips the `.app` into an IPA structure; [Sideloadly](https://sideloadly.io/) re-signs it with the user's own Apple ID at install time. Don't add code-signing/export-options logic — that's a solved-differently problem here, not a missing piece.

### Deployment target

`project.yml` targets iOS 17.0. This isn't arbitrary — `ContentUnavailableView` and the two-parameter `onChange(of:)` overload are used throughout the views and both require iOS 17. Lowering the deployment target back to 16 would break the build.
