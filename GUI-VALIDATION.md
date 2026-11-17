# Offline GUI validation

See V2-IMPLEMENTATION.md for the verified flow table, isolation controls, exact limitations and Claude design-advice disposition.

Executed built binary with CODEBASIC_V2_OFFLINE=1 and CODEBASIC_V2_TEST_ROOT=/tmp/codebasic-v2-gui-review. CUA verified startup, image attachment, message send, mock response, explicit playback/stop, slow-generation cancellation, conversation selection, settings round trip, normal quit and restart restoration. V1 was simultaneously running throughout; its UI and data were not operated on. Both V2 process sessions exited 0 after normal GUI quit.

Test data remains in /tmp/codebasic-v2-gui-review for inspection. It contains synthetic text/images only. Playback was a state mock with fake bytes, not sound-device output. No paid provider or ElevenLabs requests were made.
