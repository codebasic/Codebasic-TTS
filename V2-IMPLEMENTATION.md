# Codebasic TTS V2 prototype

Goal: preserve the existing multi-provider connection/model selection while making ordinary conversation the primary interface. Direct Gemini streaming remains supported; fresh V2 defaults to gemini-flash-lite-latest with Google service default gemini-2.5-flash. OpenAI-compatible, Anthropic, Ollama and existing supported plan transports reuse EndpointGenerator unchanged.

Scope: this independent clone only, branch feature/chat-v2, base aba918365ea9a7dc19fa27b9652a0f6bbe84df24. V1 and pipeline checkouts are read-only. No installation, app launch, push, live model generation or live voice calls.

## Isolation and operation

- Bundle ID: com.seongjoo.CodebasicTTSV2; app: build/Codebasic TTS V2.app.
- Data: ~/Library/Application Support/Codebasic TTS V2. Google plan and Codex plan working directories are also isolated.
- Conversation records: chat/conversations.json, including roles, timestamps, PNG attachments, response status, provider and model snapshots.
- Disposable audio: chat/audio-cache; deleting this folder does not delete conversations.
- No automatic V1 migration. The explicit V1 connection button imports endpoint/model settings and voice/model IDs only. It enables read-only access to V1 credential files without copying keys. A second button revokes that fallback. New settings/key writes always target V2. Existing account-plan login state is not copied; authenticate separately if needed.
- No Services or global hotkeys are registered by V2. ElevenLabs is not contacted on startup, settings opening, key save, or text generation. Playback/preview are explicit. Voice/model IDs can be entered without listing APIs.
- Text streams persist independently of audio. Generation and audio have separate cancellation tokens. Late cancelled work cannot append or play. Failed/partial/interrupted assistant messages remain visible and are excluded from subsequent context.
- Corrupt conversation files are preserved and block writes; repair/restore the JSON before continuing. Persistence errors appear in the interface.

## Commands

`./build.sh build` builds and ad-hoc signs locally. `./build.sh test` runs new mock chat checks and all original local test targets. Bare build.sh also means build only; install/dev/smoke are unavailable. No SwiftPM/Xcode project.

Build uses the installed macOS 26.5 SDK because this host's default macOS 27 SDK references a missing SwiftUIMacros plugin. Override SWIFT_SDK_PATH to choose another complete SDK. Minimum target is macOS 14, matching existing UI API usage.

## Verification and remaining limits

New mock tests cover persisted text/images/timestamps/provider/model, audio-generation independence, duplicate generation/playback, cache reuse, cancellation/late results, synthesis and generation failures, restart interruption, corrupt-history preservation and cache deletion. Existing tests exercise provider records, serialization, fake CLI connections, model catalog and explanation rules.

GUI layout, actual streaming against all providers, account-plan login and real ElevenLabs audio remain unverified. No paid calls were made. Attachments currently support PNG/JPEG (up to eight, 10 MB each); no arbitrary files. Entire conversation history is supplied without automatic context trimming; large histories may exceed a provider limit. Drafts are session-only. No deletion/export/search UI in this prototype.

Claude Code 2.1.316 is installed. `claude auth status` returned loggedIn=false/authMethod=none. A tools-disabled, safe-mode design consultation failed with `Not logged in · Please run /login`. No Claude design/final-diff review was obtained; a separate local review pass was performed instead. Claude review remains a completion blocker for the requested independent review. No credentials or user documents were sent.

## Acceptance record

- PASS: independent V2 clone, bundle ID, settings/data/plan workspace paths; V1 checkout stayed clean at the base revision. No install/start/registration command executed.
- PASS: preserved shared multi-provider EndpointGenerator and model picker; fast Gemini defaults configured.
- PASS: 21 mock chat checks, original unit suite, ElevenLabs catalog/cache parsing, memory concurrency/cancellation, fake CLI connection tests, conversation serialization (134), explanation rules (49). Test command exited 0.
- PASS: final local V2 build using macOS 26.5 SDK exited 0, including UI actor-boundary cleanup. Existing CodexPlan capture warnings remain.
- UNVERIFIED: GUI behavior/layout, real provider/API/voice calls, account-plan login.
- BLOCKED: requested Claude consultation and independent final diff review, because installed CLI is not authenticated. No auto-review denial occurred.
- Risk: medium. Recovery: discard this independent clone/build and its unique V2 data directory; V1 requires no rollback.
