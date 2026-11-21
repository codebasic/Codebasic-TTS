#!/usr/bin/env python3
"""Native signed CLI + app-side gate, offscreen/synthetic; all files in build/."""
import json
import os
from pathlib import Path
import plistlib
import re
import selectors
import shutil
import subprocess
import tempfile

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
BUILD = Path(os.environ.get("TTS_BUILD_DIR", REPO / "build"))
SOURCES = REPO / "Sources"
APP_ID = "com.seongjoo.SelectedTextTTS"
FIXTURE_SELECTOR = "66666666-6666-4666-8666-666666666666"


def read(proc):
    with selectors.DefaultSelector() as handles:
        handles.register(proc.stdout, selectors.EVENT_READ)
        if not handles.select(5):
            raise TimeoutError("fixture did not respond")
        line = proc.stdout.readline()
        if not line:
            raise RuntimeError(f"fixture exited unexpectedly ({proc.wait(timeout=3)}): {proc.stderr.read()}")
        return line.strip()


def write(proc, message):
    proc.stdin.write(message + "\n")
    proc.stdin.flush()


def stop(proc):
    if proc.poll() is None:
        proc.stdin.close()
        try:
            proc.wait(timeout=3)
        except subprocess.TimeoutExpired:
            proc.terminate()
            proc.wait(timeout=2)


def rpc(proc, method, params=None):
    msg = {"jsonrpc":"2.0", "id":1, "method":method}
    if params is not None:
        msg["params"] = params
    write(proc, json.dumps(msg, ensure_ascii=False))
    return json.loads(read(proc))["result"]


def call(proc, name, **kwargs):
    return rpc(proc, "tools/call", {"name":name, "arguments":kwargs})


def initialize(proc):
    res = rpc(proc, "initialize", {"protocolVersion":"2025-11-25", "capabilities":{}})
    assert res["serverInfo"]["name"] == "codebasic-tts-agent"
    write(proc, '{"jsonrpc":"2.0","method":"notifications/initialized"}')
    assert {t["name"] for t in rpc(proc, "tools/list")["tools"]} == {"get_tts_instructions","submit_explanation_draft"}


def command(proc, instruction):
    write(proc, instruction)
    return read(proc)


def message(result):
    return result["content"][0]["text"]


