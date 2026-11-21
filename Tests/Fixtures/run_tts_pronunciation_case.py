#!/usr/bin/env python3
"""Offline test of actual AppState/LocalSpeechGate using disposable app sources."""
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
    source, count = re.subn(expression, "    " + signature + " {\n        " + replacement + "\n    }",
                            source, count=1, flags=re.S)
    if count != 1:
        raise RuntimeError("test factory seam changed: " + signature)
    path.write_text(source)


build = REPO / "build"
build.mkdir(exist_ok=True)
cache = build / "clt-check" / "cache"
cache.mkdir(parents=True, exist_ok=True)
with tempfile.TemporaryDirectory(prefix="tts-pronunciation-case-", dir=str(build)) as temp:
    scratch = Path(temp)
    # Use only a disposable profile. Original Secrets.swift is never compiled.
    profile = scratch / "profile"
    profile.mkdir(mode=0o700)
    copy = scratch / "Sources"
    shutil.copytree(REPO / "Sources", copy)
    (copy / "App" / "Secrets.swift").write_text('''import Foundation
    enum Secrets {
        static let appSupportDir = ProcessInfo.processInfo.environment["TTS_PRONUNCIATION_FIXTURE_PROFILE"]!
        static var elevenLabsKey: String? { nil }
        static var geminiKey: String? { nil }
        static var zaiKey: String? { nil }
        static func endpointKey(_ id: UUID) -> String? { nil }
        static func writeEndpointKey(_ id: UUID, _ value: String) { preconditionFailure("fixture must not write keys") }
    }
''')
    state = copy / "App" / "AppState.swift"
    replace_factory(state, "private func makeBackend() -> TTSBackend?",
                    "return PronunciationCase.CaptureOnlyEngine()")
    replace_factory(state, "private func makeNormalizer(instruction: String) -> Normalizing?",
                    "return PronunciationCase.FakeNormalizer(instruction: instruction)")
    sources = [str(path) for path in sorted(copy.rglob("*.swift")) if path.name != "main.swift"]
    binary = scratch / "case-test"
    sdk = subprocess.check_output(["/usr/bin/xcrun", "--sdk", "macosx26.5", "--show-sdk-path"], text=True).strip()
    env = dict(os.environ, SDKROOT=sdk, CLANG_MODULE_CACHE_PATH=str(cache),
               TTS_PRONUNCIATION_FIXTURE_PROFILE=str(profile))
    subprocess.run(["/usr/bin/swiftc", "-Onone", "-o", str(binary), *sources, str(HERE / "TTSPronunciationCase.swift"),
                    "-framework", "AppKit", "-framework", "SwiftUI", "-framework", "AVFoundation", "-framework", "Carbon",
                    "-framework", "ApplicationServices", "-lsqlite3"], check=True, timeout=140, env=env)
    # The execution context contains no provider or ambient application variables.
    subprocess.run([str(binary)], check=True, timeout=15, env={
        "PATH": "/usr/bin:/bin", "HOME": str(scratch), "TTS_PRONUNCIATION_FIXTURE_PROFILE": str(profile),
    })
