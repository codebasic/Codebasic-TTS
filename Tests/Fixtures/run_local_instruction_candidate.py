#!/usr/bin/env python3
"""Exercise the actual Swift listener and production Python stdio adapter, offline."""
import hashlib
import json
import re
from pathlib import Path
import selectors
import subprocess
import tempfile

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
BODY = "합성 지시만 반환합니다. __init__, 0.84\n"
REVISION = hashlib.sha256(b"tts-profile-v1\0explain\0" + BODY.encode()).hexdigest()


def send(proc, value):
    proc.stdin.write(json.dumps(value, ensure_ascii=False) + "\n")
    proc.stdin.flush()


def line(proc):
    with selectors.DefaultSelector() as selector:
        selector.register(proc.stdout, selectors.EVENT_READ)
        if not selector.select(5):
            raise TimeoutError("probe output timed out")
        return proc.stdout.readline().strip()


def rpc(proc, request_id, method, params=None):
    req = {"jsonrpc":"2.0", "id":request_id, "method":method}
    if params is not None:
        req["params"] = params
    send(proc, req)
    response = json.loads(line(proc))
    assert response["id"] == request_id, response
    return response


def start_stdio(script, env, cwd):
    return subprocess.Popen(["/usr/bin/python3", "-I", "-B", str(script)], env=env, cwd=cwd,
                            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)


def init(proc):
    response = rpc(proc, 1, "initialize", {"protocolVersion":"2025-11-25", "capabilities":{},
                                         "clientInfo":{"name":"candidate-fixture", "version":"1"}})
    assert response["result"]["serverInfo"]["name"] == "codebasic-tts-instructions"
    assert "instructions" not in response["result"]
    send(proc, {"jsonrpc":"2.0", "method":"notifications/initialized"})
    tools = rpc(proc, 2, "tools/list")["result"]["tools"]
    assert len(tools) == 1 and tools[0]["name"] == "get_tts_instructions"
    assert tools[0]["annotations"]["readOnlyHint"] is True


def fetch(proc, name="explain", ident=3):
    return rpc(proc, ident, "tools/call", {"name":"get_tts_instructions", "arguments":{"profile":name}})["result"]


def stop(proc):
    if proc.poll() is None:
        proc.stdin.close()
        try:
            proc.wait(timeout=3)
        except subprocess.TimeoutExpired:
            proc.terminate()
            proc.wait(timeout=2)


build = REPO / "build"
cache = build / "clt-check" / "cache"
cache.mkdir(parents=True, exist_ok=True)
with tempfile.TemporaryDirectory(prefix="i", dir=build) as temp:
    root = Path(temp)
    env = {"PATH":"/usr/bin:/bin", "HOME":str(root)}
    sdk = subprocess.check_output(["/usr/bin/xcrun", "--sdk", "macosx26.5", "--show-sdk-path"], text=True).strip()
    binary = root / "probe"
    subprocess.run(["/usr/bin/swiftc", str(REPO / "Sources/Core/TTSRuntime.swift"), str(REPO / "Sources/App/LocalInstructionSocket.swift"),
                    str(HERE / "LocalInstructionSocketProbe.swift"), "-o", str(binary)], check=True, timeout=90,
                   env={**env, "SDKROOT":sdk, "CLANG_MODULE_CACHE_PATH":str(cache)})
    # Use an existing locally trusted signing identity; do not mint a test identity.
    trusted_app = build / "Codebasic TTS.app"
    subprocess.run(["/usr/bin/codesign", "--verify", "--strict", str(trusted_app)], check=True, timeout=10)
    signed = subprocess.run(["/usr/bin/codesign", "-dr", "-", str(trusted_app)],
                           check=True, capture_output=True, text=True, timeout=10)
    anchor = re.search(r'certificate\s+leaf\s*=\s*H["\']?([a-fA-F0-9]{40})', signed.stdout + signed.stderr)
    if anchor is None:
        raise RuntimeError("An already trusted signed app candidate is needed; this test will not enroll a new certificate")
    subprocess.run(["/usr/bin/codesign", "--force", "--sign", "Codebasic TTS Local", "--identifier",
                    "com.seongjoo.SelectedTextTTS", str(binary)], check=True, timeout=12)
    env["CODEBASIC_TTS_SIGNER_SHA1"] = anchor.group(1)
    # A relative socket under the fixture's build directory also fits AF_UNIX
    # when the checkout is in a deeply nested worktree.
    script = root / "mcp_tts_instructions.py"
    original = (REPO / "scripts/mcp_tts_instructions.py").read_text()
    needle = 'return Path("/private/tmp") / ("codebasic-tts-mcp-%d" % os.geteuid()) / "i.sock"'
    assert original.count(needle) == 1
    script.write_text(original.replace(needle, 'return Path('+json.dumps(root.name + "/i.sock")+')'))
    (root / "mcp_speech.py").write_bytes((REPO / "scripts/mcp_speech.py").read_bytes())
    (root / "tts_mcp_app_identity.py").write_bytes((REPO / "scripts/tts_mcp_app_identity.py").read_bytes())
    wrong_pin = "0" * 40 if anchor.group(1) != "0" * 40 else "1" * 40
    allowed, unrelated = start_stdio(script, env, build), start_stdio(script, env, build)
    wrong_signer = start_stdio(script, {**env, "CODEBASIC_TTS_SIGNER_SHA1": wrong_pin}, build)

    def launch(approved_pid):
        return subprocess.Popen([str(binary), str(approved_pid), root.name], cwd=build, env=env, stdin=subprocess.PIPE,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)

    server = None
    try:
        init(allowed); init(unrelated); init(wrong_signer)
        off = fetch(allowed)
        assert off["isError"] and str(allowed.pid) in off["content"][0]["text"]
        server = launch(wrong_signer.pid)
        assert line(server) == "ready"
        rejected_signer = fetch(wrong_signer)
        assert rejected_signer["isError"] and "structuredContent" not in rejected_signer
        stop(server); server = None
        assert not (root / "i.sock").exists()
        server = launch(allowed.pid)
        state = line(server)
        assert state == "ready", state
        assert (root / "i.sock").lstat().st_mode & 0o777 == 0o600
        rejected = fetch(unrelated)
        assert rejected["isError"] and "structuredContent" not in rejected
        wrong = fetch(allowed, "normalize", 4)
        assert wrong["isError"] and "structuredContent" not in wrong
        result = fetch(allowed, ident=5)
        expected = {"schema_version":1, "profile":"explain", "instructions":BODY, "revision":REVISION}
        assert not result["isError"] and result["structuredContent"] == expected, result
        assert result["content"] == [{"type":"text", "text":BODY}]
        assert fetch(allowed, ident=6) == result
        assert "error" in rpc(allowed, 7, "tools/call", {"name":"speak_text", "arguments":{"text":"never"}})
        server.stdin.write("revoke\n"); server.stdin.flush()
        assert line(server) == "revoked"
        assert not (root / "i.sock").exists()
        assert fetch(allowed, ident=8)["isError"]
        print("Swift -> Python stdio: default off; wrong signer rejected; approved exact revision only; other same-UID PID rejected; no speech tool; revoke works")
    finally:
        if server is not None:
            stop(server)
        stop(allowed); stop(unrelated); stop(wrong_signer)
