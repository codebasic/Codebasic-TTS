import io
import json
import os
from pathlib import Path
import plistlib
import sys
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
import mcp_speech as common
import mcp_tts_draft as draft

INIT = {"jsonrpc": "2.0", "id": 1, "method": "initialize",
        "params": {"protocolVersion": common.PROTOCOL, "capabilities": {}, "clientInfo": {"name": "fixture", "version": "1"}}}
READY = {"jsonrpc": "2.0", "method": "notifications/initialized"}
LIST = {"jsonrpc": "2.0", "id": 2, "method": "tools/list"}
ARGS = {"idempotency_key": "case-1", "display_text": "as_frame 옵션", "speech_text": "애즈 프레임 옵션"}


def call(args, tool=draft.TOOL["name"], ident=3):
    return {"jsonrpc": "2.0", "id": ident, "method": "tools/call", "params": {"name": tool, "arguments": args}}


class DraftAdapterTests(unittest.TestCase):
    def run_session(self, backend, *frames, prefix=True):
        output = io.BytesIO()
        wire = b"".join(common.encode(x) for x in ((INIT, READY) if prefix else ()))
        wire += b"".join(x if isinstance(x, bytes) else common.encode(x) for x in frames)
        common.run(io.BytesIO(wire), output, session=draft.DraftSession(backend), max_frame=draft.MAX_FRAME)
        return [json.loads(line) for line in output.getvalue().splitlines()]

    def test_discovery_is_receive_only_and_acceptance_is_not_audio(self):
        seen = []
        def accept(args):
            seen.append(args)
            return "accepted"
        init, tools, response, speak, instructions = self.run_session(
            accept, LIST, call(ARGS), call(ARGS, "speak_text"), call(ARGS, "get_tts_instructions"))
        self.assertEqual(init["result"]["serverInfo"]["name"], "codebasic-tts-draft")
        self.assertEqual([item["name"] for item in tools["result"]["tools"]], ["submit_explanation_draft"])
        self.assertEqual(seen, [ARGS])
        self.assertIn("Nothing has been applied to the editor or played", response["result"]["content"][0]["text"])
        self.assertNotIn(ARGS["display_text"], json.dumps(response, ensure_ascii=False))
        self.assertEqual([x["error"]["code"] for x in (speak, instructions)], [-32602, -32602])

    def test_validation_and_utf8_limits(self):
        self.assertTrue(draft.valid_arguments(ARGS))
        self.assertTrue(draft.valid_arguments({k: v for k, v in ARGS.items() if k != "speech_text"}))
        self.assertTrue(draft.valid_arguments({**ARGS, "display_text": "a" * 8192, "speech_text": "a" * 8192}))
        bad = [None, [], {}, {**ARGS, "display_text": "가" * 2731}, {**ARGS, "speech_text": None},
               {**ARGS, "speech_text": " "}, {**ARGS, "display_text": "a\x00b"},
               {**ARGS, "play": True}, {**ARGS, "path": "filepath"}, {**ARGS, "idempotency_key": "a b"}]
        rows = self.run_session(lambda _: self.fail("invalid payload reached backend"), *(call(x) for x in bad))
        self.assertTrue(all(r["result"]["isError"] for r in rows[1:]))

    def test_retry_statuses_and_pid_when_no_permission(self):
        outcomes = iter(("duplicate", "conflict", "busy", "unconfirmed", "offline", "unsafe"))
        statuses = self.run_session(lambda _: next(outcomes), *(call(ARGS) for _ in range(6)))[1:]
        self.assertFalse(statuses[0]["result"]["isError"])
        self.assertTrue(all(r["result"]["isError"] for r in statuses[1:]))
        self.assertIn(str(os.getpid()), statuses[4]["result"]["content"][0]["text"])

    def test_oversized_or_duplicate_frames_never_reach_backend(self):
        rows = self.run_session(lambda _: self.fail("bad frame reached backend"),
                                b"{" + b"x" * draft.MAX_FRAME + common.encode(call(ARGS)),
                                b'{"method":"tools/call","method":"ping","jsonrpc":"2.0","id":4}\n',
                                {"jsonrpc": "2.0", "id": 5, "method": "ping"})
        self.assertEqual([rows[i]["error"]["code"] for i in (1, 2)], [-32700, -32700])
        self.assertEqual(rows[-1]["result"], {})

    def test_old_shortcut_and_service_cannot_launch_explanation(self):
        root = Path(__file__).resolve().parents[1]
        with (root / "Resources/Info.plist").open("rb") as plist:
            services = plistlib.load(plist)["NSServices"]
        self.assertEqual([s["NSMessage"] for s in services], ["readSelectedText"])
        delegate = (root / "Sources/App/AppDelegate.swift").read_text()
        self.assertIn("kVK_ANSI_R", delegate)
        self.assertNotIn("kVK_ANSI_E", delegate)
        self.assertNotIn("explainAndSpeak(", delegate)

    def test_legacy_submit_fails_closed_without_contacting_any_socket(self):
        with patch.object(common.socket, "socket") as factory:
            self.assertEqual(draft.submit(ARGS), "upgrade_required")
            factory.assert_not_called()
        rows = self.run_session(draft.submit, call(ARGS))
        self.assertTrue(rows[-1]["result"]["isError"])
        self.assertIn("paste the draft manually", rows[-1]["result"]["content"][0]["text"])
