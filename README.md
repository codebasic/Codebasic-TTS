# SelectedTextTTS

macOS menu-bar utility: select text anywhere → right-click → **Services → "Read with
SelectedTextTTS"** → high-quality TTS reads it aloud, with per-sentence caching.

This repo is built **without Xcode** (only Command Line Tools are installed). A small
`build.sh` compiles with `swiftc` and assembles the `.app` bundle by hand. It is still a
plain AppKit project and can be imported into Xcode later if desired.

## Status: M1 (skeleton)

M1 = menu-bar agent + macOS Services registration + selected-text logging. **No audio yet.**
The `TTSBackend` protocol (the pluggable engine abstraction) is defined; only a no-op
`StubBackend` is wired in. Audio playback arrives in M2.

## Build & run

```bash
./build.sh          # build → install to ~/Applications → register Services → launch
./build.sh dev      # build → run in THIS terminal (stdout/os_log visible, no install)
./build.sh build    # build into ./build only
./build.sh logs     # tail the app's unified logs
./build.sh clean    # remove ./build
```

> Launch Services only reliably scans `~/Applications` and `/Applications`, so `./build.sh`
> installs there. Running the `.app` from `./build` may **not** make the Service appear.

## Stable signing (keep the global-hotkey Accessibility grant across rebuilds)

The global hotkeys (⌃⌥⌘R read, ⌃⌥⌘E explain) need **Accessibility** permission. With
ad-hoc signing the grant is bound to the binary's cdhash, so every rebuild silently
invalidates it — the toggle still shows *on* in System Settings, but pressing the hotkey
just re-opens the permission prompt. Sign with a **stable self-signed identity** to fix this
once and for all.

One-time cert creation (Keychain Access → Certificate Assistant → **Create a Certificate…**):

- **Name:** `Codebasic TTS Local`
- **Identity Type:** Self-Signed Root
- **Certificate Type:** Code Signing
- Create (it lands in your *login* keychain).

Then:

```bash
./build.sh                                              # now signs with the cert (see its log line)
tccutil reset Accessibility com.seongjoo.SelectedTextTTS  # clear the stale grant once
# press ⌃⌥⌘R → grant in System Settings → Privacy & Security → Accessibility
```

After this, rebuilds keep the permission. `build.sh` auto-detects the identity by name; override
with `CODESIGN_IDENTITY="…" ./build.sh` if you named it differently.

## Smoke test (M1)

1. `./build.sh` — installs, registers, and launches the app (🔊 appears in the menu bar).
2. In **TextEdit**, type and select a line of text.
3. Right-click → **Services → "Read with SelectedTextTTS"** (or the app menu → Services).
4. Confirm it fired:
   - menu-bar 🔊 briefly flips to 🔈,
   - its menu's "Last selection: …" updates,
   - `./build.sh logs` shows `Service fired: received N chars`.

For fast iteration during development, prefer `./build.sh dev`: it runs the binary in the
foreground so logs print straight to your terminal. (The Services menu item still resolves
to the copy registered in `~/Applications`, so keep one `./build.sh` install around.)

## Service not appearing in the menu?

Order of things to try:

1. `./build.sh` again (re-runs `lsregister -f` + `pbs -update/-flush`).
2. Make sure you tested from an app that exposes Services well (TextEdit is reliable).
3. Manually re-register:
   ```bash
   /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
     -f ~/Applications/SelectedTextTTS.app
   /System/Library/CoreServices/pbs -update
   ```
4. **Last resort:** log out and back in. `pbs` sometimes only rescans on session start;
   a missing menu item after the steps above is a registration quirk, *not* a code bug.

## Layout

```
SelectedTextTTS/
├── build.sh                       # swiftc build + bundle assembly + LS registration
├── Resources/Info.plist           # LSUIElement + NSServices definition
└── Sources/
    ├── App/main.swift             # programmatic NSApplication entry point
    ├── App/AppDelegate.swift      # menu-bar item, Services registration, selection handler
    ├── Service/ServiceProvider.swift  # NSServices handler (readSelectedText:userData:error:)
    ├── Core/Logging.swift         # os_log wrappers (why: LSUIElement print() is invisible)
    └── TTS/TTSBackend.swift       # TTSBackend protocol + VoiceConfig + StubBackend
```

## Roadmap

| Milestone | Scope |
|-----------|-------|
| **M1 ✅** | Menu-bar agent, Services registration, selected-text logging |
| M2 | ElevenLabs `/stream` → `AVQueuePlayer`, one-shot playback (no cache) |
| M3 | `NLTokenizer` sentence segmentation + per-segment disk cache |
| M4 | Partial / suffix-extended selection reuse |
| M5 | Local `Qwen3MLXBackend` (Python `mlx-audio` sidecar), backend toggle |
| M6 | Keychain API key, error/offline handling, voice-selection UI |

### Note on the local model

The handoff's final line asks to "run the local model first in M1." That is deferred on
purpose: `mlx` / `mlx_audio` are not importable in this machine's Python (3.14.5 — too new
for current MLX wheels), so the local engine needs its own venv (Python 3.11/3.12) set up as
a parallel track before M5. M1 ships the skeleton + the backend abstraction so either engine
can drop in behind `TTSBackend`. Voice-clone assets already exist in the repo root
(`ref_sj.wav`, `voice_clone_prompt_sj.pt`, `ref_text.txt`).
```
