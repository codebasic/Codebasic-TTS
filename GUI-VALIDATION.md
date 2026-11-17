# Offline GUI validation

See V2-IMPLEMENTATION.md for the verified flow table, isolation controls, exact limitations and Claude design-advice disposition.

Executed built binary with CODEBASIC_V2_OFFLINE=1 and CODEBASIC_V2_TEST_ROOT=/tmp/codebasic-v2-gui-review. CUA verified startup, image attachment, message send, mock response, explicit playback/stop, slow-generation cancellation, conversation selection, settings round trip, normal quit and restart restoration. V1 was simultaneously running throughout; its UI and data were not operated on. Both V2 process sessions exited 0 after normal GUI quit.

Test data remains in /tmp/codebasic-v2-gui-review for inspection. It contains synthetic text/images only. Playback was a state mock with fake bytes, not sound-device output. No paid provider or ElevenLabs requests were made.

## Final post-performance-patch rerun

The final app built and signed successfully, and all 38 chat mock checks, offline/permit checks, production Gemini transport mock and original regressions passed. It was launched with CODEBASIC_V2_OFFLINE=1 and CODEBASIC_V2_TEST_ROOT=/tmp/codebasic-v2-bench-300, containing only generated synthetic history (300 seed conversations, 6,000 seed messages and approximately 83 MB of synthetic PNGs, plus a few benchmark turns).

CUA could not inspect or operate the app because the Mac was locked and automatic unlock was unavailable. A manual-unlock request was issued; no lock bypass was attempted. Therefore the full flow on this final revision and actual large-list GUI responsiveness remain BLOCKED, not passed. The prior complete GUI sequence above was on 0bfb8f4; it must not be presented as the final post-cache-patch rerun. The offline app remained running for the unlock/resume step. Startup logged one nonfatal NSTableView reentrant-operation warning; its user-visible effect could not be checked while locked.

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

The Mac locked again before the final check of the newly generated response/image/cancel state after another restart. That specific last GUI observation is still pending manual unlock; prior general restart/large-list restoration above did pass. Direct inspection of the synthetic archive independently confirms 310 threads / 6,020 messages, the completed test thread with one existing attachment and timestamps, and the second thread's cancelled partial response with timestamps. Do not substitute that disk inspection for the remaining visual restart check. The running offline test app is left ready for this short continuation.

V1 settings and installed-binary digests, and original credential-file metadata, were checked again after this GUI session and remained unchanged.