def main():
    app = BUILD / "Codebasic TTS.app"
    subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)], check=True, timeout=12)
    sig = subprocess.run(["/usr/bin/codesign", "-dr", "-", str(app)], check=True, text=True, capture_output=True, timeout=12)
    leaf = re.search(r'certificate leaf = H"([a-fA-F0-9]{40})"', sig.stderr + sig.stdout)
    assert leaf, "signed local fixture requires the existing supported certificate"
    with tempfile.TemporaryDirectory(prefix="v", dir=BUILD) as temp:
        root = Path(temp)
        assert len(os.fsencode(root / "i.sock")) < 104, "fixture AF_UNIX path too long"
        new_helper = root / "AgentCatalogMCP.swift"
        original = (REPO/"Helpers/AgentCatalogMCP.swift").read_text()
        path = r'"/private/tmp/codebasic-tts-mcp-\(getuid())"'
        assert original.count(path) == 1
        new_helper.write_text(original.replace(path, json.dumps(str(root))))
        sdk = subprocess.check_output(["/usr/bin/xcrun","--sdk","macosx26.5","--show-sdk-path"], text=True).strip()
        env = {"PATH":"/usr/bin:/bin", "HOME":str(root), "TMPDIR":str(root),
               "CODEBASIC_TTS_SIGNER_SHA1":leaf.group(1)}
        compile_env = {**env, "SDKROOT":sdk, "CLANG_MODULE_CACHE_PATH":str(BUILD/"module-cache")}
        common = [SOURCES/"App/AgentPeerSigning.swift", SOURCES/"Core/AgentCatalog.swift"]
        server_src = [SOURCES/"App/LocalInstructionSocket.swift", SOURCES/"App/AgentSessionController.swift",
                      SOURCES/"Core/AgentDeliveryProofs.swift", SOURCES/"Core/ExplanationDraftWorkspace.swift",
                      HERE / "LocalExplanationDraftSocketProbe.swift"]
        other_src = root / "Other.swift"
        other_src.write_text("import Foundation\n@main struct Other { static func main() { while readLine() != nil {} } }\n")
        for binary, identifier, files in ((root/"helper", APP_ID+".agent-helper",[new_helper]),
                                           (root/"server", APP_ID,server_src),
                                           (root/"other", APP_ID+".agent-helper",[other_src])):
            subprocess.run(["/usr/bin/swiftc","-framework","Security",*map(str,common+files),"-o",str(binary)],
                           check=True, timeout=120, env=compile_env)
            subprocess.run(["/usr/bin/codesign","--force","--options","runtime","--timestamp=none",
                            "--sign",os.environ.get("CODESIGN_IDENTITY","Codebasic TTS Local"),
                            "--identifier",identifier,str(binary)], check=True, timeout=15)
        shutil.copy2(root / "server", root / "unhardened")
        subprocess.run(["/usr/bin/codesign","--force","--timestamp=none",
                        "--sign",os.environ.get("CODESIGN_IDENTITY","Codebasic TTS Local"),
                        "--identifier",APP_ID,str(root / "unhardened")], check=True, timeout=15)
        # Known zero-capability value; explicitly does not enable a network client.
        marker = {"com.apple.security.network.client": False}
        entitlements = root / "TestEntitlements.plist"
        entitlements.write_bytes(plistlib.dumps(marker))
        for base, identifier in (("helper", APP_ID+".agent-helper"), ("server", APP_ID)):
            entitled = root / ("entitled-" + base)
            shutil.copy2(root / base, entitled)
            subprocess.run(["/usr/bin/codesign","--force","--timestamp=none","--options","runtime",
                            "--sign",os.environ.get("CODESIGN_IDENTITY","Codebasic TTS Local"),
                            "--identifier",identifier,"--entitlements",str(entitlements),str(entitled)], check=True, timeout=15)
            subprocess.run(["/usr/bin/codesign", "--verify", "--strict", str(entitled)], check=True, timeout=15)
            embedded = subprocess.check_output(["/usr/bin/codesign","--display","--xml","--entitlements","-",str(entitled)],
                                               stderr=subprocess.DEVNULL, timeout=12)
            assert plistlib.loads(embedded) == marker

        def launch(path, *args, extra=None):
            return subprocess.Popen([str(root/path),*args], env={**env,**(extra or {})}, stdin=subprocess.PIPE,
                                    stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)

        server = launch("server", str(root))
        unhardened = launch("unhardened", str(root))
        entitled_server = launch("entitled-server", str(root))
        entitled_helper = launch("entitled-helper")
        exact_entitled_pin = launch("server", str(root), "entitled-helper")
        a, b, wrong = launch("helper"), launch("helper"), launch("helper",extra={"CODEBASIC_TTS_SIGNER_SHA1":"0"*40})
        other = launch("other")
        try:
            assert read(server) == "ready"
            assert read(unhardened) == "ready"
            assert read(entitled_server) == "ready"
            assert read(exact_entitled_pin) == "ready"
            for h in a,b,wrong,entitled_helper: initialize(h)
            assert command(entitled_server, "inspect-signing-info") == "dict+raw"
            print("Security.framework signing-information flag returned both the generic entitlement dictionary and raw blob")
            assert command(entitled_server, f"bind {a.pid}") == "no" # same signer, app ID, and hardened runtime; self check
            assert command(exact_entitled_pin, f"bind {entitled_helper.pid}") == "no" # exact bundled test hash matches; live PID check
            assert command(entitled_server, f"observe-request {a.pid}") == "ok"
            assert call(a,"get_tts_instructions",profile=FIXTURE_SELECTOR)["isError"]
            assert command(entitled_server, "stop-observing") == "0" # same signer/ID; helper's kernel peer check blocked before any request
            assert command(server, f"observe-request {a.pid}") == "ok"
            assert call(a,"get_tts_instructions",profile=FIXTURE_SELECTOR)["isError"] # probe intentionally sends no response
            assert command(server, "stop-observing") == "1" # positive control: same request reached an entitlement-free signing peer
            print("Entitled app/helper rejected by app self-check, exact-pinned helper pairing, and helper socket peer authentication")
            assert command(unhardened, f"bind {a.pid}") == "no" # wrong runtime policy, same signer and ID
            assert command(server, f"bind {os.getpid()}") == "no" # unsigned/wrong code
            assert command(server, f"bind {other.pid}") == "no" # same signer and identifier, different code
            assert command(server, f"bind {wrong.pid}") == "ok" and command(server,"share") == "ok"
            assert call(wrong,"get_tts_instructions",profile=FIXTURE_SELECTOR)["isError"]
            assert command(server, f"bind {a.pid}") == "ok"
            assert call(a,"get_tts_instructions",profile=FIXTURE_SELECTOR)["isError"] # default off on rebind
            assert command(server, "share") == "ok"
            assert call(b,"get_tts_instructions",profile=FIXTURE_SELECTOR)["isError"]
            reply = call(a,"get_tts_instructions",profile=FIXTURE_SELECTOR)
            assert not reply["isError"] and reply["structuredContent"]["instructions"].encode() == "합성 지시 e\u0301\n".encode()
            assert "proof" not in json.dumps(reply) and "Owner label" not in json.dumps(reply)
            old = reply["structuredContent"]["revision"]
            fields = dict(profile=FIXTURE_SELECTOR, revision=old, idempotency_key="one",display_text="as_frame",speech_text="애즈 프레임")
            assert call(a,"submit_explanation_draft",**fields)["isError"] # receiving still off
            assert command(server, "receipt") == "ok"
            assert command(server, "change") == "ok" and command(server, "revert") == "ok"
            assert call(a,"get_tts_instructions",profile=FIXTURE_SELECTOR)["isError"] # edit/revert never restores
            assert call(b,"submit_explanation_draft",**fields)["isError"]
            assert not call(a,"submit_explanation_draft",**fields)["isError"] # actual older proof
            assert "Already received" in message(call(a,"submit_explanation_draft",**fields))
            assert "Already received" in message(call(a,"submit_explanation_draft",**{**fields,"idempotency_key":"different-key"}))
            assert call(a,"submit_explanation_draft",**{**fields,"speech_text":"other"})["isError"]
            snap = json.loads(command(server,"snapshot"))
            assert snap["count"] == 1 and snap["editor"] == "manual untouched" and snap["old"] == [True]
            assert snap["labels"] == ["Owner label"] and len(snap["pairs"][0]) == 36
            assert command(server,"share") == "ok"
            new = call(a,"get_tts_instructions",profile=FIXTURE_SELECTOR)["structuredContent"]["revision"]
            assert new != old
            assert command(server,"stopreceipt") == "ok" and command(server,"receipt") == "ok"
            revoked = call(a,"submit_explanation_draft",**{**fields,"revision":new,"idempotency_key":"two"})
            assert revoked["isError"] and "proof" in message(revoked)
            read_again = call(a,"get_tts_instructions",profile=FIXTURE_SELECTOR)
            assert read_again["structuredContent"]["revision"] == new
            assert command(server,"delete") == "ok"
            assert call(a,"submit_explanation_draft",**{**fields,"revision":new,"idempotency_key":"two"})["isError"]
            assert json.loads(command(server,"snapshot"))["count"] == 1
            assert command(server, f"bind {b.pid}") == "ok"
            assert not json.loads(command(server,"snapshot"))["receiving"]
            print("signed Agent IPC: exact delivery, wrong signer/pid/code/runtime, default off, independent grants, old proof, dedup, revoke/revert/delete and pasted editor untouched")
        finally:
            for proc in server,unhardened,entitled_server,entitled_helper,exact_entitled_pin,a,b,wrong,other: stop(proc)


if __name__ == "__main__":
    main()
