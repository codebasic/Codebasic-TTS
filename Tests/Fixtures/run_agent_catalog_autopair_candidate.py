#!/usr/bin/env python3
"""E2E test: signed native MCP helper (`codebasic-tts-agent-mcp`) <-> signed App probe (`AgentAutopairProbe`)."""
import hashlib
import json
import os
from pathlib import Path
import re
import selectors
import shutil
import subprocess
import tempfile

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
BUILD = Path(os.environ.get("TTS_BUILD_DIR", REPO / "build"))
APP = BUILD / "Codebasic TTS.app"
HELPER = APP / "Contents/Helpers/codebasic-tts-agent-mcp"
SOURCES = REPO / "Sources"


def line(proc):
    with selectors.DefaultSelector() as selector:
        selector.register(proc.stdout, selectors.EVENT_READ)
        if not selector.select(5):
            raise TimeoutError("process output timed out")
        return proc.stdout.readline().strip()


def write(proc, text):
    proc.stdin.write(text + "\n")
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
    req = {"jsonrpc": "2.0", "method": method, "id": ident}
    if params is not None:
        req["params"] = params
    write(proc, json.dumps(req, ensure_ascii=False))
    return json.loads(line(proc))


def probe_cmd(proc, *parts):
    write(proc, "\t".join(str(p) for p in parts))
    return json.loads(line(proc))


def init_helper(proc, name="client"):
    res = rpc(proc, "initialize", {
        "protocolVersion": "2025-11-25",
        "capabilities": {},
        "clientInfo": {"name": name, "version": "1"},
    })["result"]
    assert res["serverInfo"]["name"] == "codebasic-tts-agent", res
    assert "instructions" not in res
    write(proc, '{"jsonrpc":"2.0","method":"notifications/initialized"}')
    tools = rpc(proc, "tools/list")["result"]["tools"]
    names = [t["name"] for t in tools]
    assert names == ["pair_tts_session", "get_agent_instruction", "submit_explanation_draft"], names
    assert "speak_text" not in names


def call_tool(proc, name, args=None, ident=10):
    params = {"name": name}
    if args is not None:
        params["arguments"] = args
    return rpc(proc, "tools/call", params, ident=ident)["result"]


# Verify built signed bundle & nested helper keep distinct valid signatures
subprocess.run(["/usr/bin/codesign", "--verify", "--strict", "--deep", str(APP)], check=True, timeout=12)
subprocess.run(["/usr/bin/codesign", "--verify", "--strict", str(HELPER)], check=True, timeout=12)
app_meta = subprocess.run(["/usr/bin/codesign", "-dr", "-", str(APP)], check=True, text=True, capture_output=True, timeout=12)
helper_meta = subprocess.run(["/usr/bin/codesign", "-dvv", str(HELPER)], check=True, text=True, capture_output=True, timeout=12)
anchor = re.search(r'certificate\s+leaf\s*=\s*H["\']?([a-fA-F0-9]{40})', app_meta.stdout + app_meta.stderr)
if not anchor:
    raise RuntimeError("Trusted certificate leaf required on Codebasic TTS.app")
assert "Identifier=com.seongjoo.SelectedTextTTS.agent-mcp" in (helper_meta.stdout + helper_meta.stderr)

cache = BUILD / "clt-check" / "cache"
cache.mkdir(parents=True, exist_ok=True)
sdk = subprocess.check_output(["/usr/bin/xcrun", "--sdk", "macosx26.5", "--show-sdk-path"], text=True).strip()

