#!/usr/bin/env python3
"""Offline discovery and consent tests for the agent bridge helper.

Usage (both paths absolute):
    AGENT_BRIDGE_BIN=/abs/bridge AGENT_BRIDGE_FIXTURE_BIN=/abs/bridge-fixture python3 <this file>

AGENT_BRIDGE_BIN is the normal build. Here it is unsigned, so it must fail closed before it looks
at any socket. AGENT_BRIDGE_FIXTURE_BIN is the same source compiled with -D AGENT_BRIDGE_TEST_SEAM:
the signature check is replaced by the kernel peer identity (UID, PID, start time) and the socket
root comes from AGENT_BRIDGE_TEST_ROOT, so this file can play the app. The fixture is never shipped.
No real app, socket directory, model, network or credential is touched.
"""
import ctypes
import json
import os
import shutil
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time
import unittest

BIN = os.environ.get("AGENT_BRIDGE_BIN", "")
FIXTURE = os.environ.get("AGENT_BRIDGE_FIXTURE_BIN", "")
NL = bytes([10])
PROFILE = "6F0C2B5E-3A41-4D7B-9C1E-0A5D8E2F7B10"
REVISION = PROFILE + ".2." + "ab" * 32
INSTRUCTIONS = {"schema_version": 2, "profile_id": PROFILE, "revision": REVISION,
                "instructions": "Explain the synthetic change."}
DRAFT = {"revision": REVISION, "display_text": "synthetic display", "speech_text": "synthetic speech",
         "idempotency_key": "k-1"}


def start_identity(pid):
    """Kernel start time (seconds, microseconds) of a process: proc_bsdinfo.pbi_start_tv*."""
    libc = ctypes.CDLL(None)
    libc.proc_pidinfo.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_uint64, ctypes.c_void_p, ctypes.c_int]
    libc.proc_pidinfo.restype = ctypes.c_int
    buf = ctypes.create_string_buffer(136)
    if libc.proc_pidinfo(pid, 3, 0, buf, 136) != 136:
        raise RuntimeError("proc_pidinfo failed")
    return struct.unpack_from("<QQ", buf.raw, 120)


def generation_name(pid=None, shift=0):
    pid = os.getpid() if pid is None else pid
    seconds, micro = start_identity(pid)
    return "g%d.%d.%d" % (pid, seconds - shift, micro)


class Endpoint:
    """One synthetic endpoint: records every request, answers each non-empty one with one frame."""

    def __init__(self, path, reply):
        self.requests = []
        self.reply = reply
        self.stopped = False
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.bind(path)
        os.chmod(path, 0o600)
        self.sock.listen(8)
        self.sock.settimeout(0.1)
        self.thread = threading.Thread(target=self._serve, daemon=True)
        self.thread.start()

    def _serve(self):
        while not self.stopped:
            try:
                conn, _ = self.sock.accept()
            except OSError:
                continue
            data = b""
            try:
                conn.settimeout(5)
                while True:
                    chunk = conn.recv(65536)
                    if not chunk:
                        break
                    data += chunk
                self.requests.append(data)
                if data and self.reply is not None:
                    conn.sendall(json.dumps(self.reply).encode("utf-8") + NL)
            except OSError:
                pass
            finally:
                conn.close()

    def close(self):
        self.stopped = True
        self.thread.join()
        self.sock.close()


class FakeApp:
    """Plays one app generation inside a private test root."""

    def __init__(self, root, name=None):
        self.directory = os.path.join(root, name or generation_name())
        os.mkdir(self.directory, 0o700)
        self.endpoints = []

    def serve(self, name, reply):
        endpoint = Endpoint(os.path.join(self.directory, name), reply)
        self.endpoints.append(endpoint)
        return endpoint

    def close(self):
        for endpoint in self.endpoints:
            endpoint.close()


def consent(status):
    return {"protocol": 3, "status": status}


def call(ident, name, arguments):
    return {"jsonrpc": "2.0", "id": ident, "method": "tools/call", "params": {"name": name, "arguments": arguments}}


