#!/usr/bin/env python3
"""Check real AppKit menu/alert wiring offscreen with a synthetic app-owned profile."""
import json
from pathlib import Path
import shutil
import subprocess
import tempfile

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
CACHE = REPO / "build" / "clt-check" / "cache"
CACHE.mkdir(parents=True, exist_ok=True)

with tempfile.TemporaryDirectory(prefix="u", dir=REPO / "build") as temp:
    root = Path(temp)
    profile = root / "profile"
    profile.mkdir(mode=0o700)
    (profile / "settings.json").write_text(json.dumps({"backend":"local", "endpoints":[], "glossary":[]}))
    sources = root / "Sources"
    shutil.copytree(REPO / "Sources", sources)
    (sources / "App" / "Secrets.swift").write_text('''import Foundation
    enum Secrets {
        static let appSupportDir = ProcessInfo.processInfo.environment["TTS_APPROVAL_FIXTURE_PROFILE"]!
        static var elevenLabsKey: String? { nil }
        static var geminiKey: String? { nil }
        static var zaiKey: String? { nil }
        static func endpointKey(_ id: UUID) -> String? { nil }
        static func writeEndpointKey(_ id: UUID, _ value: String) { preconditionFailure("fixture must not write keys") }
    }
''')
    app = sources / "App" / "AppDelegate.swift"
    with app.open("a") as f:
        f.write('''\nextension AppDelegate {
    func syntheticInstructionFixtureSetUp() { setUpMainMenu(); observeState() }
}\n''')
    socket = sources / "App" / "LocalInstructionSocket.swift"
    source = socket.read_text()
    gate = r'"/private/tmp/codebasic-tts-mcp-\(getuid())"'
    assert source.count(gate) == 1
    socket.write_text(source.replace(gate, 'ProcessInfo.processInfo.environment["TTS_APPROVAL_FIXTURE_ROOT"]!'))
    paths = [str(x) for x in sorted(sources.rglob("*.swift")) if x.name != "main.swift"]
    executable = root / "approval-test"
    sdk = subprocess.check_output(["/usr/bin/xcrun", "--sdk", "macosx26.5", "--show-sdk-path"], text=True).strip()
    env = {"PATH":"/usr/bin:/bin", "HOME":str(root), "TTS_APPROVAL_FIXTURE_ROOT":str(root),
           "TTS_APPROVAL_FIXTURE_PROFILE":str(profile)}
    subprocess.run(["/usr/bin/swiftc", "-Onone", "-o", str(executable), *paths,
                    str(HERE / "TTSInstructionApprovalUI.swift"), "-framework", "AppKit", "-framework", "SwiftUI",
                    "-framework", "AVFoundation", "-framework", "Carbon", "-framework", "ApplicationServices",
                    "-lsqlite3"], check=True, timeout=130,
                   env={**env, "SDKROOT":sdk, "CLANG_MODULE_CACHE_PATH":str(CACHE)})
    subprocess.run([str(executable)], check=True, timeout=12, env=env)
