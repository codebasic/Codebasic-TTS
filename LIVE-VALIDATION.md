# Authorized minimal Google / ElevenLabs verification — 2026-11-17

The user explicitly authorized read-only use of the existing app's authentication information for one short, harmless synthetic Google response and playback of that response with the existing ElevenLabs voice/model. No existing conversation, document or image was submitted. No credential value was printed, copied to a new file or added to a report.

The Mac was locked, so this was a production-component integration probe rather than an observed live GUI flow. The probe uses the same EndpointGenerator, provider-neutral conversation, ChatSession, ElevenLabsBackend, TextSplitter/ChatSpeechPlan and QueuePlayer as V2. It ran with CODEBASIC_V2_LIVE_VALIDATION=1, CODEBASIC_V2_OFFLINE unset and CODEBASIC_V2_TEST_ROOT=a dedicated temporary folder. Offline URLProtocol blocking was not bypassed; it is only installed by offline mode, in a different process. There was no account login, subscription, billing setting or installation change.

## Controls

Live-validation mode suppresses automatic provider/model discovery, refuses plan transports and non-Google generation endpoints in the UI, uses a dedicated /tmp data root, caps Gemini output at 64 tokens, and persists a one-use permit per authorized provider. Failed attempts also consume the permit. The audio check accepts a single response below 300 characters. The manual probe requires an explicit --authorized-single-probe argument, checks the selected original model/endpoint, and is never run by build.sh test. Keys are read through the explicit V1 fallback marker; only that empty marker is created, not key files.

Before the actual request, URLProtocol mock tests verified the production Gemini streaming payload had the 64-token cap and provider-neutral conversation. Permit/isolation checks and all normal regression tests passed without real requests.

## Actual result

| Item | Observed result |
|---|---|
| Google logical requests | 1, no application retry |
| Selected Google model | gemini-flash-lite-latest, original selected model |
| Submitted user text | 39 synthetic characters requesting only the sentence “음성 연결 테스트입니다.” |
| Other submitted content | A short synthetic system instruction; no previous messages or images |
| Generated response | 13 characters |
| Returned Google usage | 34 prompt tokens, 6 candidate tokens, 40 total; serviceTier standard |
| ElevenLabs logical requests | 1, no application retry |
| Voice/model | Original selected voice and eleven_v4; original tuning read-only |
| ElevenLabs input | The 13-character generated response only |
| ElevenLabs response | HTTP 200, 30,137 MP3 bytes |
| Playback | AVQueuePlayer reached end-of-item: completed_chunks=1, expected_chunks=1; no failure event or timeout |
| Physical audibility | Not independently recorded/heard through a measurement device; the completion event verifies the software playback path |
| Billing | No balance, invoice or exact charge was queried. Token/character counts above are known; monetary cost/credit debit remains unverified |

Non-secret evidence is under build/validation/live. The synthetic conversation/audio and one-use markers remain in the dedicated /tmp live root. Do not re-run a paid probe merely to reproduce this report; another live run requires its own authorization. The reproduction benchmark and build.sh test use synthetic/local mocks only.

## V1 preservation

Before/after checks found the original settings JSON and installed app executable SHA-256 digests unchanged. Metadata for five settings/credential files (size, modification time and inode) was unchanged; credential contents were not read for this comparison. V1 checkout remained clean at aba918365ea9a7dc19fa27b9652a0f6bbe84df24. No V1 history or attachments were read. The only credential reads were those required by the expressly authorized Google/ElevenLabs probe.
