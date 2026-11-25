# Offline GUI validation

Final status: PASS for the requested offline GUI flows on source revision 7a7e521. The parent independently completed the last restart/restore observation after the second unlock. Subsequent commits update documentation only.

See V2-IMPLEMENTATION.md for the verified flow table, isolation controls, exact limitations and Claude design-advice disposition.

Executed built binary with CODEBASIC_V2_OFFLINE=1 and CODEBASIC_V2_TEST_ROOT=/tmp/codebasic-v2-gui-review. CUA verified startup, image attachment, message send, mock response, explicit playback/stop, slow-generation cancellation, conversation selection, settings round trip, normal quit and restart restoration. V1 was simultaneously running throughout; its UI and data were not operated on. Both V2 process sessions exited 0 after normal GUI quit.

Test data remains in /tmp/codebasic-v2-gui-review for inspection. It contains synthetic text/images only. Playback was a state mock with fake bytes, not sound-device output. No paid provider or ElevenLabs requests were made.

## Final post-performance-patch rerun

The final app built and signed successfully, and all 38 chat mock checks, offline/permit checks, production Gemini transport mock and original regressions passed. It was launched with CODEBASIC_V2_OFFLINE=1 and CODEBASIC_V2_TEST_ROOT=/tmp/codebasic-v2-bench-300, containing only generated synthetic history (300 seed conversations, 6,000 seed messages and approximately 83 MB of synthetic PNGs, plus a few benchmark turns).

CUA could not inspect or operate the app because the Mac was locked and automatic unlock was unavailable. A manual-unlock request was issued; no lock bypass was attempted. At that point the final flow and actual large-list GUI responsiveness were blocked. Both were subsequently observed after unlock, as recorded below. The prior complete GUI sequence above was on 0bfb8f4; it must not be presented as the final post-cache-patch rerun. The offline app remained running for the unlock/resume step. Startup logged one nonfatal NSTableView reentrant-operation warning; its user-visible effect could not be checked while locked.

The authorized real Google/ElevenLabs check was completed separately through production V2 components while GUI access was blocked; see LIVE-VALIDATION.md. That check does not establish the live GUI flow.

## Resumed final-code observations after unlock

The Mac was unlocked and CUA inspected the exact app built from 7a7e521 (binary SHA-256 3c89774e52bdc60a7cb4fe006be96e8156ebb2e192b263b5e5721a49cf06145e). The offline banner was visible. New test records were written only in /tmp/codebasic-v2-bench-300/chat, confirming the isolated data route. No source changes or additional real API requests were made.

Observed on this final source:

- Selected Synthetic conversation 0000, scrolled the sidebar to the final 0299 item, selected it and opened a new conversation. All remained responsive; no visible hang or incorrect conversation content was observed. This is qualitative GUI observation, not a measured FPS/frame-time result.
- Normally quit the old offline process (exit 0), relaunched the same final binary with the same offline variables, and observed the persisted new conversation plus the large synthetic list restored.
- Attached the known synthetic PNG through NSOpenPanel. Explicitly selecting the file row enabled Open; selecting only its suggested path had left Open disabled. This required no app change. The completed conversation visibly rendered the blue synthetic image.
- Sent Final offline attachment test 7a7e521; observed streaming state, complete mock response and playback control. Playback showed preparing/stop; stop reset the state.
- Created a second conversation with 취소 검증 final 7a7e521, started the deliberately slow mock and cancelled it; state became cancelled and input controls re-enabled.
- Switched back to the completed image conversation, opened voice and AI-service settings, and returned. Image, response and thread selection were preserved.
- The new restart logged the same nonfatal NSTableView reentrant-operation warning. During the tested list, compose, playback, cancellation and settings operations it caused no observed user-visible failure. Its underlying cause and behavior on future macOS versions remain unverified.

The Mac locked again before the last visual restoration check. Direct inspection at that point confirmed 310 threads / 6,020 messages, the completed test thread with an existing image attachment and timestamps, and the cancelled partial response with timestamps. This was initially recorded as pending; the independent GUI observation below resolves it.

V1 settings and installed-binary digests, and original credential-file metadata, were checked again after this GUI session and remained unchanged.

## Independent final restart/restore confirmation — completed

The parent reported a direct CUA confirmation after the Mac was unlocked again:

1. Normally quit V2 with Command-Q, then started the same built binary explicitly with CODEBASIC_V2_OFFLINE=1 and CODEBASIC_V2_TEST_ROOT=/tmp/codebasic-v2-bench-300.
2. Confirmed the visible offline MOCK / external-connection-blocked banner.
3. Opened 취소 검증 final 7a7e521 and observed the partial response with cancelled status.
4. Selected Final offline attachment test 7a7e521 and observed the original user message, image element, completed mock response acknowledging one image, and restored playback button.

This completes the visual restoration check for the newly created records; no GUI lock blocker remains. The observation was performed independently by the parent, not repeated by this implementation turn. No source change or further API test was required.

Automation caveat: immediately after the first normal quit, a CUA getAXState call automatically launched V2 in its default mode. The parent immediately closed that process without input, settings, generation or key-import actions, then explicitly relaunched offline and performed the checks above. The default-mode startup was not used as validation evidence. No additional generation/synthesis was requested; automatic model-discovery traffic during that incidental startup was not instrumented, so this report does not claim that process had a network blocker installed. Avoid selecting/observing a stopped native app until it has been relaunched with the intended explicit test environment.

A final read-only preservation check after this confirmation again found V1 settings and installed-executable digests unchanged, original settings/credential file metadata unchanged, and the V1 checkout clean at aba918365ea9a7dc19fa27b9652a0f6bbe84df24. No credentials were copied or printed. Physical speaker audibility, exact billing and full live GUI coverage of every provider remain outside this offline GUI result.
