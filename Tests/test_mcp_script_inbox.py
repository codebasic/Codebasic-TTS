"""submit_script adapter: protocol, validation, and the real Swift inbox socket (offline)."""
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO / "scripts"))
import mcp_script_inbox as inbox
import mcp_speech

VISUAL = "as_frame 옵션을 켜면 데이터프레임을 반환합니다."
SPOKEN = "애즈 프레임 옵션을 켜면 데이터프레임을 반환합니다."
ARGS = {"display_text": VISUAL, "speech_text": SPOKEN, "idempotency_key": "synthetic-1"}


def request(method, request_id=1, params=None):
    msg = {"jsonrpc": "2.0", "method": method}
    if request_id is not None:
        msg["id"] = request_id
    if params is not None:
        msg["params"] = params
    return inbox.encode(msg)


INIT = request("initialize", 0, {"protocolVersion": mcp_speech.PROTOCOL, "capabilities": {},
                                 "clientInfo": {"name": "test", "version": "1"}})
READY = request("notifications/initialized", None)


def call(args, request_id=2, name="submit_script"):
    return request("tools/call", request_id, {"name": name, "arguments": args})


def run(frames, backend):
    out = io.BytesIO()
    inbox.run(io.BytesIO(frames), out, inbox.InboxSession(backend))
    return [json.loads(line) for line in out.getvalue().splitlines()]


