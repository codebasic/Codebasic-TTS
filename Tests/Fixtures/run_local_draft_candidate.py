#!/usr/bin/env python3
"""Signed, disposable Swift inbox ↔ production MCP adapter; no real app or provider."""
import json
import os
from pathlib import Path
import re
import selectors
import shutil
import subprocess
import tempfile
import time

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
BUILD = Path(os.environ.get("TTS_BUILD_DIR", REPO / "build"))
SOURCES = REPO / "Sources"


def line(proc):
    with selectors.DefaultSelector() as selector:
        selector.register(proc.stdout, selectors.EVENT_READ)
        if not selector.select(5):
            raise TimeoutError("fixture output timed out")
        return proc.stdout.readline().strip()


def write(proc, message):
    proc.stdin.write(message + "\n")
    proc.stdin.flush()


def close(proc):
    if proc and proc.poll() is None:
        proc.stdin.close()
        try:
            proc.wait(timeout=3)
        except subprocess.TimeoutExpired:
            proc.terminate()
            proc.wait(timeout=2)


def rpc(proc, method, params=None, ident=1):
    request = {"jsonrpc": "2.0", "method": method, "id": ident}
    if params is not None:
        request["params"] = params
    write(proc, json.dumps(request, ensure_ascii=False))
    return json.loads(line(proc))


def initialize(proc):
    init = rpc(proc, "initialize", {"protocolVersion": "2025-11-25", "capabilities": {},
                                  "clientInfo": {"name": "draft-probe", "version": "1"}})
    assert init["result"]["serverInfo"]["name"] == "codebasic-tts-draft"
    write(proc, '{"jsonrpc":"2.0","method":"notifications/initialized"}')
    tools = rpc(proc, "tools/list")["result"]["tools"]
    assert [tool["name"] for tool in tools] == ["submit_explanation_draft"]


def submit(proc, args):
    result = rpc(proc, "tools/call", {"name": "submit_explanation_draft", "arguments": args})["result"]
    return result["content"][0]["text"].split(":", 1)[0], result["isError"]


def snapshot(proc):
    write(proc, "snapshot")
    return json.loads(line(proc))


cache = BUILD / "cache"
cache.mkdir(parents=True, exist_ok=True)
candidate = BUILD / "Codebasic TTS.app"
subprocess.run(["/usr/bin/codesign", "--verify", "--strict", str(candidate)], check=True, timeout=12)
meta = subprocess.run(["/usr/bin/codesign", "-dr", "-", str(candidate)], check=True, text=True,
                      capture_output=True, timeout=12)
anchor = re.search(r'certificate\s+leaf\s*=\s*H["\']?([a-fA-F0-9]{40})', meta.stdout + meta.stderr)
if not anchor:
    raise RuntimeError("The test candidate must be signed with the existing locally trusted certificate")

with tempfile.TemporaryDirectory(prefix="cbtts-draft-", dir="/private/tmp") as directory:
    tmp = Path(directory)
    probe = tmp / "draft-probe"
    sdk = subprocess.check_output(["/usr/bin/xcrun", "--sdk", "macosx26.5", "--show-sdk-path"], text=True).strip()
    env = {"PATH": "/usr/bin:/bin", "HOME": str(tmp), "CODEBASIC_TTS_SIGNER_SHA1": anchor.group(1)}
    subprocess.run(["/usr/bin/swiftc", "-o", str(probe),
                    str(SOURCES / "App/LocalInstructionSocket.swift"),
                    str(SOURCES / "App/LocalExplanationDraftSocket.swift"),
                    str(SOURCES / "Core/ExplanationDraftWorkspace.swift"),
                    str(HERE / "LocalExplanationDraftSocketProbe.swift")],
                   env={**env, "SDKROOT": sdk, "CLANG_MODULE_CACHE_PATH": str(cache)}, check=True, timeout=100)
    subprocess.run(["/usr/bin/codesign", "--force", "--sign", os.environ.get("CODESIGN_IDENTITY", "Codebasic TTS Local"),
                    "--identifier", "com.seongjoo.SelectedTextTTS", str(probe)], check=True, timeout=12)
    for name in ("mcp_speech.py", "tts_mcp_app_identity.py"):
        shutil.copyfile(REPO / "scripts" / name, tmp / name)
    adapter = tmp / "mcp_tts_draft.py"
    original = (REPO / "scripts/mcp_tts_draft.py").read_text()
    needle = 'return Path("/private/tmp") / ("codebasic-tts-mcp-%d" % os.geteuid()) / "d.sock"'
    assert original.count(needle) == 1
    adapter.write_text(original.replace(needle, "return Path(" + json.dumps(str(tmp / "d.sock")) + ")"))

    def helper(config):
        process = subprocess.Popen(["/usr/bin/python3", "-I", "-B", str(adapter)],
                                   env=config, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                   stderr=subprocess.PIPE, text=True)
        return process

    def start(peer, lifetime=600_000):
        process = subprocess.Popen([str(probe), str(peer.pid), str(tmp), str(lifetime)], env=env, text=True,
                                   stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        assert line(process) == "ready", process.stderr.read()
        return process

    allowed, other = helper(env), helper(env)
    wrong = helper({**env, "CODEBASIC_TTS_SIGNER_SHA1": "0" * 40})
    server = None
    first = {"idempotency_key": "one", "display_text": "as_frame 옵션", "speech_text": "애즈 프레임 옵션"}
    try:
        for process in (allowed, other, wrong):
            initialize(process)
        assert submit(allowed, first) == ("offline", True)
        server = start(wrong)
        assert submit(wrong, first) == ("unsafe", True)
        assert snapshot(server)["count"] == 0
        close(server); server = None
        server = start(allowed)
        assert not (tmp / "s.sock").exists() and not (tmp / "i.sock").exists()
        assert submit(other, first)[1] is True
        assert submit(allowed, first) == ("accepted", False)
        assert submit(allowed, first) == ("duplicate", False)
        assert submit(allowed, {**first, "speech_text": "다른 대본"}) == ("conflict", True)
        assert snapshot(server) == {"count": 1, "editor": "synthetic manual text",
                                     "lastDisplay": first["display_text"], "lastSpeech": first["speech_text"]}
        for n in range(2, 9):
            assert submit(allowed, {"idempotency_key": f"queued-{n}", "display_text": "가" * 2730}) == ("accepted", False)
        assert submit(allowed, {"idempotency_key": "over", "display_text": "가득 참"}) == ("busy", True)
        assert snapshot(server)["count"] == 8
        write(server, "revoke")
        assert line(server) == "revoked" and not (tmp / "d.sock").exists()
        assert submit(allowed, first) == ("offline", True)
        close(server); server = None
        server = start(allowed, lifetime=150)
        time.sleep(.25)
        assert submit(allowed, first)[1] is True and snapshot(server)["count"] == 0
        print("signed draft IPC: opt-in, wrong pin/PID, arrival/retry/conflict/limit, no editor overwrite, separated text, revoke/expiry")
    finally:
        close(server)
        close(allowed)
        close(other)
        close(wrong)
