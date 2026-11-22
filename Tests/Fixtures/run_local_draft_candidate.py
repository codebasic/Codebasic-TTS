#!/usr/bin/env python3
"""Native signed CLI + app-side gate, offscreen/synthetic; all files in build/."""
import json
import os
from pathlib import Path
import plistlib
import selectors
import socket
import shutil
import subprocess
import tempfile

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
BUILD = Path(os.environ.get("TTS_BUILD_DIR", REPO / "build")).resolve()
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
    assert {t["name"] for t in rpc(proc, "tools/list")["tools"]} == {"tts_agent_status","get_tts_instructions","submit_explanation_draft"}


def command(proc, instruction):
    write(proc, instruction)
    return read(proc)


def message(result):
    return result["content"][0]["text"]


def main():
    BUILD.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="v", dir=BUILD) as temp:
        root = Path(temp)
        new_helper = root / "AgentCatalogMCP.swift"
        original = (REPO/"Helpers/AgentCatalogMCP.swift").read_text()
        path = r'"/private/tmp/codebasic-tts-mcp-\(getuid())"'
        assert original.count(path) == 1
        new_helper.write_text(original.replace(path, '"ipc"'))
        sdk = subprocess.check_output(["/usr/bin/xcrun","--sdk","macosx26.5","--show-sdk-path"], text=True).strip()
        env = {"PATH":"/usr/bin:/bin", "HOME":str(root), "TMPDIR":str(root)}
        compile_env = {**env, "SDKROOT":sdk, "CLANG_MODULE_CACHE_PATH":str(BUILD/"module-cache")}
        common = [SOURCES/"App/AgentPeerSigning.swift", SOURCES/"Core/AgentCatalog.swift"]
        server_src = [SOURCES/"App/LocalInstructionSocket.swift", SOURCES/"App/AgentSessionController.swift",
                      SOURCES/"Core/AgentDeliveryProofs.swift", SOURCES/"Core/ExplanationDraftWorkspace.swift",
                      SOURCES/"Core/AgentInstructionEditing.swift",
                      HERE / "LocalExplanationDraftSocketProbe.swift"]
        other_src = root / "Other.swift"
        other_src.write_text(new_helper.read_text().replace('version":"2.0"', 'version":"2.0-other"'))
        for binary, identifier, files in ((root/"helper", APP_ID+".agent-helper",[new_helper]),
                                           (root/"server", APP_ID,server_src),
                                           (root/"other", APP_ID+".agent-helper",[other_src])):
            subprocess.run(["/usr/bin/swiftc","-framework","Security",*map(str,common+files),"-o",str(binary)],
                           check=True, timeout=120, env=compile_env)
            subprocess.run(["/usr/bin/codesign","--force","--options","runtime","--timestamp=none",
                            "--sign",os.environ.get("CODESIGN_IDENTITY","Codebasic TTS Local"),
                            "--identifier",identifier,str(binary)], check=True, timeout=15)
            subprocess.run(["/usr/bin/codesign", "--verify", "--strict", str(binary)], check=True, timeout=15)
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

        def launch(path, *args):
            return subprocess.Popen([str(root/path),*args], cwd=root, env=env, stdin=subprocess.PIPE,
                                    stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)

        # Expected hash is absolute; socket address remains relative to this isolated fixture.
        # No PIN environment, PID arguments, or manually prepared sockets are given to clients.
        process = []
        def start(name, *args):
            proc = launch(name, *args)
            process.append(proc)
            return proc

        def start_server(name="server", helper="helper"):
            proc = start(name, "ipc", str(root / helper))
            assert read(proc) == "ready"
            return proc

        def status(client):
            return rpc(client, "tools/call", {"name":"tts_agent_status"})["structuredContent"]["status"]

        a, b, other, entitled_helper = [start(name) for name in ("helper", "helper", "other", "entitled-helper")]
        try:
            for h in a,b,other,entitled_helper: initialize(h)
            assert status(a) == "app_unavailable"
            assert "Open Codebasic TTS" in message(call(a, "get_tts_instructions", profile=FIXTURE_SELECTOR))
            for rejected in ("unhardened", "entitled-server"):
                server = start_server(rejected)
                assert command(server, "pair") == "no"
                assert status(a) == "app_unavailable"
                stop(server)
            server = start_server(helper="entitled-helper")
            assert command(server, "pair") == "ok"
            assert status(entitled_helper) == "signing_required"
            # A same-UID unsigned connection cannot cause a pairing.
            probe = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            with probe:
                # The fixture lives under the worktree but the wire path must fit in sun_path.
                previous = Path.cwd()
                try:
                    os.chdir(root)
                    probe.connect("ipc/p.sock")
                    probe.sendall(b'{"schema_version":2}\n')
                    probe.shutdown(socket.SHUT_WR)
                    try:
                        assert probe.recv(128) == b""
                    except ConnectionResetError:
                        pass
                finally:
                    os.chdir(previous)
            assert not json.loads(command(server,"snapshot"))["paired"]
            assert command(server, "end") == "ok"
            server = start_server()
            assert command(server, "pair") == "ok"
            assert status(other) == "app_unavailable"  # same identifier/signer, wrong helper code hash
            assert not json.loads(command(server,"snapshot"))["paired"]
            assert status(a) == "approval_required"
            assert status(b) == "other_agent"
            assert call(a,"get_tts_instructions",profile=FIXTURE_SELECTOR)["isError"]
            assert command(server, "select") == "ok"
            assert status(a) == "ready" # one selection enabled both grants
            assert call(b,"get_tts_instructions",profile=FIXTURE_SELECTOR)["isError"]
            assert call(a,"get_tts_instructions",profile="explain")["isError"]
            reply = call(a,"get_tts_instructions")
            assert reply["structuredContent"]["profile"] == FIXTURE_SELECTOR
            assert not reply["isError"] and reply["structuredContent"]["instructions"].encode() == "합성 지시 e\u0301\n".encode()
            assert "proof" not in json.dumps(reply)
            old = reply["structuredContent"]["revision"]
            fields = dict(profile=FIXTURE_SELECTOR, revision=old, idempotency_key="one", display_text="as_frame", speech_text="애즈 프레임")
            assert call(a,"submit_explanation_draft",display_text="text-only",idempotency_key="unproven")["isError"]
            assert call(b,"submit_explanation_draft",**fields)["isError"]
            assert not call(a,"submit_explanation_draft",**fields)["isError"]
            assert "Already received" in message(call(a,"submit_explanation_draft",**fields))
            assert "Already received" in message(call(a,"submit_explanation_draft",**{**fields,"idempotency_key":"different-key"}))
            assert call(a,"submit_explanation_draft",**{**fields,"speech_text":"other"})["isError"]
            another = {**fields, "idempotency_key":"two", "display_text":"두 번째 대본"}
            assert not call(a,"submit_explanation_draft",**another)["isError"]
            snap = json.loads(command(server,"snapshot"))
            assert snap["count"] == 2 and snap["editor"] == "manual untouched"
            assert snap["previews"] == ["두 번째 대본", "as_frame"] # immediate, both retained, newest first
            assert snap["old"] == [False, False] and snap["labels"] == ["로컬 MCP", "로컬 MCP"]
            assert command(server,"select-alternate") == "ok"
            assert call(a,"get_tts_instructions",profile=FIXTURE_SELECTOR)["isError"]
            assert call(a,"submit_explanation_draft",**{**fields,"idempotency_key":"one-old"})["isError"]
            alt = call(a,"get_tts_instructions")["structuredContent"]
            assert alt["profile"] == "continue"
            assert not call(a,"submit_explanation_draft",profile="continue",revision=alt["revision"],
                            display_text="다른 지시의 대본",idempotency_key="alt")["isError"]
            assert command(server,"select") == "ok"
            assert call(a,"submit_explanation_draft",**{**fields,"idempotency_key":"one-old"})["isError"] # even re-selecting same revision
            assert call(a,"get_tts_instructions")["structuredContent"]["revision"] == old
            assert command(server, "change") == "ok" and command(server, "revert") == "ok"
            assert status(a) == "approval_required"
            assert call(a,"get_tts_instructions")["isError"] # edit/revert never restores either grant
            assert call(a,"submit_explanation_draft",**fields)["isError"]
            assert command(server,"select") == "ok"
            new = call(a,"get_tts_instructions")["structuredContent"]["revision"]
            assert new != old
            assert command(server,"delete") == "ok"
            assert call(a,"submit_explanation_draft",**{**fields,"revision":new,"idempotency_key":"final"})["isError"]
            assert json.loads(command(server,"snapshot"))["count"] == 3
            # Recover after an ungraceful app restart while the same helper remains alive.
            server.kill()
            server.wait(timeout=3)
            assert status(a) == "app_unavailable"
            server = start_server()
            assert command(server, "pair") == "ok"
            assert status(a) == "approval_required"
            assert command(server, "select") == "ok"
            assert status(a) == "ready"
            assert call(a,"submit_explanation_draft",**fields)["isError"] # old proof cannot authorize a new app instance
            assert json.loads(command(server,"snapshot"))["count"] == 0
            prior = call(a, "get_tts_instructions")["structuredContent"]
            assert command(server, "edit-buffer") == "ok"
            assert call(a, "get_tts_instructions")["structuredContent"] == prior # unsaved text stays private
            assert command(server, "revert-buffer") == "ok"
            assert call(a, "get_tts_instructions")["structuredContent"] == prior
            assert command(server, "edit-buffer") == "ok" and command(server, "save-buffer") == "ok"
            assert status(a) == "approval_required"
            assert call(a, "get_tts_instructions")["isError"]
            assert command(server, "select") == "ok"
            new_saved = call(a, "get_tts_instructions")["structuredContent"]
            assert new_saved["instructions"] == "저장하지 않은 합성 지시"
            assert new_saved["revision"] != prior["revision"]
            stop(a)
            assert status(b) == "approval_required"
            assert not json.loads(command(server,"snapshot"))["receiving"]
            assert command(server, "end") == "ok"
            print("signed stdio MCP: automatic discovery, closed app/restart recovery, default off, single selection, untrusted peers rejected, immediate previews, old proof and revised/deleted selection revoked, dedup, and unchanged editor")
        finally:
            for proc in process: stop(proc)


if __name__ == "__main__":
    main()