class ProtocolTest(unittest.TestCase):
    def test_real_stdio_lists_only_submit_script(self):
        process = subprocess.run([sys.executable, "-I", "-B", str(Path(inbox.__file__).resolve())],
                                 input=INIT + READY + request("tools/list", "list"),
                                 capture_output=True, check=True, timeout=5)
        init, tools = [json.loads(line) for line in process.stdout.splitlines()]
        self.assertEqual(process.stderr, b"")
        self.assertEqual(init["result"]["serverInfo"]["name"], "codebasic-tts-script-inbox")
        self.assertEqual([tool["name"] for tool in tools["result"]["tools"]], ["submit_script"])
        self.assertIn("Nothing is played", tools["result"]["tools"][0]["description"])

    def test_separate_from_speak_text(self):
        seen = []
        replies = run(INIT + READY + call({"text": "읽어", "idempotency_key": "x"}, 2, "speak_text")
                      + call({"text": "읽어", "idempotency_key": "x"}, 3), seen.append)
        self.assertEqual(replies[1]["error"]["code"], -32602)       # no speech tool here
        self.assertTrue(replies[2]["result"]["content"][0]["text"].startswith("invalid:"))
        self.assertEqual(seen, [])
        speech = io.BytesIO()
        mcp_speech.run(io.BytesIO(INIT + READY + call(ARGS, 2)), speech, lambda _: self.fail("must not reach app"))
        self.assertEqual(json.loads(speech.getvalue().splitlines()[1])["error"]["code"], -32602)

    def test_statuses_and_validation(self):
        seen, statuses = [], iter(["received", "duplicate", "conflict", "full", "disabled", "offline", "unsafe", "unconfirmed"])
        def backend(args):
            seen.append(args)
            return next(statuses)
        frames = INIT + READY + b"".join(call(ARGS, i) for i in range(1, 9))
        display_only = {"display_text": VISUAL, "idempotency_key": "display-only"}
        bad = [
            {"display_text": " ", "idempotency_key": "blank"},
            {"display_text": VISUAL, "speech_text": " \n", "idempotency_key": "blank-speech"},
            {"display_text": "a\0b", "idempotency_key": "nul"},
            {"display_text": VISUAL, "idempotency_key": "bad key"},
            {"display_text": VISUAL},
            {"speech_text": SPOKEN, "idempotency_key": "no-display"},
            {**ARGS, "autoplay": True},
            {"display_text": "가" * (inbox.MAX_TEXT_BYTES // 3 + 1), "idempotency_key": "big"},
            {"display_text": VISUAL, "speech_text": 3, "idempotency_key": "type"},
        ]
        frames += b"".join(call(args, 20 + i) for i, args in enumerate(bad))
        replies = run(frames, backend)[1:]
        expected = ["received", "duplicate", "conflict", "full", "disabled", "offline", "unsafe", "unconfirmed"]
        expected += ["invalid"] * len(bad)
        self.assertEqual(seen, [ARGS] * 8)
        for reply, status in zip(replies, expected):
            self.assertTrue(reply["result"]["content"][0]["text"].startswith(status + ":"), reply)
            self.assertEqual(reply["result"]["isError"], status not in ("received", "duplicate"))
        self.assertEqual(len(replies), len(expected))
        accepted = []
        run(INIT + READY + call(display_only), lambda args: accepted.append(args) or "received")
        self.assertEqual(accepted, [display_only])

    def test_largest_valid_submission_fits_stdio_and_ipc_frames(self):
        text = ("가\n" * (inbox.MAX_TEXT_BYTES // 4))[:inbox.MAX_TEXT_BYTES // 4 * 2]
        args = {"display_text": text, "speech_text": text, "idempotency_key": "k" * 128}
        self.assertTrue(inbox.valid_arguments(args))
        self.assertLess(len(call(args)), inbox.MAX_FRAME)
        self.assertLess(len(inbox.encode(args)), inbox.MAX_IPC_FRAME)

    def test_missing_socket_and_symlink_send_nothing(self):
        with tempfile.TemporaryDirectory(prefix="tts-inbox-test-", dir="/private/tmp") as directory:
            path = Path(directory) / "r.sock"
            self.assertEqual(inbox.submit_local(ARGS, path), "offline")
            path.symlink_to("no-socket")
            self.assertEqual(inbox.submit_local(ARGS, path), "unsafe")

    def test_default_path_is_not_the_speech_or_instruction_socket(self):
        self.assertEqual(inbox.socket_path().name, "r.sock")
        self.assertEqual(inbox.socket_path().parent, mcp_speech.socket_path().parent)
        self.assertNotEqual(inbox.socket_path(), mcp_speech.socket_path())


@unittest.skipUnless(sys.platform == "darwin", "Swift listener requires macOS")
class SwiftSocketTest(unittest.TestCase):
    """Production LocalScriptInboxSocket + ScriptInbox behind the production adapter client."""

    def test_swift_listener_stores_once_and_never_plays(self):
        build = REPO / "build"
        cache = build / "clt-check" / "cache"
        cache.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(prefix="cbtts-inbox-", dir="/private/tmp") as temp:
            root = Path(temp)
            os.chmod(root, 0o700)
            sdk = subprocess.check_output(["/usr/bin/xcrun", "--sdk", "macosx26.5", "--show-sdk-path"], text=True).strip()
            binary = root / "probe"
            subprocess.run(["/usr/bin/swiftc", str(REPO / "Sources/App/LocalScriptInboxSocket.swift"),
                            str(REPO / "Sources/Core/ExplainHandoff.swift"),
                            str(REPO / "Tests/Fixtures/LocalScriptInboxSocketProbe.swift"), "-o", str(binary)],
                           check=True, timeout=120,
                           env={"PATH": "/usr/bin:/bin", "HOME": str(root), "SDKROOT": sdk,
                                "CLANG_MODULE_CACHE_PATH": str(cache)})
            server = subprocess.Popen([str(binary), str(root)], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
            path = root / "r.sock"
            trusted = lambda _: True   # signer pinning is covered by test_mcp_peer_identity
            def ask(command):
                server.stdin.write(command + "\n"); server.stdin.flush()
                return server.stdout.readline().strip()
            try:
                line = server.stdout.readline().strip()
                if line != "ready":
                    self.skipTest("Sandbox denied temporary AF_UNIX bind: " + line)
                self.assertEqual(path.lstat().st_mode & 0o777, 0o600)
                self.assertEqual(inbox.submit_local(ARGS, path), "unsafe")   # no pinned signer → nothing sent
                self.assertEqual(ask("state"), "0 items")
                self.assertEqual(inbox.submit_local(ARGS, path, verify_peer=trusted), "received")
                self.assertEqual(inbox.submit_local(ARGS, path, verify_peer=trusted), "duplicate")
                self.assertEqual(inbox.submit_local({**ARGS, "speech_text": VISUAL}, path, verify_peer=trusted), "conflict")
                second = {"display_text": "둘째 해설입니다.", "idempotency_key": "synthetic-2"}
                self.assertEqual(inbox.submit_local(second, path, verify_peer=trusted), "received")
                self.assertEqual(ask("state"), "2 items")
                self.assertEqual(json.loads(ask("dump")), [[VISUAL, SPOKEN, "synthetic-1"], ["둘째 해설입니다.", "", "synthetic-2"]])
                # Wire-level rejects: speak_text frame, extra field, blank text.
                for frame in ({"text": "읽어", "idempotency_key": "speak"}, {**second, "play": True},
                              {"display_text": " ", "idempotency_key": "blank"}):
                    self.assertEqual(inbox.submit_local(frame, path, verify_peer=trusted), "invalid")
                self.assertEqual(ask("state"), "2 items")
                self.assertEqual(ask("off"), "off")
                self.assertFalse(path.exists())
                self.assertEqual(inbox.submit_local(second, path, verify_peer=trusted), "offline")
            finally:
                server.stdin.close()
                server.wait(timeout=5)
                server.stdout.close()


if __name__ == "__main__":
    unittest.main()
