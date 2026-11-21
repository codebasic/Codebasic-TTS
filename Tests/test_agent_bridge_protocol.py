#!/usr/bin/env python3
"""Hermetic MCP protocol tests for the agent bridge helper.

Usage (the binary path must be absolute):
    AGENT_BRIDGE_BIN=/abs/path/codebasic-tts-agent-bridge python3 Tests/test_agent_bridge_protocol.py
    python3 Tests/test_agent_bridge_protocol.py /abs/path/codebasic-tts-agent-bridge

The helper is always started WITHOUT a valid certificate pin, so it fails closed before it looks at
any socket: no real socket, app, model or network is touched.
"""
import json
import os
import subprocess
import sys
import tempfile
import unittest

BIN = os.environ.get("AGENT_BRIDGE_BIN", "")
NL = bytes([10])
SECRET = "SECRET-DRAFT-TEXT"


def req(ident, method, params=None):
    message = {"jsonrpc": "2.0", "id": ident, "method": method}
    if params is not None:
        message["params"] = params
    return message


def call(ident, name, arguments):
    return req(ident, "tools/call", {"name": name, "arguments": arguments})


def run(lines, extra_env=None):
    env = {"PATH": "/usr/bin:/bin", "CODEBASIC_TTS_APP_BUNDLE_ID": "com.example.hermetic-test-app"}
    if extra_env:
        env.update(extra_env)
    payload = b""
    for line in lines:
        payload += (line if isinstance(line, bytes) else json.dumps(line).encode("utf-8")) + NL
    with tempfile.TemporaryDirectory() as cwd:
        proc = subprocess.Popen([BIN], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE, env=env, cwd=cwd)
        out, err = proc.communicate(payload, timeout=30)
    responses = [json.loads(chunk.decode("utf-8")) for chunk in out.split(NL) if chunk]
    return proc, responses, out, err


def tool_payload(response):
    result = response["result"]
    content = result["content"]
    assert len(content) == 1 and content[0]["type"] == "text"
    return result["isError"], json.loads(content[0]["text"])


class AgentBridgeProtocolTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if not BIN:
            raise unittest.SkipTest("set AGENT_BRIDGE_BIN to the absolute path of the built helper")
        if not os.path.isabs(BIN) or not os.access(BIN, os.X_OK):
            raise RuntimeError("AGENT_BRIDGE_BIN must be an absolute path to an executable")

    def test_handshake_ping_and_tool_listing(self):
        init = {"protocolVersion": "2025-11-25", "capabilities": {},
                "clientInfo": {"name": "hermetic-test", "version": "0"}}
        proc, responses, _, err = run([
            req(1, "initialize", init),
            {"jsonrpc": "2.0", "method": "notifications/initialized"},
            req("p", "ping"),
            req(2, "tools/list"),
        ])
        self.assertEqual(proc.returncode, 0)
        self.assertEqual(err, b"")
        self.assertEqual([r["id"] for r in responses], [1, "p", 2])
        self.assertTrue(all(r["jsonrpc"] == "2.0" for r in responses))
        self.assertEqual(responses[0]["result"]["protocolVersion"], "2025-11-25")
        self.assertIn("tools", responses[0]["result"]["capabilities"])
        self.assertIn("name", responses[0]["result"]["serverInfo"])
        self.assertEqual(responses[1]["result"], {})
        tools = {tool["name"]: tool for tool in responses[2]["result"]["tools"]}
        self.assertEqual(set(tools), {"get_tts_instructions", "submit_explanation_draft"})
        self.assertEqual(tools["get_tts_instructions"]["inputSchema"]["properties"], {})
        self.assertIs(tools["get_tts_instructions"]["inputSchema"]["additionalProperties"], False)
        schema = tools["submit_explanation_draft"]["inputSchema"]
        self.assertEqual(set(schema["properties"]), {"revision", "display_text", "speech_text", "idempotency_key"})
        self.assertEqual(set(schema["required"]), {"revision", "display_text", "idempotency_key"})
        self.assertIs(schema["additionalProperties"], False)

    def test_unknown_protocol_version_falls_back_to_latest(self):
        _, responses, _, err = run([req(1, "initialize", {"protocolVersion": "1999-01-01"})])
        self.assertEqual(err, b"")
        self.assertEqual(responses[0]["result"]["protocolVersion"], "2025-11-25")

    def test_malformed_input_is_safe(self):
        proc, responses, out, err = run([
            b"{not json " + SECRET.encode("ascii"),
            b'{"jsonrpc":"2.0","id":1,"id":2,"method":"ping"}',
            b'{"jsonrpc":"2.0","method":"notifications/whatever","params":5}',
            b'{"method":"notifications/no-version"}',
            b'{"jsonrpc":"2.0","id":77,"result":{}}',
            b"[1,2]",
            req(9, "no/such/method"),
            call(10, "no_such_tool", {}),
            req(11, "tools/call", {"name": "get_tts_instructions", "arguments": []}),
            req(12, "ping"),
        ])
        self.assertEqual(proc.returncode, 0)
        self.assertEqual(err, b"")
        self.assertNotIn(SECRET.encode("ascii"), out)
        self.assertEqual(len(responses), 7)
        self.assertEqual([r["id"] for r in responses], [None, None, None, 9, 10, 11, 12])
        self.assertEqual([r["error"]["code"] for r in responses[:6]],
                         [-32700, -32700, -32600, -32601, -32602, -32602])
        self.assertEqual(responses[6]["result"], {})

    def test_tools_fail_closed_without_a_valid_pin(self):
        for extra in (None, {"CODEBASIC_TTS_SIGNER_SHA1": "not-a-pin"}, {"CODEBASIC_TTS_SIGNER_SHA1": ""}):
            with self.subTest(extra=extra):
                proc, responses, out, err = run([
                    call(1, "get_tts_instructions", {}),
                    call(2, "submit_explanation_draft",
                         {"revision": "r1", "display_text": SECRET, "speech_text": SECRET, "idempotency_key": "k-1"}),
                ], extra)
                self.assertEqual(proc.returncode, 0)
                self.assertEqual(err, b"")
                self.assertNotIn(SECRET.encode("ascii"), out)
                self.assertEqual([r["id"] for r in responses], [1, 2])
                for response in responses:
                    is_error, payload = tool_payload(response)
                    self.assertIs(is_error, True)
                    self.assertEqual(payload["status"], "unavailable")
                    self.assertEqual(payload["helper_pid"], proc.pid)
                    self.assertIn(str(proc.pid), payload["help"])

    def test_strict_argument_validation(self):
        good = {"revision": "r1", "display_text": "hello", "idempotency_key": "k-1"}

        def variant(**changes):
            args = dict(good)
            for key, value in changes.items():
                if value is None:
                    args.pop(key, None)
                else:
                    args[key] = value
            return args

        cases = [
            ("get_tts_instructions", {"x": 1}),
            ("submit_explanation_draft", variant(idempotency_key=None)),
            ("submit_explanation_draft", variant(revision=None)),
            ("submit_explanation_draft", variant(display_text=None)),
            ("submit_explanation_draft", variant(label="my helper")),
            ("submit_explanation_draft", variant(display_text="   ")),
            ("submit_explanation_draft", variant(display_text="a" * 8193)),
            ("submit_explanation_draft", variant(display_text=chr(233) * 4097)),
            ("submit_explanation_draft", variant(display_text="a" + chr(0) + "b")),
            ("submit_explanation_draft", variant(speech_text="")),
            ("submit_explanation_draft", variant(speech_text=7)),
            ("submit_explanation_draft", variant(idempotency_key="k y")),
            ("submit_explanation_draft", variant(idempotency_key="k" + chr(233))),
            ("submit_explanation_draft", variant(idempotency_key="k" * 129)),
            ("submit_explanation_draft", variant(revision=1)),
            ("submit_explanation_draft", variant(revision="")),
        ]
        lines = [call(index, name, args) for index, (name, args) in enumerate(cases)]
        proc, responses, _, err = run(lines)
        self.assertEqual(proc.returncode, 0)
        self.assertEqual(err, b"")
        self.assertEqual([r["id"] for r in responses], list(range(len(cases))))
        for response in responses:
            is_error, payload = tool_payload(response)
            self.assertIs(is_error, True)
            self.assertEqual(payload["status"], "invalid_arguments", response["id"])

    def test_boundary_sized_valid_draft_is_not_an_argument_error(self):
        args = {"revision": "r1", "display_text": "a" * 8192, "speech_text": chr(233) * 4096,
                "idempotency_key": "k" * 128}
        _, responses, _, err = run([call("big", "submit_explanation_draft", args)])
        self.assertEqual(err, b"")
        self.assertEqual(responses[0]["id"], "big")
        is_error, payload = tool_payload(responses[0])
        self.assertIs(is_error, True)
        self.assertEqual(payload["status"], "unavailable")


if __name__ == "__main__":
    if len(sys.argv) > 1 and os.path.isabs(sys.argv[-1]):
        BIN = sys.argv.pop()
    unittest.main()
