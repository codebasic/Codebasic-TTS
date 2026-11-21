#!/usr/bin/env python3
"""Offline end-to-end test of the redesigned Explain tab, AppState, AppDelegate, and local MCP sockets."""
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]


def replace_factory(path, signature, replacement):
    source = path.read_text()
    expression = r"    " + re.escape(signature) + r" \{.*?\n    \}"
    source, count = re.subn(
        expression,
        "    " + signature + " {\n        " + replacement + "\n    }",
        source,
        count=1,
        flags=re.S,
    )
    if count != 1:
        raise RuntimeError("test factory seam changed: " + signature)
    path.write_text(source)


def select_sdk():
    for args in (
        ["/usr/bin/xcrun", "--sdk", "macosx26.5", "--show-sdk-path"],
        ["/usr/bin/xcrun", "--show-sdk-path"],
    ):
        proc = subprocess.run(args, capture_output=True, text=True)
        if proc.returncode == 0 and proc.stdout.strip():
            return proc.stdout.strip()
    raise RuntimeError("No macOS SDK found via xcrun")


build = REPO / "build"
build.mkdir(exist_ok=True)
cache = build / "clt-check" / "cache"
cache.mkdir(parents=True, exist_ok=True)

with tempfile.TemporaryDirectory(prefix="cbtts-explain-wf-", dir="/private/tmp") as temp:
    root = Path(temp)
    profile = root / "profile"
    profile.mkdir(mode=0o700)
    (profile / "settings.json").write_text(json.dumps({
        "backend": "local",
        "endpoints": [],
        "glossary": [],
        "useCache": False,
        "normalize": False,
    }))

    sources = root / "Sources"
    shutil.copytree(REPO / "Sources", sources)

    (sources / "App" / "Secrets.swift").write_text("""import Foundation
enum Secrets {
    static let appSupportDir = ProcessInfo.processInfo.environment["TTS_WORKFLOW_FIXTURE_PROFILE"]!
    static var elevenLabsKey: String? { nil }
    static var geminiKey: String? { nil }
    static var zaiKey: String? { nil }
    static func endpointKey(_ id: UUID) -> String? { nil }
    static func writeEndpointKey(_ id: UUID, _ value: String) {
        preconditionFailure("fixture must not write keys")
    }
}
""")

    app_state = sources / "App" / "AppState.swift"
    replace_factory(
        app_state,
        "private func makeBackend() -> TTSBackend?",
        "return ExplainWorkflowProbe.CaptureOnlyBackend(app: self)",
    )
    replace_factory(
        app_state,
        "private func makeNormalizer(instruction: String) -> Normalizing?",
        "return ExplainWorkflowProbe.SpyNormalizer(instruction: instruction)",
    )

    app_delegate = sources / "App" / "AppDelegate.swift"
    with app_delegate.open("a") as f:
        f.write("""
extension AppDelegate {
    func explainWorkflowFixtureSetUp() { setUpMainMenu(); observeState() }
}
""")

    needle = r'"/private/tmp/codebasic-tts-mcp-\(getuid())"'
    for rel in ("LocalInstructionSocket.swift", "LocalExplainDraftSocket.swift"):
        sock = sources / "App" / rel
        text = sock.read_text()
        assert text.count(needle) == 1, f"expected single socket dir literal in {rel}"
        sock.write_text(text.replace(needle, 'ProcessInfo.processInfo.environment["TTS_WORKFLOW_FIXTURE_ROOT"]!'))

    paths = [str(x) for x in sorted(sources.rglob("*.swift")) if x.name != "main.swift"]
    binary = root / "explain-workflow-tests"
    sdk = select_sdk()
    compile_env = {
        **os.environ,
        "SDKROOT": sdk,
        "CLANG_MODULE_CACHE_PATH": str(cache),
    }
    subprocess.run(
        [
            "/usr/bin/swiftc",
            "-Onone",
            "-o",
            str(binary),
            *paths,
            str(HERE / "ExplainTabWorkflowTests.swift"),
            "-framework",
            "AppKit",
            "-framework",
            "SwiftUI",
            "-framework",
            "AVFoundation",
            "-framework",
            "Carbon",
            "-framework",
            "ApplicationServices",
            "-lsqlite3",
        ],
        check=True,
        timeout=160,
        env=compile_env,
    )

    run_env = {
        "PATH": "/usr/bin:/bin",
        "HOME": str(root),
        "TTS_WORKFLOW_FIXTURE_ROOT": str(root),
        "TTS_WORKFLOW_FIXTURE_PROFILE": str(profile),
    }
    subprocess.run([str(binary)], check=True, timeout=30, env=run_env)
