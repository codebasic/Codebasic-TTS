# Codebasic TTS V2 prototype

Goal: keep the existing multi-provider connection/model selection while making ordinary conversation the primary interface. Direct Gemini streaming remains supported; fresh V2 defaults to gemini-flash-lite-latest with Google service default gemini-2.5-flash. OpenAI-compatible, Anthropic, Ollama and supported account-plan transports reuse EndpointGenerator and provider-neutral message conversion.

Scope: independent clone a separate local clone, branch feature/chat-v2, base aba918365ea9a7dc19fa27b9652a0f6bbe84df24. V1 and pipeline checkouts are read-only. No install, Services registration or push. The validated GUI flows used explicit offline test mode; one incidental default-mode CUA auto-relaunch was immediately closed without user actions and is documented in GUI-VALIDATION.md. After later explicit user authorization, one synthetic Google request and one ElevenLabs request/software playback check succeeded through the production components; see LIVE-VALIDATION.md.

## Isolation and connection reuse

- Bundle ID com.seongjoo.CodebasicTTSV2; local app build/Codebasic TTS V2.app.
- Normal data: ~/Library/Application Support/Codebasic TTS V2. Google/Codex plan working directories also remain inside V2.
- No automatic V1 migration. The explicit connection button imports endpoint/model settings and voice/model IDs only, enabling read-only access to the original V1 key files. No keys are copied. Another button revokes the fallback. New settings/key writes always target V2. Account-plan login state is not copied.
- No V1 Services or global hotkeys are registered. ElevenLabs is not contacted on startup, settings opening, key save or text generation. Playback/preview are explicit; voice/model IDs can be entered without listing APIs.

## Persistence and cancellation

Conversation metadata lives in chat/conversations.json: roles, timestamps, status, provider/model snapshots and attachment filenames. Immutable images live in chat/attachments and are written once. Disposable audio lives in chat/audio-cache; clearing it preserves conversations. Prior V2 inline-image archives remain readable and are upgraded on the next save; V1 data is never migrated.

A serial utility queue performs encoding and writes, caching serialized metadata for unchanged threads. New-thread creation performs one durability flush and rolls back if it fails. Streaming schedules at most one checkpoint per second; new chunks do not encode the full image archive. Completion, error, cancellation and normal application termination cancel the pending timer and synchronously drain/save the final snapshot. Initial send is also durable before a generation request begins. Abrupt process termination can lose up to the last checkpoint interval of text. After an unclean exit, unfinished responses become interrupted. Failed/partial/interrupted assistant messages stay visible and are excluded from future model context.

Corrupt metadata or missing attachment files block further writes and show an error, preserving the original files for repair. Checkpoints reuse unchanged thread encodings and assemble/write all metadata, so very large histories can eventually need per-thread files/indexing. Reproducible 50/300/1000-thread synthetic benchmarks include up to 20,000 messages and 82,641,440 attachment bytes; see PERFORMANCE-VALIDATION.md for timings and memory tradeoffs.

## Response playback

Text generation and audio have separate tasks/tokens. A repeated click cannot start a second request; stop invalidates the token before cancelling and clearing the playback queue. Cache identity includes voice, model, voice settings and chunk text. Existing TextSplitter and QueuePlayer are reused: maximum 700 characters per synthesis request, sequential synthesis with the first available chunk immediately enqueued. The first chunk is fully buffered before playback; later chunks can synthesize while earlier audio plays. Slow synthesis can leave gaps at paragraph boundaries. Cancelling stops future requests and ignores late results, but cannot undo provider billing for an already submitted request.

Speech removes common Markdown heading/fence/emphasis/link delimiters locally; code content remains. It is not a full Markdown renderer or an LLM narration pass. Responses over 20,000 characters are rejected before synthesis with a visible message. The limit and initial-playback behavior are shown in the UI. One authorized 13-character ElevenLabs response reached normal AVQueuePlayer completion; physical speaker audibility is not independently measured.

## Build and offline GUI commands

`./build.sh build` compiles and ad-hoc signs locally. `./build.sh test` runs 38 chat mock checks, offline isolation/network-interception checks, and all original local regression targets, plus a mocked production Gemini payload/stream check. Bare build.sh also means build only; install/dev/smoke are unavailable.

The build uses the installed macOS 26.5 SDK because this host's default macOS 27 SDK references a missing SwiftUIMacros plugin. Override SWIFT_SDK_PATH for another complete SDK. Minimum target is macOS 14, matching existing UI API usage.

