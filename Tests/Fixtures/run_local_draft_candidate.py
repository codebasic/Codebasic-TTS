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
import time

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
    assert {t["name"] for t in rpc(proc, "tools/list")["tools"]} == {"tts_agent_status","get_tts_instructions","submit_explanation_draft","submit_tts_draft"}


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

        def start_server(name="server", helper="helper", waiting=90000):
            proc = start(name, "ipc", str(root / helper), str(waiting))
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
            # An explicit enable can wait, but expires and never transfers automatically.
            server = start_server(waiting=180)
            assert command(server, "pair") == "ok" and command(server, "enable") == "ok"
            assert json.loads(command(server, "snapshot"))["waiting"]
            time.sleep(0.3)
            assert not json.loads(command(server, "snapshot"))["waiting"]
            assert status(a) == "approval_required"
            assert command(server, "end") == "ok"

            server = start_server()
            assert command(server, "pair") == "ok"
            assert command(server, "enable") == "ok"
            assert status(other) == "app_unavailable" # same leaf/ID, wrong helper hash
            assert json.loads(command(server, "snapshot"))["waiting"]
            assert status(a) == "receiving_only" # no profile or instruction read
            assert status(b) == "other_agent"
            assert call(a,"get_tts_instructions")["isError"]
            draft = dict(idempotency_key="doc-1", display_text="첫 번째 대본")
            assert call(b,"submit_tts_draft",**draft)["isError"]
            assert call(a,"submit_tts_draft",**{**draft,"profile":FIXTURE_SELECTOR})["isError"]
            assert call(a,"submit_tts_draft",**{**draft,"display_text":"x"*8193})["isError"]
            assert call(a,"submit_tts_draft",**draft)["structuredContent"]["status"] == "accepted"
            assert call(a,"submit_tts_draft",**draft)["structuredContent"]["status"] == "duplicate"
            assert call(a,"submit_tts_draft",**{**draft,"display_text":"바뀐 대본"})["isError"]
            info = json.loads(command(server, "snapshot"))
            assert info["editor"] == info["original"] == "첫 번째 대본"
            assert not info["canRevert"] and info["associated"] == ""
            assert command(server, "edit-document") == "ok"
            assert command(server, "begin-clear") == "ok"
            first_id = json.loads(command(server, "snapshot"))["editorID"]
            second = dict(idempotency_key="doc-2", display_text="두 번째 대본 e\u0301\n",
                          speech_text="  음성 원문 e\u0301\n")
            assert call(a,"submit_tts_draft",**second)["structuredContent"]["status"] == "accepted"
            assert command(server, "edit-document") == "ok"
            assert command(server, "edit-speech") == "ok"
            third = dict(idempotency_key="doc-3", display_text="세 번째 대본")
            assert call(a,"submit_tts_draft",**third)["structuredContent"]["status"] == "accepted"
            assert command(server, "confirm-clear") == "ok"
            info = json.loads(command(server, "snapshot"))
            assert info["editor"] == "세 번째 대본" and info["editorID"] != first_id
            assert info["tabs"] == ["첫 번째 대본", "두 번째 대본 e\u0301", "세 번째 대본"]
            assert info["dirty"] == [True, True, False]
            assert command(server, "switch-tab 1") == "ok"
            info = json.loads(command(server, "snapshot"))
            assert info["editor"] == "직접 수정: " + second["display_text"] and info["canRevert"]
            assert info["speech"] == "음성 수정: " + second["speech_text"]
            assert command(server, "revert-document") == "ok"
            info = json.loads(command(server, "snapshot"))
            assert info["editor"].encode() == second["display_text"].encode()
            assert info["speech"].encode() == second["speech_text"].encode()
            assert command(server, "switch-tab 0") == "ok"
            info = json.loads(command(server, "snapshot"))
            assert info["editor"] == "직접 수정: 첫 번째 대본" and info["editorID"] == first_id
            assert command(server, "begin-clear") == "ok" and command(server, "confirm-clear") == "ok"
            assert json.loads(command(server, "snapshot"))["editor"] == ""
            assert command(server, "revert-document") == "ok"
            assert json.loads(command(server, "snapshot"))["editor"] == draft["display_text"]
            print("fixed clear: two arrivals leave the current document and parked edits intact; target clear and exact two-field revert passed")

            # Optional instruction is separate, pins only the selected saved revision, and cannot be bypassed.
            assert command(server, "select") == "ok" and status(a) == "ready"
            plain = dict(idempotency_key="will-not-bypass", display_text="범위 확인")
            assert call(a,"submit_tts_draft",**plain)["structuredContent"]["status"] == "instruction_required"
            assert call(a,"get_tts_instructions",profile="explain")["isError"]
            prior = call(a,"get_tts_instructions")["structuredContent"]
            assert prior["instructions"].encode() == "합성 지시 e\u0301\n".encode() and "proof" not in prior
            fields = dict(profile=FIXTURE_SELECTOR, revision=prior["revision"], idempotency_key="linked", display_text="연결된 대본")
            assert call(a,"submit_explanation_draft",**fields)["structuredContent"]["status"] == "accepted"
            assert json.loads(command(server, "snapshot"))["associated"] == FIXTURE_SELECTOR
            assert call(a,"submit_explanation_draft",**fields)["structuredContent"]["status"] == "duplicate"
            assert call(a,"submit_explanation_draft",**{**fields,"idempotency_key":"linked-repeat"})["structuredContent"]["status"] == "accepted"
            assert command(server, "select-alternate") == "ok"
            assert call(a,"submit_explanation_draft",**fields)["structuredContent"]["status"] == "unproven"
            assert command(server, "select") == "ok"
            assert call(a,"submit_explanation_draft",**fields)["structuredContent"]["status"] == "unproven"
            assert call(a,"get_tts_instructions")["structuredContent"] == prior
            assert command(server,"edit-buffer") == "ok"
            assert call(a,"get_tts_instructions")["structuredContent"] == prior
            assert command(server,"save-buffer") == "ok"
            assert status(a) == "instruction_required"
            assert call(a,"submit_tts_draft",**plain)["structuredContent"]["status"] == "instruction_required"
            assert call(a,"submit_explanation_draft",**fields)["isError"]
            assert command(server,"select") == "ok"
            revised = call(a,"get_tts_instructions")["structuredContent"]
            assert revised["revision"] != prior["revision"] and revised["instructions"] == "저장하지 않은 합성 지시"
            assert command(server,"invalidate-pending") == "ok"  # The selected scope survives an edit.
            assert status(a) == "instruction_required"
            assert command(server,"delete") == "ok"
            assert status(a) == "receiving_only"
            assert json.loads(command(server, "snapshot"))["scope"] == ""
            stale = {**fields, "revision":revised["revision"], "idempotency_key":"stale-deleted"}
            snapshot = json.loads(command(server, "snapshot"))
            assert call(a,"submit_explanation_draft",**stale)["structuredContent"]["status"] == "unproven"
            assert json.loads(command(server, "snapshot")) == snapshot
            assert call(a,"submit_tts_draft",**plain)["structuredContent"]["status"] == "accepted"
            print("fixed deletion: edited selection clears on deletion, generic draft opens and stale linked draft is refused")

            assert command(server, "disable") == "ok"
            assert status(a) == "approval_required" and call(a,"submit_tts_draft",**plain)["isError"]
            assert command(server, "enable") == "ok"
            assert call(a,"submit_tts_draft",**plain)["structuredContent"]["status"] == "duplicate"
            alias = {**plain, "idempotency_key":"intentional-repeat"}
            assert call(a,"submit_tts_draft",**alias)["structuredContent"]["status"] == "accepted"
            assert call(a,"submit_tts_draft",**alias)["structuredContent"]["status"] == "duplicate"
            assert "Retry key already used" in message(call(a,"submit_tts_draft",**{**alias,"display_text":"changed"}))
            print("fixed key policy: distinct key opens intentional repeat, and reused key with changed text conflicts")

            server.kill()
            server.wait(timeout=3)
            assert status(a) == "app_unavailable"
            server = start_server()
            assert command(server, "pair") == "ok"
            assert status(a) == "approval_required"
            assert not json.loads(command(server, "snapshot"))["paired"]
            assert call(a,"submit_tts_draft",**draft)["isError"]
            assert command(server,"enable") == "ok" and status(a) == "receiving_only"
            assert call(a,"submit_explanation_draft",**fields)["isError"] # old proof cannot authorize a new instance
            for index in range(6):
                args = {"idempotency_key":f"cap-{index}","display_text":f"합성 문서 {index}"}
                assert call(a,"submit_tts_draft",**args)["structuredContent"]["status"] == "accepted"
                assert command(server,"edit-document") == "ok"
                assert command(server,"edit-speech") == "ok"
            full = call(a,"submit_tts_draft",idempotency_key="cap-overflow",display_text="넘치는 문서")
            assert full["isError"] and full["structuredContent"]["status"] == "busy"
            snapshot = json.loads(command(server,"snapshot"))
            assert len(snapshot["tabs"]) == 6 and all(snapshot["dirty"])
            assert snapshot["editor"] == "직접 수정: 합성 문서 5"
            for index in range(6):
                assert command(server, f"switch-tab {index}") == "ok"
                snapshot = json.loads(command(server, "snapshot"))
                assert snapshot["editor"] == f"직접 수정: 합성 문서 {index}" and snapshot["speech"] == "음성 수정: "
            assert command(server, "disconnect") == "ok"
            assert status(a) == "approval_required" and status(b) == "approval_required"
            assert call(b,"submit_tts_draft",**draft)["isError"]
            assert not json.loads(command(server,"snapshot"))["paired"]
            assert not json.loads(command(server,"snapshot"))["receiving"]
            assert command(server, "enable") == "ok" and status(b) == "receiving_only"
            assert status(a) == "other_agent"
            stop(b)
            assert status(a) == "approval_required"
            assert not json.loads(command(server,"snapshot"))["receiving"]
            print("fixed disconnect: either helper stays unpaired until explicit approval; second helper can take over, and exit revokes its grant")
            assert command(server, "end") == "ok"

            # Deleting an unrelated profile cannot change an absent or different scope.
            for select_other in (False, True):
                server = start_server()
                assert command(server, "pair") == "ok" and command(server, "enable") == "ok"
                assert status(a) == "receiving_only"
                if select_other:
                    assert command(server, "select-alternate") == "ok"
                    assert call(a,"get_tts_instructions")["structuredContent"]["profile"] == "continue"
                before = json.loads(command(server, "snapshot"))
                assert command(server, "delete") == "ok"
                assert json.loads(command(server, "snapshot")) == before
                assert status(a) == ("ready" if select_other else "receiving_only")
                assert command(server, "end") == "ok"

            server = start_server()
            assert command(server, "pair") == "ok" and command(server, "enable") == "ok"
            assert status(a) == "receiving_only" and command(server, "select") == "ok"
            assert command(server, "delete") == "ok" and status(a) == "receiving_only"
            assert command(server, "end") == "ok"

            server = start_server()
            assert command(server, "pair") == "ok" and command(server, "select") == "ok"
            assert command(server, "delete") == "ok"
            assert command(server, "enable") == "ok" and status(a) == "receiving_only"
            assert command(server, "end") == "ok"

            server = start_server()
            assert command(server, "pair") == "ok" and command(server, "enable") == "ok"
            assert status(a) == "receiving_only"
            for index in range(128):
                if index and index % 6 == 0:
                    assert command(server, "disable") == "ok" and command(server, "enable") == "ok"
                assert call(a,"submit_tts_draft",idempotency_key=f"key-{index}",
                            display_text=f"document {index}")["structuredContent"]["status"] == "accepted"
            assert call(a,"submit_tts_draft",idempotency_key="overflow",
                        display_text="overflow")["structuredContent"]["status"] == "session_limit"
            assert call(a,"submit_tts_draft",idempotency_key="key-0",
                        display_text="document 0")["structuredContent"]["status"] == "duplicate"
            assert "Retry key already used" in message(call(a,"submit_tts_draft",idempotency_key="key-0",
                                                           display_text="different"))
            assert command(server, "end") == "ok"
            print("bounded key ledger: capacity blocks new keys and still remembers the first successful key")
            print("signed stdio MCP: no-profile first receipt, wrong helper and restart disabled, bounded inputs, idempotency, linked/stale scope, dirty tabs, exact revert and no playback")
        finally:
            for proc in process: stop(proc)


if __name__ == "__main__":
    main()
