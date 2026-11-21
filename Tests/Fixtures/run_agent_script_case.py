#!/usr/bin/env python3
"""Offline check of the 해설 tab handoff on the production AppState/AppDelegate/sockets/view.

Disposable copy of Sources with only these seams replaced: Secrets (temporary profile, no keys),
the TTS backend (captures synthesis input, emits no audio), the normalizer / explainer factories
and the model-list fetch (counted, never reach a network), and the socket directory (temporary).
No real settings, keys, user prompts, providers or the installed app are touched.
"""
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
CACHE = REPO / "build" / "clt-check" / "cache"
CACHE.mkdir(parents=True, exist_ok=True)


def replace_body(path, signature, replacement):
    source = path.read_text()
    expression = r"    " + re.escape(signature) + r" \{.*?\n    \}"
    source, count = re.subn(expression, lambda _: "    " + signature + " {\n        " + replacement + "\n    }",
                            source, count=1, flags=re.S)
    if count != 1:
        raise RuntimeError("test seam changed: " + signature)
    path.write_text(source)


def replace_once(path, old, new):
    source = path.read_text()
    if source.count(old) != 1:
        raise RuntimeError("test seam changed: " + old)
    path.write_text(source.replace(old, new))


with tempfile.TemporaryDirectory(prefix="cbtts-agent-", dir="/private/tmp") as temp:
    root = Path(temp)
    os.chmod(root, 0o700)
    profile = root / "profile"
    profile.mkdir(mode=0o700)
    sources = root / "Sources"
    shutil.copytree(REPO / "Sources", sources)
    (sources / "App" / "Secrets.swift").write_text('''import Foundation
    enum Secrets {
        static let appSupportDir = ProcessInfo.processInfo.environment["TTS_AGENT_FIXTURE_PROFILE"]!
        static var elevenLabsKey: String? { nil }
        static var geminiKey: String? { nil }
        static var zaiKey: String? { nil }
        static func endpointKey(_ id: UUID) -> String? { nil }
        static func writeEndpointKey(_ id: UUID, _ value: String) { preconditionFailure("fixture must not write keys") }
    }
''')
    state = sources / "App" / "AppState.swift"
    replace_body(state, "private func makeBackend() -> TTSBackend?", "return AgentScriptCase.CaptureOnlyEngine()")
    replace_body(state, "private func makeNormalizer(instruction: String) -> Normalizing?",
                 "return AgentScriptCase.FakeNormalizer()")
    replace_body(state, "private func makeExplainer() -> EndpointGenerator?",
                 "AgentScriptCase.log.recordExplainer(); return nil")
    replace_body(state, "func refreshEndpointModels(_ endpoint: CustomEndpoint)",
                 "AgentScriptCase.log.recordModelQuery()")
    gate = r'"/private/tmp/codebasic-tts-mcp-\(getuid())"'
    fixture_root = 'ProcessInfo.processInfo.environment["TTS_AGENT_FIXTURE_ROOT"]!'
    replace_once(sources / "App" / "LocalInstructionSocket.swift", gate, fixture_root)
    replace_once(sources / "App" / "LocalScriptInboxSocket.swift", gate, fixture_root)
    with (sources / "App" / "AppDelegate.swift").open("a") as f:
        f.write('''\nextension AppDelegate {
    func agentScriptFixtureSetUp() { setUpMainMenu(); observeState(); wireAgentHandoff() }
}\n''')
    paths = [str(x) for x in sorted(sources.rglob("*.swift")) if x.name != "main.swift"]
    binary = root / "agent-script-case"
    sdk = subprocess.check_output(["/usr/bin/xcrun", "--sdk", "macosx26.5", "--show-sdk-path"], text=True).strip()
    env = {"PATH": "/usr/bin:/bin", "HOME": str(root), "TTS_AGENT_FIXTURE_ROOT": str(root),
           "TTS_AGENT_FIXTURE_PROFILE": str(profile)}
    subprocess.run(["/usr/bin/swiftc", "-Onone", "-o", str(binary), *paths, str(HERE / "AgentScriptCase.swift"),
                    "-framework", "AppKit", "-framework", "SwiftUI", "-framework", "AVFoundation", "-framework", "Carbon",
                    "-framework", "ApplicationServices", "-lsqlite3"], check=True, timeout=240,
                   env={**env, "SDKROOT": sdk, "CLANG_MODULE_CACHE_PATH": str(CACHE)})
    subprocess.run([str(binary)], check=True, timeout=60, env=env)
    leftovers = sorted(p.name for p in root.iterdir() if p.name.endswith(".sock"))
    assert not leftovers, leftovers
    saved = json.loads((profile / "settings.json").read_text())
    assert saved.get("agentPrompt.full") == "SYNTHETIC 전체 해설 지시" and "agentPrompt.delta" not in saved, sorted(saved)
    print("settings: only the customized 양식 persisted; sockets cleaned up")
