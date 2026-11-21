import io
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
import mcp_speech as mcp


def request(method, request_id=1, params=None):
    msg = {"jsonrpc": "2.0", "method": method}
    if request_id is not None:
        msg["id"] = request_id
    if params is not None:
        msg["params"] = params
    return mcp.encode(msg)


INIT = request("initialize", 0, {
    "protocolVersion": mcp.PROTOCOL, "capabilities": {},
    "clientInfo": {"name": "test", "version": "1"},
})
READY = request("notifications/initialized", None)
ARGS = {"text": "  k\nk는 __init__의 기호 @이며 값은 0.84입니다.\n\nkeep(x_values, 0.91)  ", "idempotency_key": "example-1"}


def call(args, request_id=2):
    return request("tools/call", request_id, {"name": "speak_text", "arguments": args})


def parse(output):
    return [json.loads(line) for line in output.splitlines()]


class ProtocolTest(unittest.TestCase):
    def test_stdio_handshake_and_list(self):
        process = subprocess.run(
            [sys.executable, "-B", str(Path(mcp.__file__).resolve())],
            input=INIT + READY + request("tools/list", "list") + request("ping", "ping"),
            capture_output=True, check=True, timeout=5,
        )
        init, tools, pong = parse(process.stdout)
        self.assertEqual(process.stderr, b"")
        self.assertEqual(init["result"]["protocolVersion"], mcp.PROTOCOL)
        self.assertEqual(tools["id"], "list")
        self.assertEqual([tool["name"] for tool in tools["result"]["tools"]], ["speak_text"])
        self.assertEqual(pong["result"], {})

    def test_call_and_error_states(self):
        received, statuses = [], iter(["accepted", "duplicate", "busy", "offline", "disabled", "conflict"])
        def backend(args):
            received.append(args)
            return next(statuses)

        stdout = io.BytesIO()
        frames = INIT + READY + b"".join(call(ARGS, i) for i in range(1, 7))
        frames += call({"text": "한" * 1366, "idempotency_key": "too-big"}, 7)
        frames += call({**ARGS, "voice": "not allowed"}, 8)
        frames += call({"text": " ", "idempotency_key": "empty"}, 9)
        frames += call({"text": "\0", "idempotency_key": "control"}, 10)
        frames += call({"text": "hello", "idempotency_key": "bad\n"}, 11)
        frames += call({"text": "애즈 프레임 옵션입니다.", "idempotency_key": "separate-display",
                        "display_text": "as_frame 옵션입니다."}, 12)
        frames += call({"text": "ok", "idempotency_key": "task"}, None)
        mcp.run(io.BytesIO(frames), stdout, backend)
        statuses = ["accepted", "duplicate", "busy", "offline", "disabled", "conflict"] + ["invalid"] * 6
        replies = parse(stdout.getvalue())[1:]
        self.assertEqual(len(replies), len(statuses))
        self.assertEqual(received, [ARGS] * 6)
        for reply, status in zip(replies, statuses):
            result = reply["result"]
            self.assertEqual(result["isError"], status not in ("accepted", "duplicate"))
            self.assertTrue(result["content"][0]["text"].startswith(status + ":"))

    def test_malformed_and_oversized_frame_recovery(self):
        stdout = io.BytesIO()
        frames = request("tools/list") + INIT + call(ARGS) + READY
        frames += b"{" + b"x" * mcp.MAX_FRAME + call(ARGS)  # Entire oversized line discarded.
        frames += b"\xff\n" + b'[1, 2]\n' + b'{"jsonrpc":"2.0","method":"ping","method":"call"}\n'
        frames += request("ping", "ok")
        mcp.run(io.BytesIO(frames), stdout, lambda _: self.fail("backend must not be called"))
        replies = parse(stdout.getvalue())
        self.assertEqual([r.get("error", {}).get("code") for r in replies],
                         [-32002, None, -32002, -32700, -32700, -32600, -32700, None])
        self.assertEqual(replies[-1]["id"], "ok")


@unittest.skipUnless(sys.platform == "darwin", "Darwin getpeereid is required")
class SocketTest(unittest.TestCase):
    def test_getpeereid_on_socketpair(self):
        left, right = socket.socketpair()
        with left, right:
            self.assertTrue(mcp.same_uid(left))
            self.assertTrue(mcp.same_uid(right))
            # A preloaded fake reply lets us check wire framing without a pathname bind.
            right.sendall(b'{"status":"accepted"}\n')
            self.assertEqual(mcp.exchange(left, mcp.encode(ARGS), time.monotonic() + 1), "accepted")
            with right.makefile("rb") as source:
                self.assertEqual(source.read(1024), mcp.encode(ARGS))

    def test_missing_socket_and_symlink(self):
        with tempfile.TemporaryDirectory(prefix="s", dir=os.environ.get("TMPDIR", "/private/tmp")) as directory:
            path = Path(directory) / "s.sock"
            self.assertEqual(mcp.send_local(ARGS, path), "offline")
            path.symlink_to("no-socket")
            self.assertEqual(mcp.send_local(ARGS, path), "unsafe")

    def test_local_unix_frame_and_safe_path(self):
        with tempfile.TemporaryDirectory(prefix="s", dir=os.environ.get("TMPDIR", "/private/tmp")) as directory:
            path = Path(directory) / "s.sock"
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