with tempfile.TemporaryDirectory(prefix="cbtts-autopair-", dir="/private/tmp") as tmp_raw:
    tmp = Path(tmp_raw)
    ipc_dir = tmp / "ipc"
    ipc_dir.mkdir(mode=0o700)
    profile_dir = tmp / "profile"
    profile_dir.mkdir(mode=0o700)

    app_probe = tmp / "app-probe"
    subprocess.run(
        [
            "/usr/bin/swiftc", "-Onone", "-o", str(app_probe),
            str(SOURCES / "Core/SSMLGuard.swift"),
            str(SOURCES / "Core/AgentInstructionCatalog.swift"),
            str(SOURCES / "Core/AgentSessionPolicy.swift"),
            str(SOURCES / "Core/ExplanationDraftWorkspace.swift"),
            str(SOURCES / "Core/Logging.swift"),
            str(SOURCES / "Core/MemoryDiagnostics.swift"),
            str(SOURCES / "Core/ExplanationConversation.swift"),
            str(SOURCES / "TTS/TextNormalizer.swift"),
            str(SOURCES / "App/LocalInstructionSocket.swift"),
            str(SOURCES / "App/AgentPeerVerifier.swift"),
            str(SOURCES / "App/AgentSessionController.swift"),
            str(HERE / "AgentAutopairProbe.swift"),
            "-framework", "Security",
        ],
        check=True,
        timeout=120,
        env={"PATH": "/usr/bin:/bin", "SDKROOT": sdk, "CLANG_MODULE_CACHE_PATH": str(cache)},
    )
    sign_id = os.environ.get("CODESIGN_IDENTITY", "Codebasic TTS Local")
    subprocess.run(
        ["/usr/bin/codesign", "--force", "--sign", sign_id, "--identifier", "com.seongjoo.SelectedTextTTS", str(app_probe)],
        check=True,
        timeout=12,
    )

    rogue_helper = tmp / "rogue-helper"
    shutil.copyfile(HELPER, rogue_helper)
    rogue_helper.chmod(0o755)
    subprocess.run(
        ["/usr/bin/codesign", "--force", "--sign", "-", "--identifier", "com.example.rogue", str(rogue_helper)],
        check=True,
        timeout=12,
    )

    base_env = {
        "PATH": "/usr/bin:/bin",
        "HOME": str(tmp),
        "CODEBASIC_TTS_MCP_DIR": str(ipc_dir),
    }

    server = subprocess.Popen(
        [str(app_probe), str(ipc_dir), str(profile_dir)],
        env=base_env,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    assert line(server) == "ready", server.stderr.read()

    helper_a = subprocess.Popen([str(HELPER)], env=base_env, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    helper_b = subprocess.Popen([str(HELPER)], env=base_env, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    wrong_pin_helper = subprocess.Popen(
        [str(HELPER)],
        env={**base_env, "CODEBASIC_TTS_SIGNER_SHA1": "0" * 40},
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    rogue = subprocess.Popen([str(rogue_helper)], env={**base_env, "CODEBASIC_TTS_SIGNER_SHA1": anchor.group(1)}, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)

    try:
        init_helper(helper_a, "Codex-A")
        init_helper(helper_b, "Claude-B")
        init_helper(wrong_pin_helper, "WrongPin")
        init_helper(rogue, "Rogue")

        # 1. Pairing closed by default
        assert call_tool(helper_a, "pair_tts_session")["isError"] is True
        assert probe_cmd(server, "start_pairing")["ok"] is True
        assert (ipc_dir / "pair.sock").lstat().st_mode & 0o777 == 0o600

        # 2. Rogue (ad-hoc/wrong ID) rejected by OS peer verifier; wrong pin rejected by helper
        assert call_tool(rogue, "pair_tts_session")["isError"] is True
        assert call_tool(wrong_pin_helper, "pair_tts_session")["isError"] is True
        assert call_tool(wrong_pin_helper, "pair_tts_session")["content"][0]["text"].startswith("unsafe:")
        assert probe_cmd(server, "candidates")["candidates"] == []

        # 3. Legitimate signed helpers knock; no grant granted until user approves ONE
        k_a = call_tool(helper_a, "pair_tts_session", {"client_note": "Codex Harness"})
        k_b = call_tool(helper_b, "pair_tts_session", {"client_note": "Claude Harness"})
        assert not k_a["isError"] and k_a["content"][0]["text"].startswith("pending_approval:")
        assert not k_b["isError"] and k_b["content"][0]["text"].startswith("pending_approval:")
        assert call_tool(helper_a, "get_agent_instruction", {"target": "explain"})["isError"] is True

        # Approve helper_a only
        assert probe_cmd(server, "approve_pid", helper_a.pid)["ok"] is True
        snap = probe_cmd(server, "snapshot")
        assert not (ipc_dir / "pair.sock").exists()
        assert snap["pinnedPID"] == helper_a.pid
        assert not snap["readActive"] and not snap["receiptActive"]

        # 4. Local catalog create + exact read + delivery_proof + edit-then-revert sticky revocation
        created = probe_cmd(server, "create_local", "로컬 파이썬", "SYNTHETIC_LOCAL: as_frame은 애즈 프레임으로 읽습니다.")
        assert created["ok"] is True
        local_id = created["id"]
        assert probe_cmd(server, "grant_read", local_id)["ok"] is True
        assert call_tool(helper_b, "get_agent_instruction", {"target": local_id})["isError"] is True
        assert call_tool(helper_a, "get_agent_instruction", {"target": "explain"})["isError"] is True
        res_local = call_tool(helper_a, "get_agent_instruction", {"target": local_id})
        assert not res_local["isError"], res_local
        sc = res_local["structuredContent"]
        assert sc["origin"] == "local" and sc["label"] == "로컬 파이썬"
        assert sc["revision"] == created["revision"]
        assert sc["instructions"] == created["body"]
        assert len(sc["delivery_proof"]) == 32

        # Sticky edit-then-revert revocation on local catalog entry
        assert probe_cmd(server, "update_local", local_id, "로컬 파이썬", "SYNTHETIC_LOCAL: 수정됨")["ok"] is True
        assert not (ipc_dir / "i.sock").exists()
        assert probe_cmd(server, "update_local", local_id, "로컬 파이썬", created["body"])["ok"] is True
        assert probe_cmd(server, "snapshot")["readActive"] is False
        assert call_tool(helper_a, "get_agent_instruction", {"target": local_id})["isError"] is True

        # 5. Built-in explain read -> mints proof -> revoke read -> grant receipt -> late draft provenance & caps
        assert probe_cmd(server, "grant_read", "explain")["ok"] is True
        res_explain = call_tool(helper_a, "get_agent_instruction", {"target": "explain"})
        assert not res_explain["isError"], res_explain
        ex_sc = res_explain["structuredContent"]
        assert ex_sc["origin"] == "builtin"
        assert ex_sc["revision"] == hashlib.sha256(b"tts-profile-v1\0explain\0" + ex_sc["instructions"].encode()).hexdigest()
        assert probe_cmd(server, "revoke_read")["ok"] is True
        assert not (ipc_dir / "i.sock").exists()

        # Receipt is separate and enables d.sock
        assert probe_cmd(server, "grant_receipt")["ok"] is True
        assert (ipc_dir / "d.sock").lstat().st_mode & 0o777 == 0o600
        assert call_tool(helper_b, "submit_explanation_draft", {"idempotency_key": "b-1", "display_text": "nope"})["isError"] is True

        # Marked late draft WITH valid prior proof accepted
        late_ok = call_tool(helper_a, "submit_explanation_draft", {
            "idempotency_key": "late-1",
            "display_text": "as_frame 옵션입니다.",
            "speech_text": "애즈 프레임 옵션입니다.",
            "late_draft": True,
            "instruction_target": "explain",
            "instruction_revision": ex_sc["revision"],
            "delivery_proof": ex_sc["delivery_proof"],
        })
        assert not late_ok["isError"] and late_ok["content"][0]["text"].startswith("accepted:"), late_ok
        # Exact duplicate returns duplicate (non-error)
        late_dup = call_tool(helper_a, "submit_explanation_draft", {
            "idempotency_key": "late-1",
            "display_text": "as_frame 옵션입니다.",
            "speech_text": "애즈 프레임 옵션입니다.",
            "late_draft": True,
            "instruction_target": "explain",
            "instruction_revision": ex_sc["revision"],
            "delivery_proof": ex_sc["delivery_proof"],
        })
        assert not late_dup["isError"] and late_dup["content"][0]["text"].startswith("duplicate:"), late_dup

        # Forged late proof rejected as unproven
        late_bad = call_tool(helper_a, "submit_explanation_draft", {
            "idempotency_key": "late-bad",
            "display_text": "위조된 지연 대본",
            "late_draft": True,
            "instruction_target": "explain",
            "instruction_revision": ex_sc["revision"],
            "delivery_proof": "0" * 32,
        })
        assert late_bad["isError"] and late_bad["content"][0]["text"].startswith("unproven:"), late_bad

        # 6/min rate limit (5 more accepted = 6 total, 7th rate_limited)
        for i in range(2, 7):
            r = call_tool(helper_a, "submit_explanation_draft", {"idempotency_key": f"rate-{i}", "display_text": f"문구 {i}"})
            assert not r["isError"] and r["content"][0]["text"].startswith("accepted:"), r
        rate_7 = call_tool(helper_a, "submit_explanation_draft", {"idempotency_key": "rate-7", "display_text": "초과 문구"})
        assert rate_7["isError"] and rate_7["content"][0]["text"].startswith("rate_limited:"), rate_7

        # Revoking receipt wipes delivery proofs; re-granting receipt rejects old proof
        assert probe_cmd(server, "revoke_receipt")["ok"] is True
        snap2 = probe_cmd(server, "snapshot")
        assert snap2["proofCount"] == 0 and not (ipc_dir / "d.sock").exists()
        assert probe_cmd(server, "grant_receipt")["ok"] is True
        late_expired = call_tool(helper_a, "submit_explanation_draft", {
            "idempotency_key": "late-old-proof",
            "display_text": "만료 증명",
            "late_draft": True,
            "instruction_target": "explain",
            "instruction_revision": ex_sc["revision"],
            "delivery_proof": ex_sc["delivery_proof"],
        })
        assert late_expired["isError"] and late_expired["content"][0]["text"].startswith("unproven:"), late_expired

        # Delete local entry leaves tombstone and revokes active read
        assert probe_cmd(server, "grant_read", local_id)["ok"] is True
        del_res = probe_cmd(server, "delete_local", local_id)
        assert del_res["ok"] and del_res["tombstoned"] is True
        assert not (ipc_dir / "i.sock").exists()

        probe_cmd(server, "quit")
        print("signed native helper E2E: codesign peer verification, harness-initiated autopair, local catalog, sticky revoke, delivery proof, 6/min rate limit, tombstone all passed")
    finally:
        close(helper_a)
        close(helper_b)
        close(wrong_pin_helper)
        close(rogue)
        close(server)
