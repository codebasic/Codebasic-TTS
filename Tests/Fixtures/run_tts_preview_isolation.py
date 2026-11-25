#!/usr/bin/env python3
"""Exercise preview startup data and account boundaries with a disposable home."""
import json
from pathlib import Path
import shutil
import subprocess
import tempfile

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
BUILD = REPO / "build"
CACHE = BUILD / "clt-check" / "preview-cache"
CACHE.mkdir(parents=True, exist_ok=True)

with tempfile.TemporaryDirectory(prefix="preview-isolation-", dir=BUILD) as temp:
    root = Path(temp)
    home = root / "home"
    production = home / "Library/Application Support/Codebasic TTS"
    production.mkdir(parents=True, mode=0o700)
    (production / "eleven_key").write_text("synthetic-production-key")
    (production / "88888888-8888-4888-8888-888888888888.key").write_text("synthetic-production-endpoint")
    (production / "settings.json").write_text(json.dumps({"voiceName": "SYNTHETIC PRODUCTION VOICE"}))
    before = {path.name: path.read_bytes() for path in production.iterdir()}

    sources = root / "Sources"
    shutil.copytree(REPO / "Sources", sources)
    runtime = sources / "Core/TTSRuntime.swift"
    text = runtime.read_text()
    assert text.count("NSHomeDirectory()") == 1
    runtime.write_text(text.replace("NSHomeDirectory()", 'ProcessInfo.processInfo.environment["TTS_TEST_HOME"]!'))
    with (sources / "App/AppDelegate.swift").open("a") as app:
        app.write("\nextension AppDelegate { func syntheticPreviewMenu() { setUpMainMenu() } }\n")
    swift_files = sorted(str(path) for path in sources.rglob("*.swift") if path.name != "main.swift")
    binary = root / "probe"
    sdk = subprocess.check_output(["/usr/bin/xcrun", "--sdk", "macosx26.5", "--show-sdk-path"], text=True).strip()
    env = {"PATH": "/usr/bin:/bin", "HOME": str(home), "TTS_TEST_HOME": str(home), "TMPDIR": str(root)}
    subprocess.run(
        ["/usr/bin/swiftc", "-D", "TTS_LOCAL_PREVIEW", "-o", str(binary), *swift_files,
         str(HERE / "TTSPreviewIsolation.swift"), "-framework", "AppKit", "-framework", "SwiftUI",
         "-framework", "AVFoundation", "-framework", "Carbon", "-framework", "ApplicationServices", "-lsqlite3"],
        check=True, timeout=130, env={**env, "SDKROOT": sdk, "CLANG_MODULE_CACHE_PATH": str(CACHE)},
    )
    subprocess.run([str(binary), str(home)], check=True, timeout=15, env=env, cwd=root)
    assert {path.name: path.read_bytes() for path in production.iterdir()} == before
    print("synthetic installed profile is byte-for-byte unchanged")