def run_bridge(binary, root, lines):
    env = {"PATH": "/usr/bin:/bin"}
    if root is not None:
        env["AGENT_BRIDGE_TEST_ROOT"] = root
    payload = b"".join(json.dumps(line).encode("utf-8") + NL for line in lines)
    with tempfile.TemporaryDirectory() as cwd:
        proc = subprocess.Popen([binary], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE, env=env, cwd=cwd)
        out, err = proc.communicate(payload, timeout=120)
    responses = [json.loads(chunk.decode("utf-8")) for chunk in out.split(NL) if chunk]
    return proc, responses, err


def tool_payload(response):
    result = response["result"]
    return result["isError"], json.loads(result["content"][0]["text"])


class DiscoveryTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        for path in (BIN, FIXTURE):
            if not path:
                raise unittest.SkipTest("set AGENT_BRIDGE_BIN and AGENT_BRIDGE_FIXTURE_BIN")
            if not os.path.isabs(path) or not os.access(path, os.X_OK):
                raise RuntimeError("bridge paths must be absolute paths to executables")

    def setUp(self):
        self.root = tempfile.mkdtemp(prefix="cbtts-", dir="/private/tmp")
        self.apps = []
        self.addCleanup(self._cleanup)

    def _cleanup(self):
        for app in self.apps:
            app.close()
        shutil.rmtree(self.root, ignore_errors=True)

    def app(self, status, name=None):
        app = FakeApp(self.root, name)
        self.apps.append(app)
        app.consent = app.serve("c.sock", consent(status))
        app.read = app.serve("ai.sock", INSTRUCTIONS)
        app.draft = app.serve("ad.sock", {"status": "accepted"})
        return app

    def tools(self, binary=None, root=None, calls=None):
        calls = calls or [call(1, "get_tts_instructions", {}), call(2, "submit_explanation_draft", DRAFT)]
        proc, responses, err = run_bridge(binary or FIXTURE, root or self.root, calls)
        self.assertEqual(proc.returncode, 0)
        self.assertEqual(err, b"")  # MCP on stdout only, nothing on stderr
        self.assertTrue(all(r["jsonrpc"] == "2.0" for r in responses))
        self.assertEqual([r["id"] for r in responses], [c["id"] for c in calls])
        return proc, [tool_payload(r) for r in responses]

    def assert_unavailable(self, results, reason, pid):
        for is_error, payload in results:
            self.assertIs(is_error, True)
            self.assertEqual(payload["status"], "unavailable")
            self.assertEqual(payload["reason"], reason)
            self.assertEqual(payload["helper_pid"], pid)
            self.assertNotIn("synthetic", json.dumps(payload))

    def test_app_closed_start_list_and_calls(self):
        init = {"jsonrpc": "2.0", "id": 0, "method": "initialize", "params": {"protocolVersion": "2025-06-18"}}
        listing = {"jsonrpc": "2.0", "id": 9, "method": "tools/list"}
        proc, responses, err = run_bridge(FIXTURE, self.root, [init, listing])
        self.assertEqual((proc.returncode, err), (0, b""))
        self.assertEqual(responses[0]["result"]["protocolVersion"], "2025-06-18")
        self.assertEqual({tool["name"] for tool in responses[1]["result"]["tools"]},
                         {"get_tts_instructions", "submit_explanation_draft"})
        proc, results = self.tools()
        self.assert_unavailable(results, "app_not_running", proc.pid)
        proc, results = self.tools(root=os.path.join(self.root, "missing"))
        self.assert_unavailable(results, "app_not_running", proc.pid)

    def test_app_open_pending_denied_busy_share_nothing(self):
        app = self.app("pending")
        for status, reason in (("pending", "approval_pending"), ("denied", "approval_denied"),
                               ("busy", "approval_busy")):
            with self.subTest(status=status):
                app.consent.reply = consent(status)
                proc, results = self.tools()
                self.assert_unavailable(results, reason, proc.pid)
        self.assertEqual(len(app.consent.requests), 6)
        for request in app.consent.requests:
            self.assertEqual(json.loads(request), {"operation": "hello", "protocol": 3})
        self.assertEqual(app.read.requests + app.draft.requests, [])

    def test_exact_two_way_roundtrip_after_approval(self):
        app = self.app("approved")
        _, results = self.tools()
        self.assertEqual(results[0], (False, INSTRUCTIONS))
        self.assertEqual(results[1], (False, {"status": "accepted"}))
        self.assertEqual(app.read.requests, [b'{"operation":"get"}' + NL])
        self.assertEqual(len(app.draft.requests), 1)
        self.assertTrue(app.draft.requests[0].endswith(NL))
        self.assertEqual(json.loads(app.draft.requests[0]), DRAFT)
        submit = [call(5, "submit_explanation_draft", DRAFT)]
        for status, is_error, shown in (("duplicate", False, "duplicate"), ("stale_revision", True, "stale_revision"),
                                        ("conflict", True, "conflict"), ("played", True, "unconfirmed")):
            with self.subTest(status=status):
                app.draft.reply = {"status": status}
                _, results = self.tools(calls=submit)
                self.assertEqual((results[0][0], results[0][1]["status"]), (is_error, shown))
        app.read.reply = None
        proc, results = self.tools(calls=[call(6, "get_tts_instructions", {})])
        self.assert_unavailable(results, "nothing_shared", proc.pid)

    def test_wrong_identity_gets_no_request_byte(self):
        # The directory is named for another live process (our parent) while this process listens.
        app = self.app("approved", generation_name(os.getppid()))
        proc, results = self.tools()
        self.assert_unavailable(results, "app_not_running", proc.pid)
        time.sleep(0.3)
        self.assertTrue(all(request == b"" for request in app.consent.requests))
        self.assertEqual(app.read.requests + app.draft.requests, [])

    def test_restart_ignores_stale_generation_and_old_socket_path(self):
        # The old fixed path with a live listener, and a dead generation that left its socket behind.
        legacy = Endpoint(os.path.join(self.root, "ai.sock"), INSTRUCTIONS)
        legacy_consent = Endpoint(os.path.join(self.root, "c.sock"), consent("approved"))
        stale_dir = os.path.join(self.root, generation_name(shift=5))
        os.mkdir(stale_dir, 0o700)
        stale = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        stale.bind(os.path.join(stale_dir, "c.sock"))
        stale.close()
        try:
            proc, results = self.tools()
            self.assert_unavailable(results, "app_not_running", proc.pid)
            app = self.app("approved")  # the restarted app: a new generation next to the stale one
            _, results = self.tools()
            self.assertEqual(results[0], (False, INSTRUCTIONS))
            self.assertEqual(len(app.consent.requests), 2)
            time.sleep(0.3)
            self.assertEqual(legacy.requests + legacy_consent.requests, [])
            self.assertTrue(os.path.exists(os.path.join(stale_dir, "c.sock")))
        finally:
            legacy.close()
            legacy_consent.close()

    def test_two_live_apps_are_never_resolved_silently(self):
        app = self.app("approved")
        other = subprocess.Popen([sys.executable, "-I", os.path.abspath(__file__), "--fake-app", self.root],
                                 stdin=subprocess.PIPE, stdout=subprocess.PIPE)
        try:
            self.assertEqual(other.stdout.readline(), b"ready" + NL)
            proc, results = self.tools()
            self.assert_unavailable(results, "multiple_apps", proc.pid)
            self.assertEqual(app.read.requests + app.draft.requests, [])
        finally:
            other.stdin.close()
            other.wait(timeout=30)
            other.stdout.close()
        _, results = self.tools(calls=[call(3, "get_tts_instructions", {})])
        self.assertEqual(results[0], (False, INSTRUCTIONS))

    def test_unsigned_production_build_fails_closed_and_ignores_the_environment(self):
        app = self.app("approved")
        proc, results = self.tools(binary=BIN)
        self.assert_unavailable(results, "bridge_not_signed", proc.pid)
        time.sleep(0.3)
        self.assertEqual(app.consent.requests + app.read.requests + app.draft.requests, [])


def fake_app_main(root):
    app = FakeApp(root)
    app.serve("c.sock", consent("approved"))
    app.serve("ai.sock", INSTRUCTIONS)
    sys.stdout.write("ready" + chr(10))
    sys.stdout.flush()
    sys.stdin.read()
    app.close()


def main():
    if len(sys.argv) == 3 and sys.argv[1] == "--fake-app":
        fake_app_main(sys.argv[2])
    else:
        unittest.main()


if __name__ == "__main__":
    main()
