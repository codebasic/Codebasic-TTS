# Offline GUI validation

See V2-IMPLEMENTATION.md for the verified flow table, isolation controls, exact limitations and Claude design-advice disposition.

Executed built binary with CODEBASIC_V2_OFFLINE=1 and CODEBASIC_V2_TEST_ROOT=/tmp/codebasic-v2-gui-review. CUA verified startup, image attachment, message send, mock response, explicit playback/stop, slow-generation cancellation, conversation selection, settings round trip, normal quit and restart restoration. V1 was simultaneously running throughout; its UI and data were not operated on. Both V2 process sessions exited 0 after normal GUI quit.

Test data remains in /tmp/codebasic-v2-gui-review for inspection. It contains synthetic text/images only. Playback was a state mock with fake bytes, not sound-device output. No paid provider or ElevenLabs requests were made.

## Final post-performance-patch rerun

The final app built and signed successfully, and all 38 chat mock checks, offline/permit checks, production Gemini transport mock and original regressions passed. It was launched with CODEBASIC_V2_OFFLINE=1 and CODEBASIC_V2_TEST_ROOT=/tmp/codebasic-v2-bench-300, containing only generated synthetic history (300 seed conversations, 6,000 seed messages and approximately 83 MB of synthetic PNGs, plus a few benchmark turns).

CUA could not inspect or operate the app because the Mac was locked and automatic unlock was unavailable. A manual-unlock request was issued; no lock bypass was attempted. Therefore the full flow on this final revision and actual large-list GUI responsiveness remain BLOCKED, not passed. The prior complete GUI sequence above was on 0bfb8f4; it must not be presented as the final post-cache-patch rerun. The offline app remained running for the unlock/resume step. Startup logged one nonfatal NSTableView reentrant-operation warning; its user-visible effect could not be checked while locked.

The authorized real Google/ElevenLabs check was completed separately through production V2 components while GUI access was blocked; see LIVE-VALIDATION.md. That check does not establish the live GUI flow.
