import io
import json
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
import mcp_explain_draft as mcp


def request(method, request_id=1, params=None):
    msg = {"jsonrpc": "2.0", "method": method}
    if request_id is not None:
        msg["id"] = request_id
    if params is not None:
        msg["params"] = params
    return mcp.encode(msg)


INIT = request("initialize", 0, {
    "protocolVersion": "2025-11-25",
    "capabilities": {},
    "clientInfo": {"name": "test", "version": "1"},
})
READY = request("notifications/initialized", None)
ARGS = {
    "display_text": "as_frame 옵션을 켜면 데이터프레임을 반환합니다.",
    "spoken_text": "애즈 프레임 옵션을 켜면 데이터프레임을 반환합니다.",
    "mode": "explain",
    "idempotency_key": "draft-1",
    "instruction_revision": "a" * 64,
}
MINIMAL_ARGS = {
    "display_text": "간단한 해설 문구입니다.",
    "idempotency_key": "draft-2",
}


def call(args, request_id=2, tool="submit_explain_draft"):
    return request("tools/call", request_id, {"name": tool, "arguments": args})


def parse(output):
    return [json.loads(line) for line in output.splitlines()]


class ExplainDraftProtocolTest(unittest.TestCase):
    def test_stdio_handshake_and_isolated_tool_surface(self):
        process = subprocess.run(
            [sys.executable, "-I", "-B", str(Path(mcp.__file__).resolve())],
            input=INIT + READY + request("tools/list", "list") + request("ping", "ping"),
            capture_output=True,
            check=True,
            timeout=5,
        )
        init, tools, pong = parse(process.stdout)
        self.assertEqual(process.stderr, b"")
        self.assertEqual(init["result"]["protocolVersion"], "2025-11-25")
        self.assertEqual(init["result"]["serverInfo"]["name"], "codebasic-tts-explain-draft")
        self.assertNotIn("instructions", init["result"])
        self.assertEqual(tools["id"], "list")
        self.assertEqual([tool["name"] for tool in tools["result"]["tools"]], ["submit_explain_draft"])
        self.assertTrue(tools["result"]["tools"][0]["annotations"]["idempotentHint"])
        self.assertEqual(pong["result"], {})

    def test_call_validation_and_error_mapping(self):
        received = []
        statuses = iter(["accepted", "duplicate", "accepted", "conflict", "offline", "disabled"])

        def backend(args):
            received.append(args)
            return next(statuses)

        stdout = io.BytesIO()
        frames = INIT + READY
        frames += call(ARGS, 1)
        frames += call(ARGS, 2)
        frames += call(MINIMAL_ARGS, 3)
        frames += call(ARGS, 4)
        frames += call(ARGS, 5)
        frames += call(ARGS, 6)
        # Invalid arguments that must never reach backend:
        frames += call({"display_text": "한" * 5462, "idempotency_key": "too-big"}, 7)  # > 16KB UTF-8
        frames += call({**ARGS, "spoken_text": "한" * 5462}, 8)
        frames += call({**ARGS, "spoken_text": None}, 9)
        frames += call({**ARGS, "spoken_text": "   "}, 10)
        frames += call({**ARGS, "mode": "normalize"}, 11)
        frames += call({**ARGS, "instruction_revision": "A" * 64}, 12)
        frames += call({**ARGS, "auto_play": True}, 13)
        frames += call({"display_text": " ", "idempotency_key": "blank"}, 14)
        frames += call({"display_text": "a\0b", "idempotency_key": "nul"}, 15)
        frames += call({"display_text": "ok", "idempotency_key": "bad key"}, 16)
        mcp.run(io.BytesIO(frames), stdout, backend)

        expected = ["accepted", "duplicate", "accepted", "conflict", "offline", "disabled"] + ["invalid"] * 10
        replies = parse(stdout.getvalue())[1:]
        self.assertEqual(len(replies), len(expected))
        self.assertEqual(received, [ARGS, ARGS, MINIMAL_ARGS, ARGS, ARGS, ARGS])
        for reply, status in zip(replies, expected):
            result = reply["result"]
            self.assertEqual(result["isError"], status not in ("accepted", "duplicate"))
            self.assertTrue(result["content"][0]["text"].startswith(status + ":"))

    def test_other_tools_rejected_and_oversized_frame_recovery(self):
        stdout = io.BytesIO()
        frames = request("tools/list") + INIT + call(ARGS) + READY
        frames += call({"text": "never", "idempotency_key": "k1"}, 10, tool="speak_text")
        frames += call({"profile": "explain"}, 11, tool="get_tts_instructions")
        frames += b"{" + b"x" * mcp.MAX_FRAME + call(ARGS)
        frames += b"\xff\n" + b'[1, 2]\n' + request("ping", "ok")
        mcp.run(io.BytesIO(frames), stdout, lambda _: self.fail("backend must not be called"))
        replies = parse(stdout.getvalue())
        self.assertEqual(
            [r.get("error", {}).get("code") for r in replies],
            [-32002, None, -32002, -32602, -32602, -32700, -32700, -32600, None],
        )
        self.assertEqual(replies[-1]["id"], "ok")


@unittest.skipUnless(sys.platform == "darwin", "Darwin getpeereid is required")
class ExplainDraftSocketTest(unittest.TestCase):
    def test_exchange_on_socketpair(self):
        left, right = socket.socketpair()
        with left, right:
            self.assertTrue(mcp.same_uid(left))
            right.sendall(b'{"status":"accepted"}\n')
            self.assertEqual(mcp.exchange(left, mcp.encode(ARGS), time.monotonic() + 1), "accepted")
            with right.makefile("rb") as source:
                self.assertEqual(source.read(1024), mcp.encode(ARGS))

    def test_missing_socket_and_symlink(self):
        with tempfile.TemporaryDirectory(prefix="tts-draft-mcp-", dir="/private/tmp") as directory:
            path = Path(directory) / "e.sock"
            self.assertEqual(mcp.send_local(ARGS, path), "offline")
            path.symlink_to("no-socket")
            self.assertEqual(mcp.send_local(ARGS, path), "unsafe")

    def test_local_unix_frame_and_safe_path(self):
        with tempfile.TemporaryDirectory(prefix="tts-draft-mcp-", dir="/private/tmp") as directory:
            path = Path(directory) / "e.sock"
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as listener:
                try:
                    listener.bind(str(path))
                except PermissionError as error:
                    self.skipTest(f"Sandbox denied temporary AF_UNIX bind: {error}")
                path.chmod(0o600)
                listener.listen(1)
                listener.settimeout(3)
                seen = []

                def fake_app():
                    with listener.accept()[0] as conn:
                        conn.settimeout(3)
                        with conn.makefile("rb") as source:
                            seen.append(json.loads(source.readline()))
                        conn.sendall(b'{"status":"accepted"}\n')

                thread = threading.Thread(target=fake_app, daemon=True)
                thread.start()
                result = mcp.send_local(ARGS, path, verify_peer=lambda _: True)
                thread.join(timeout=4)
                self.assertEqual(result, "accepted")
                self.assertEqual(seen, [ARGS])
                path.chmod(0o666)
                self.assertEqual(mcp.send_local(ARGS, path), "unsafe")