For GUI testing, run the built binary with CODEBASIC_V2_OFFLINE=1 and CODEBASIC_V2_TEST_ROOT=/tmp/codebasic-v2-gui-review. The test root must resolve inside /tmp. Offline setup happens before AppState initialization: credential reads return nil, model refresh/CLI discovery calls are skipped, URLSession requests are intercepted and failed locally, account-plan editing and V1 reuse are disabled. Chat text and audio use mock functions; no sound device or paid service is used. The network regression probe uses loopback port 1 and verifies URLProtocol interception before a connection.

## GUI observations — 2026-11-17

Observed with CUA on the actual compiled V2 while V1 stayed running:

| Flow | Result |
|---|---|
| Startup | Offline isolation banner and gemini-flash-lite-latest selector visible |
| Image | Native open panel selected a synthetic PNG from /tmp; attachment count and rendered image visible |
| Send | User message, streamed mock response and completed response playback control visible |
| Playback/stop | Explicit mock playback showed preparing status and stop button; stop reset the state |
| New conversation/list | Two independent conversations listed; selecting each restored its own messages |
| Cancel | Slow mock response changed from generating to cancelled; send became available |
| Settings round trip | Voice and AI service panels showed existing multi-provider UI; returning preserved chat |
| Quit/restart | Normal quit succeeded; same /tmp data restored cancelled status, completed response, timestamps and image |
| Cleanup | Test V2 exited normally; V1 remained running |

One invalid tiny PNG fixture was initially rejected correctly. Replacing it with a valid synthetic PNG succeeded. A stale attachment notice found during this test was cleared in the final UI patch. The final Markdown and notice patch was unit-tested/built; the entire GUI sequence was not repeated for that small follow-up.

## Claude consultation and review

The first Claude CLI attempt failed while unauthenticated. The parent later confirmed authentication but reported automatic approval review rejected source-diff review because of external Figma/Datadog destination risk. That operation was not retried or bypassed here. A separate authenticated Claude desktop design consultation was completed by the parent, without source or secrets, using Claude Haiku 5.5: https://claude.ai/chat/b12bc313-c36a-4f20-9907-75728a26d498 . This is design advice, not an independent source-diff review.

Adopted against code/tests: one-second throttled checkpoints; final-state flushes; immutable separate attachments; interrupted recovery; separate playback token and a single queue; voice/model/settings cache identity; long-text splitting; basic Markdown cleanup; provider-neutral history. The mock GUI and tests verify these selected changes.

Not adopted: copying credentials or sharing Keychain access, which exceed the authorized read-only V1 reference approach. Model-specific image capability detection remains deferred: users must choose an image-capable model; provider rejection is shown as a generation failure, without deleting the message/attachment. Large-history synthetic benchmarks and a minimal Google/ElevenLabs production-component check were completed. Other real providers and account login remain unverified. Local self-review and the parent's independent Codex review were performed; Claude final source-diff review remains unavailable due to the stated automatic-review block.

## Acceptance and recovery

- PASS: isolated clone, identity, data and plan paths; V1 checkout stayed clean at the base revision. No install or registration executed.
- PASS: shared multi-provider generation/picker and fast Gemini defaults.
- PASS: chat cancellation, duplicates, failures, cache independence, restart, corrupted-history protection, throttled writes, one-time attachment writes, final flushes, bounded/chunk-first audio, Markdown and over-limit handling through mocks.
- PASS: original unit targets, model catalog/cache parsing, memory concurrency/cancellation, fake CLI connections, conversation serialization (134), explanation rules (49).
- PASS: isolated offline GUI flows on 0bfb8f4 above. Final post-performance-patch list/compose/attachment/playback/cancel/settings flows were subsequently observed successfully after unlock; the parent independently completed visual restart restoration of the newly added image/response/cancelled records after another unlock. No GUI blocker remains. See GUI-VALIDATION.md. One authorized Google/ElevenLabs production-component check passed; image/model compatibility, other providers, account login and physical speaker audibility remain UNVERIFIED.
- Risk: medium. Recovery: discard this independent clone/build and its V2-only data directory; V1 requires no rollback.

Raw local verification logs are kept under build/validation. No source, credentials or user documents were sent as model content. Only the expressly authorized credential headers and new synthetic test text were sent to Google/ElevenLabs; see LIVE-VALIDATION.md.
