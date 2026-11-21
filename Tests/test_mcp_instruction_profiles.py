import json
from pathlib import Path
import subprocess
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent / "Fixtures"))
from mcp_instruction_profiles import FixtureSession, MAX_BYTES, SyntheticPublisher, encode

UID = 501
DRAFT = "합성 지시입니다. __init__, 0.84, @를 그대로 둡니다.\n"
INIT = {"jsonrpc":"2.0", "id":0, "method":"initialize", "params":{
    "protocolVersion":"2025-11-25", "capabilities":{}, "clientInfo":{"name":"fixture", "version":"1"}}}
READY = {"jsonrpc":"2.0", "method":"notifications/initialized"}


def call(profile="explain", tool="get_tts_instructions", **extra):
    return {"jsonrpc":"2.0", "id":2, "method":"tools/call", "params":{
        "name":tool, "arguments":{"profile":profile, **extra}}}


def connect(publisher, uid=UID, token=None):
    session = FixtureSession(publisher, uid, token)
    session.handle(encode(INIT)); session.handle(encode(READY))
    return session


def query(session, profile="explain"):
    return session.handle(encode(call(profile)))["result"]


class InstructionProfileTest(unittest.TestCase):
    def setUp(self):
        self.now = 0
        self.publisher = SyntheticPublisher(UID, clock=lambda: self.now)
        self.revision = self.publisher.stage("explain", DRAFT)
        self.other = self.publisher.stage("normalize", "합성 대본 지시 (별개 프로필)")

    def test_startup_real_stdio_is_off_and_has_no_speech_tool(self):
        p = Path(__file__).resolve().parent / "Fixtures" / "mcp_instruction_profiles.py"
        listing = {"jsonrpc":"2.0", "id":1, "method":"tools/list"}
        frames = (INIT, call(), READY, listing, call(), call(tool="speak_text"))
        run = subprocess.run([sys.executable, "-I", "-B", str(p)], input=b"".join(map(encode, frames)),
                             capture_output=True, check=True, timeout=5)
        init, before, tools, denied, no_speech = map(json.loads, run.stdout.splitlines())
        self.assertEqual(run.stderr, b"")
        self.assertNotIn("instructions", init["result"])
        self.assertEqual(before["error"]["code"], -32002)
        self.assertEqual([t["name"] for t in tools["result"]["tools"]], ["get_tts_instructions"])
        self.assertTrue(tools["result"]["tools"][0]["annotations"]["readOnlyHint"])
        self.assertTrue(denied["result"]["isError"])
        self.assertNotIn(b"SYNTHETIC ONLY", run.stdout)
        self.assertEqual(no_speech["error"]["code"], -32602)

    def test_approval_only_returns_externalized_profile_exactly(self):
        self.assertTrue(query(connect(self.publisher))["isError"])
        capability = self.publisher.approve("explain", self.revision, UID)
        result = query(connect(self.publisher, token=capability))
        result_data = result["structuredContent"]
        self.assertFalse(result["isError"])
        self.assertEqual(set(result_data), {"schema_version", "profile", "revision", "instructions"})
        self.assertEqual(result_data["revision"], self.revision)
        self.assertEqual(result_data["instructions"].encode(), DRAFT.encode())
        self.assertEqual(result["content"], [{"type":"text", "text":DRAFT}])
        self.assertNotIn(capability, json.dumps(result))
        self.assertTrue(query(connect(self.publisher, token=capability), "normalize")["isError"])

    def test_no_widening_from_uid_token_or_client_arguments(self):
        capability = self.publisher.approve("explain", self.revision, UID)
        for uid, token in [(UID + 1, capability), (UID, None), (UID, "0" * 64), (UID, "가" * 64)]:
            self.assertTrue(query(connect(self.publisher, uid=uid, token=token))["isError"])
        session = connect(self.publisher, token=capability)
        for msg in [call("../../settings.json"), call("missing"), call(profile=[], token=capability),
                    call(path="/tmp/settings.json"), call(token=capability)]:
            self.assertEqual(session.handle(encode(msg))["error"]["code"], -32602)
        with self.assertRaises(ValueError):
            self.publisher.approve("explain", self.revision, UID + 1)

    def test_revocation_and_expiry_affect_already_connected_sessions(self):
        capability = self.publisher.approve("explain", self.revision, UID, ttl_seconds=10)
        session = connect(self.publisher, token=capability)
        self.assertFalse(query(session)["isError"])
        self.publisher.revoke(capability)
        self.assertTrue(query(session)["isError"])
        capability = self.publisher.approve("explain", self.revision, UID, ttl_seconds=10)
        session = connect(self.publisher, token=capability)
        self.now = 9
        self.assertFalse(query(session)["isError"])
        self.now = 10
        self.assertTrue(query(session)["isError"])

    def test_revision_stable_on_same_text_but_edit_and_revert_need_new_approval(self):
        token = self.publisher.approve("explain", self.revision, UID)
        s = connect(self.publisher, token=token)
        self.assertEqual(self.publisher.stage("explain", DRAFT), self.revision)
        self.assertFalse(query(s)["isError"])
        newer = self.publisher.stage("explain", DRAFT + "새 버전입니다.")
        self.assertNotEqual(newer, self.revision)
        with self.assertRaises(ValueError):
            self.publisher.approve("explain", self.revision, UID)
        self.assertTrue(query(s)["isError"])
        self.assertEqual(self.publisher.stage("explain", DRAFT), self.revision)
        self.assertTrue(query(s)["isError"])
        newer_token = self.publisher.approve("explain", self.revision, UID)
        self.assertFalse(query(connect(self.publisher, token=newer_token))["isError"])
        self.assertNotEqual(self.publisher.stage("continue", DRAFT), self.revision)

    def test_oversized_draft_rejected_without_overwriting_approved_snapshot(self):
        capability = self.publisher.approve("explain", self.revision, UID)
        session = connect(self.publisher, token=capability)
        for body in ("한" * MAX_BYTES, "\0", "   ", "\ud800"):
            with self.assertRaises(ValueError):
                self.publisher.stage("explain", body)
        self.assertEqual(query(session)["structuredContent"]["revision"], self.revision)
        self.assertEqual(query(session)["structuredContent"]["instructions"], DRAFT)
