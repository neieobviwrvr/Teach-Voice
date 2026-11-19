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
- **Deploy the Claude connector**: `supabase functions deploy connector-key --project-ref rvpisoibtqxxxpgjdhff` and `supabase functions deploy teach-mcp --project-ref rvpisoibtqxxxpgjdhff`. `teach-mcp` **must** run with `verify_jwt = false` (set in `supabase/config.toml`; `--no-verify-jwt` is the equivalent flag), because its `tvk_…` keys are not JWTs — with JWT verification on, the Supabase gateway rejects every Claude request. Needs migrations `0012_connector_keys.sql` and `0013_remove_limits.sql` applied first.
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
- **Audio must never overlap** (Simon's test: right after app start he got silence, an unprocessed answer, then several voice lines at once). Two load-bearing guards, don't "simplify" them away: (1) `SpeechService` bumps a `generation` counter on every `speak`/`stop`; late cloud audio, not-yet-started tasks and delegate callbacks of an older line are dropped, and `speakAndWait` only resolves for the line that is actually playing (identity check on the current `AVSpeechUtterance`/`AVAudioPlayer`). Unplayable audio falls back to local speech instead of leaving `speakAndWait` hanging. (2) `VoiceStudyView` starts with a preparation phase — mic permission, `transcriber.prepareIfNeeded()`, `speech.prefetch` of the first questions (max 6 s wait) — and prefetches the next questions while the user answers.

### Answer grading (the other major subsystem)

`VoiceStudyView` (the voice study mode) sends the STT transcript to `Services/GradingService.swift`, which calls the Supabase Edge Function `supabase/functions/grade-answer/index.ts` (Deno/TypeScript, GPT-4o-mini). Two things about this function are load-bearing and easy to break if "simplified" later:

1. **It is deliberately stateless** — it never touches the Supabase database. It takes `question` + `answer` (model answer) + optional cached `kernelemente` (atomic claims already extracted from the model answer) + the STT transcript, and returns the claims used plus a grading verdict. This is what lets grading work identically for cloud flashcards *and* guest (local-only, never-in-Supabase) flashcards — a stateful, DB-reading function would only work for the former.
2. **The extraction cache lives client-side, not in the function.** The client hashes the model answer text (`Core/TextHash.swift`, SHA-256) and compares it to the last hash it cached alongside the extracted claims (`Flashcard.kernelemente` / `kernelemente_source_hash` — Supabase columns for cloud cards via `RemoteLibraryRepository.updateFlashcardGradingCache`, plain struct fields for guest cards via `LocalLibraryRepository`). Only on a cache miss does the client omit `kernelemente` from the request, which makes the function do the (paid) extraction call. This lazy caching is what keeps the OpenAI request count down given how tight the API rate limits are on a fresh account tier.

**Grading schema ("Kontrollpunkte") — Simon asked for this to be as good as possible so we stop going in circles; keep all of it:**
- *Kontrollpunkte* (stored in `kernelemente`) are the statements a fully correct spoken answer must contain. **Claude must supply them** for every card created via the connector (`kontrollpunkte` is a required field in `teach-mcp`'s `add_flashcards`, 1–6 recommended, max 8, rules + a bad/good example in `CARD_STYLE_GUIDE`). `teach-mcp` stores them together with `kernelemente_source_hash = SHA-256(trimmed answer)` via `_shared/answerHash.ts`, which must stay byte-identical to `Core/TextHash.swift` (pinned by a fixed test vector in `TextHashTests`). The app then sends them on every grading — no extraction call ever happens for those cards.
- Only cards without them (written in the app, PDF import, or answer edited later → hash mismatch) fall back to GPT extraction, whose prompt forbids overlapping points (the "Behaviorismus" example of three paraphrases of one idea is in the prompt).
- Grading judges **each point separately** (`getroffen` / `teilweise` / `fehlt`, one statement may satisfy several points, a short quote from the transcript is required as evidence), via OpenAI Structured Outputs (strict JSON schema). **The server computes `deckung_prozent` from the per-point verdicts** (teilweise = 0.5), not the model. `kurzloesung` may only mention missing/partial points and is forced empty when everything was hit. The response adds `punkte` (text, status, beleg), shown in the app as a checklist; `kurzes_feedback` is kept empty only for old app builds.
- After changing the extraction prompt, stale cached extractions can be cleared with `update public.flashcards set kernelemente = null, kernelemente_source_hash = null where …` — never blindly for cards whose points came from Claude.

The OpenAI API key exists only as a Supabase Edge Function secret (`OPENAI_API_KEY`) — never in client code or in this repo. The server's own verdict thresholds (`THRESHOLD_RICHTIG`/`THRESHOLD_TEILWEISE` in `index.ts`) only fill the response's `urteil` field; the app ignores it and maps `deckung_prozent` itself via the user's **Zielnote** (`Core/Zielnote.swift`, German grade 1,0–4,0 set in the profile, linear 15 points per grade: 1,0 → 95 %, 2,0 → 80 %, 3,0 → 65 %, 4,0 → 50 %, "teilweise" 20 points lower). The Zielnote only changes how much coverage is needed — never how generously individual claims are matched (paraphrase/colloquial wording always counts, Simon's explicit wish). `kurzloesung` is read aloud by the voice mode when the answer isn't "richtig" — same OpenAI call, no extra cost. `GradingResult.kurzloesung`, `punkte` and `kurzesFeedback` are optional on the client so an older deployed function still decodes (`GradingResultDecodingTests`).

### Study modes and spaced repetition

Exactly two modes (Simon's MVP decision), both started via `studyModeDialog` (`Views/Study/StudyLauncher.swift`) from the home screen mind map, a folder ("Ganzen Ordner lernen") or a subfolder: **Sprechen** (`VoiceStudyView`: TTS question → recording ends after 8 s silence following the first word, or "Fertig" → Whisper → grading → self-assessment with the AI's suggestion highlighted) and **Tippen** (`AnkiStudyView`: show answer → self-assessment, no mic/AI). Self-assessment is always the SR signal. `Core/StudyQueue.swift` runs a session: only due + new cards (`SpacedRepetition.sessionCards`; all cards if nothing is due), and any card that lands in a 0-day box (`SpacedRepetition.isDueAgainToday`) is re-appended until it sticks. Stats count first attempts only. The old Detail / Voice-only / voice-menu modes were removed on purpose — don't resurrect them.

`gpt-4o-mini` is used deliberately despite not appearing on OpenAI's current "flagship models" pricing table — it's still fully supported (own model page, unchanged pricing, generous Tier-1 rate limits) and just isn't part of the newest marketing lineup. Don't "helpfully" swap it for a GPT-5.x model without checking with the user first.

### Data model / RLS

`folders` → `subfolders` → `flashcards` (question/answer text), one Postgres migration per change under `supabase/migrations/`. Every table has Row Level Security scoped to `auth.uid() = user_id`.

**No quantity limits** (Simon's MVP decision — for now the app is only for him): unlimited folders, subfolders and flashcards. `supabase/migrations/0013_remove_limits.sql` drops the old `enforce_folder_limit` / `enforce_flashcard_limit` triggers; the app (`LibraryStore`, `LocalLibraryRepository`, views) and `teach-mcp` no longer check counts. If limits ever come back, they have to be added on all three sides again (DB trigger, `LocalLibraryRepository` for guest mode, `teach-mcp` messages). Text-length caps in the Edge Functions stay.

Both folders and subfolders are renameable (context menu / swipe in their list views); flashcards are editable in place (tap opens `AddFlashcardSheet` pre-filled, reusing the same sheet used for creation). Editing a flashcard's model answer is exactly the case the STT-grading lazy-cache (`kernelemente_source_hash`) exists to catch — no extra invalidation code needed, the next review just naturally misses the cache and re-extracts.

### Claude connector (`teach-mcp`)

A remote MCP server on Supabase Edge Functions that lets the user's own Claude read their library and create folders, subfolders + flashcards (e.g. "make 10 cards on chapter 3 in subfolder X"). The app has no server part; it just shows the new rows on its next load (list views also reload when the app returns to the foreground via `scenePhase`).

- **Read + create only** (Simon's decision): tools `list_library`, `list_flashcards` (incl. card `id` and `kontrollpunkte`), `create_folder`, `create_subfolder`, `add_flashcards`. The one exception, approved by Simon on 2026-11-19: `set_kontrollpunkte` sets/replaces the grading points of existing cards in one subfolder (so Claude can backfill cards created before Kontrollpunkte existed) — it never touches question or answer. No other edit/delete tools — don't add them without asking.
- **Auth = personal key, not OAuth** (Simon's decision for the testing phase). The app (`Views/Profile/ConnectorView.swift` → `Services/ConnectorKeyService.swift`) calls the Edge Function `connector-key` (GET status / POST new key / DELETE revoke; caller token verified via GoTrue like `delete-account`). Keys are `tvk_` + 256 random bits; only the SHA-256 hash is stored in `public.connector_keys` (`0012_connector_keys.sql`, RLS on + all grants revoked, service_role only). One active key per user. The user adds the **personal Claude link** `…/functions/v1/teach-mcp/tvk_…` once as the custom connector URL in Claude — the key lives in the URL path because claude.ai only offers request headers for custom connectors as a beta for selected orgs. `teach-mcp` takes the key from the path, `?key=`, `Authorization: Bearer` or `X-Teach-Key`, strips it from the URL before handing the request to the MCP handler, and must never log the request URL. The app builds the link via `Core/ConnectorLink.swift` and keeps the plaintext key only in this device's Keychain (`connectorKey.<userId>`) so the link can be shown again. Switching to Supabase's OAuth 2.1 server is the planned path once other users or ChatGPT should use the connector.
- **service_role bypasses RLS**, so every query in `teach-mcp` filters `user_id=eq.<id>` explicitly, every insert sets `user_id`, and folder/subfolder ownership is checked before writing. Any new tool must follow the same rule.
- **Cloud-only**: guest data never leaves the device, so the connector can't reach it; `ProfileView` only offers it in `.cloud` mode.
- `add_flashcards` inserts atomically (max 50 cards per call, no total limit), skips questions that already exist in the subfolder, and spaces `created_at` by 1 ms per card so the app's `position, created_at` ordering stays stable. Length caps mirror `text-to-speech` (question) and `grade-answer` (answer) so every card stays speakable and gradable.
- Rate limit: 200 MCP requests/hour per user in its own bucket (`connector:<userId>`) via `_shared/rateLimit.ts`. No OpenAI cost: Claude writes the cards, the connector only stores them.

### CI / distribution

There is no Apple Developer account and no signing certificate anywhere in this project. `.github/workflows/build-ipa.yml` builds an **unsigned** archive on a macOS runner and manually zips the `.app` into an IPA structure; [Sideloadly](https://sideloadly.io/) re-signs it with the user's own Apple ID at install time. Don't add code-signing/export-options logic — that's a solved-differently problem here, not a missing piece.

### Deployment target

`project.yml` targets iOS 17.0. This isn't arbitrary — `ContentUnavailableView` and the two-parameter `onChange(of:)` overload are used throughout the views and both require iOS 17. Lowering the deployment target back to 16 would break the build.
