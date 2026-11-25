#!/usr/bin/env python3
"""Exercise signed per-app draft receipt over the bundled helper's MCP stdio.

The signed receiver hosts the actual controller and SQLite draft workspace.
Hosts and their isolated test keys are fixtures, with no live app, user keychain
or synthesis providers involved. Run on macOS with the repo's signing identity.
"""

from concurrent.futures import ThreadPoolExecutor
from contextlib import ExitStack, closing
import json
import os
from pathlib import Path
import plistlib
import shutil
import signal
import sqlite3
import subprocess
import tempfile

from run_persistent_pairing import BUILD, HERE, IDENTITY, REPO, SOURCES, Server, Session


APP_ID = "com.codebasic.tts.fixture.receiver"


def run(*arguments, env=None):
    subprocess.run(arguments, env=env, check=True, timeout=300)


def sign(path, identifier, identity=IDENTITY):
    run("/usr/bin/codesign", "--force", "--options", "runtime", "--timestamp=none", "--sign", identity,
        "--identifier", identifier, path)
    run("/usr/bin/codesign", "--verify", "--strict", path)


def build(root):
    # Recompile only the test fixture with a socket location relative to its cwd.
    # The relative path also stays below macOS's sockaddr_un path limit.
    runtime = root / "TTSRuntime.swift"
    original = (SOURCES / "Core/TTSRuntime.swift").read_text()
    location = r'"/private/tmp/\(prefix)-\(uid)"'
    assert original.count(location) == 1
    product_id = '"com.seongjoo.SelectedTextTTS"'
    assert original.count(product_id) == 1
    runtime.write_text(original.replace(location, r'"\(prefix)"').replace(product_id, f'"{APP_ID}"'))
    sdk = subprocess.check_output(
        ["/usr/bin/xcrun", "--sdk", "macosx26.5", "--show-sdk-path"], text=True
    ).strip()
    env = {
        "PATH": "/usr/bin:/bin",
        "HOME": str(root),
        "TMPDIR": str(root),
        "SDKROOT": sdk,
        "CLANG_MODULE_CACHE_PATH": str(BUILD / "module-cache"),
    }
    common = [runtime, SOURCES / "App/AgentPeerSigning.swift", SOURCES / "Core/AgentCatalog.swift"]
    receiver = [
        SOURCES / "App/LocalInstructionSocket.swift",
        SOURCES / "App/AgentSessionController.swift",
        SOURCES / "Core/AgentTrustStore.swift",
        SOURCES / "Core/AgentDeliveryProofs.swift",
        SOURCES / "Core/ExplanationDraftWorkspace.swift",
        SOURCES / "Core/DraftStore.swift",
        SOURCES / "Core/AgentInstructionEditing.swift",
        HERE / "LocalExplanationDraftSocketProbe.swift",
    ]
    helper_source = REPO / "Helpers/AgentCatalogMCP.swift"
    different_source = root / "DifferentHelper.swift"
    helper_text = helper_source.read_text()
    version = '"version":"2.0"'
    assert helper_text.count(version) == 1
    different_source.write_text(helper_text.replace(version, '"version":"2.0-fixture-other"'))

    def swift(output, files, *flags):
        run("/usr/bin/swiftc", "-framework", "Security", *flags, *common, *files, "-o", root / output, env=env)

    swift("server", receiver, "-lsqlite3")
    sign(root / "server", APP_ID)
    helper = root / "helper"
    helper_id = APP_ID + ".agent-helper"
    swift("helper", [helper_source], "-D", "TTS_AGENT_FIXTURE_KEYS")
    sign(helper, helper_id)
    swift("other-helper", [different_source], "-D", "TTS_AGENT_FIXTURE_KEYS")
    sign(root / "other-helper", helper_id)
    shutil.copy2(helper, root / "adhoc-helper")
    sign(root / "adhoc-helper", helper_id, "-")

    return build_hosts(root, env)


def build_hosts(root, env):
    launcher = root / "launcher"
    run("/usr/bin/clang", "-Wall", "-Wextra", "-Werror", HERE / "AgentMCPHost.c", "-o", launcher, env=env)
    hosts = {}
    for name, registered in (("A", True), ("B", True), ("Broker", False)):
        bundle = root / (name + ".app")
        binary = bundle / "Contents/MacOS/AgentMCPHost"
        binary.parent.mkdir(parents=True)
        shutil.copy2(launcher, binary)
        identifier = "com.codebasic.tts.fixture." + name.lower()
        info = {
            "CFBundleExecutable": binary.name,
            "CFBundleIdentifier": identifier,
            "CFBundleName": "Same Agent Name",
            "CFBundlePackageType": "APPL",
            "CFBundleVersion": "1",
        }
        with (bundle / "Contents/Info.plist").open("wb") as plist:
            plistlib.dump(info, plist)
        # A certificate-signed app is identified by its signature; an ad-hoc signed
        # one cannot be told apart from other apps, so its approval lasts one run.
        sign(bundle, identifier, IDENTITY if registered else "-")
        hosts[name] = binary
    return hosts


def clients(server):
    return json.loads(server("clients"))


def requests(server):
    return json.loads(server("requests"))


def expect_status(client, expected):
    state = client.status()
    assert state == expected, (state, expected)


def approve(server, client, request):
    assert server("approve " + request["id"]) == "ok"
    expect_status(client, "receiving_only")


def stored_documents(database):
    with closing(sqlite3.connect(database.as_uri() + "?mode=ro", uri=True)) as db:
        return [(document_id, title, json.loads(body))
                for document_id, title, body in db.execute("SELECT id, title, body FROM drafts ORDER BY seq")]


def check(message):
    print("PASS", message, flush=True)


def verify(root, hosts):
    database = root / "drafts.sqlite"
    trust = root / "agent-clients.json"
    keys = root / "test-keys"
    keys.mkdir(mode=0o700)
    env = {"PATH": "/usr/bin:/bin", "HOME": str(root), "TMPDIR": str(root)}
    same_name = "same-agent-name"
    sample_a = {"display": "A의 표시 원고\n문장 둘 e\u0301", "speech": "가의 발음용 원고", "title": "A 제목"}
    sample_b = {"display": "B의 표시 원고\n문장 둘 🎧", "speech": "나의 발음용 원고", "title": "B 제목"}

    with ExitStack() as resources:
        def app():
            server = Server(root, env, "codebasic-tts-mcp", trust, database=database)
            resources.callback(server.end)
            assert server("pair") == "ok" and server("configure") == "ok"
            return server

        def connect(host, helper="helper", key_dir=keys):
            session = Session(str(root / helper), name=same_name, launcher=[hosts[host]], cwd=root,
                              env={**env, "TTS_AGENT_FIXTURE_KEY_DIR": str(key_dir)},
                              start_new_session=True)
            resources.callback(session.close)
            return session

        server = app()
        assert server("enable") == "ok"
        a = connect("A")
        expect_status(a, "approval_required")
        request_a, = requests(server)
        b = connect("B")
        expect_status(b, "approval_required")
        request_b, = (request for request in requests(server) if request["id"] != request_a["id"])
        assert request_a["label"] == request_b["label"] == same_name
        assert request_a["host"] and request_b["host"] and request_a["host"] != request_b["host"]
        for client in (a, b):
            assert client.send("before-approval", "승인 전 원고")["outcome"] == "rejected"
        assert stored_documents(database) == []

        approve(server, a, request_a)
        assert a.send("single-client", "선택 지시와 제목이 없는 원고")["status"] == "accepted"
        client_a, = clients(server)
        expect_status(b, "approval_required")
        check("a single approved client submits the existing plain draft shape")

        approve(server, b, request_b)
        client_b, = (client for client in clients(server) if client["id"] != client_a["id"])
        assert client_a["label"] == client_b["label"] == same_name
        assert client_a["persistent"] and client_b["persistent"]
        distinct_ids = {client_a["id"], client_b["id"]}
        overlapping_a = connect("A")
        expect_status(overlapping_a, "other_agent")
        overlapping_a.close()
        check("two distinct registered host identities with the same label require independent approvals")

        # Both hosts submit concurrently with the same caller-chosen key.
        with ThreadPoolExecutor(max_workers=2) as workers:
            sent_a = workers.submit(a.send, "equal-key", **sample_a)
            sent_b = workers.submit(b.send, "equal-key", **sample_b)
            assert sent_a.result()["status"] == sent_b.result()["status"] == "accepted"
        rows = stored_documents(database)[1:]
        assert len(rows) == 2 and len({row[0] for row in rows}) == 2
        actual = {title: {field: document["original"][field] for field in ("display", "speech", "title")}
                  for _, title, document in rows}
        assert actual == {sample_a["title"]: sample_a, sample_b["title"]: sample_b}
        check("concurrent same-key drafts arrive once per app with separate title, display and speech fields")

        first = a.send("lost-answer", "응답이 유실된 원고", discard_reply=True)
        replay = a.retry()
        assert first["outcome"] == "unconfirmed" and replay["status"] == "duplicate"
        assert replay["request_id"] != first["request_id"] and len(stored_documents(database)) == 4
        assert a.send("lost-answer", "내용이 바뀐 원고")["status"] == "conflict"
        check("discarded MCP reply can be checked once with the same key and new request ID")

        assert server("select " + client_a["id"]) == "ok"
        expect_status(a, "ready")
        expect_status(b, "receiving_only")
        instruction = a.read_instruction()
        assert instruction and b.read_instruction() is None
        assert b.send("copied-profile", "다른 앱의 지시", profile=instruction["profile"],
                      revision=instruction["revision"])["outcome"] == "rejected"
        assert b.send("plain-with-other-selection", "독립된 B 원고")["status"] == "accepted"
        assert a.send("linked", "지시를 읽은 A 원고", profile=instruction["profile"],
                      revision=instruction["revision"])["status"] == "accepted"
        assert server("revoke") == "ok"
        check("instruction read and revision proof stay scoped to the selected app")

        a.close()
        a = connect("A")
        expect_status(a, "receiving_only")
        assert a.send("equal-key", **sample_a)["status"] == "duplicate"
        expect_status(b, "receiving_only")
        os.killpg(a.proc.pid, signal.SIGKILL)
        a.proc.wait(timeout=8)
        a = connect("A")
        expect_status(a, "receiving_only")
        assert a.send("after-host-restart", "A 호스트 재실행 뒤 원고")["status"] == "accepted"
        assert b.send("other-host-restarted", "B는 연결 유지")["status"] == "accepted"
        assert {client["id"] for client in clients(server)} == distinct_ids
        check("A clean exit and SIGKILL reattach to A only while B keeps receiving")

        broker = connect("Broker")
        expect_status(broker, "approval_required")
        pending_broker, = requests(server)
        assert server("lock") == "ok"
        for client in (a, b, broker):
            expect_status(client, "locked")
        assert server("approve " + pending_broker["id"]) == "no" and requests(server) == []
        assert server("unlock") == "ok"
        for client in (a, b):
            expect_status(client, "receiving_only")
        expect_status(broker, "approval_required")
        broker_request, = requests(server)
        assert broker_request["id"] != pending_broker["id"]
        approve(server, broker, broker_request)
        assert any(not client["persistent"] for client in clients(server))
        broker.close()
        broker = connect("Broker")
        expect_status(broker, "approval_required")
        assert broker.send("broker-restart", "공용 런처의 재실행 원고")["outcome"] == "rejected"
        broker.close()
        check("lock cancels stale approvals and an ad-hoc signed host requires approval for each run")

        assert server("disconnect " + client_a["id"]) == "ok"
        expect_status(a, "disabled")
        expect_status(b, "receiving_only")
        assert a.send("after-disconnect", "연결 해제 뒤 원고")["outcome"] == "rejected"
        server.end()
        server = app()
        expect_status(a, "disabled")
        expect_status(b, "receiving_only")
        assert b.send("equal-key", **sample_b)["status"] == "duplicate"
        assert b.send("equal-key", "다른 B 본문")["status"] == "conflict"
        assert server("resume " + client_a["id"]) == "ok"
        expect_status(a, "receiving_only")
        assert a.send("equal-key", **sample_a)["status"] == "duplicate"
        assert a.send("after-server-restart", "수신기 재실행 뒤 원고")["status"] == "accepted"
        check("per-app disable and draft idempotency survive receiver restart independently")

        assert server("disable") == "ok"
        for client in (a, b):
            expect_status(client, "disabled")
        server.end()
        server = app()
        for client in (a, b):
            expect_status(client, "disabled")
        assert server("enable") == "ok"
        for client in (a, b):
            expect_status(client, "receiving_only")

        # Simulate replacement of A's key without changing the registered host.
        # An already queued approval for that host must not outlive its revocation.
        new_keys = root / "replacement-keys"
        new_keys.mkdir(mode=0o700)
        rotated = connect("A", key_dir=new_keys)
        expect_status(rotated, "approval_required")
        pending_a, = requests(server)
        broker = connect("Broker")
        expect_status(broker, "approval_required")
        pending_other, = (request for request in requests(server) if request["id"] != pending_a["id"])
        assert server("forget " + client_a["id"]) == "ok"
        assert server("approve " + pending_a["id"]) == "no"
        assert [request["id"] for request in requests(server)] == [pending_other["id"]]
        rotated.close()
        broker.close()
        expect_status(a, "revoked")
        assert a.send("after-revoke", "철회 뒤 차단되는 원고")["outcome"] == "rejected"
        a.close()
        a = connect("A")
        expect_status(a, "revoked")
        expect_status(b, "receiving_only")
        assert b.send("after-other-revoke", "다른 앱 철회 뒤의 B 원고")["status"] == "accepted"
        check("master off survives restart; revocation clears A's pending approvals and blocks its old key")

        other = connect("B", helper="other-helper")
        expect_status(other, "app_unavailable")
        adhoc = connect("B", helper="adhoc-helper")
        expect_status(adhoc, "signing_required")
        assert requests(server) == []
        check("same-signer wrong helper build and ad-hoc helper cannot pair")


def main():
    BUILD.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="agent-apps-", dir=BUILD) as temp:
        root = Path(temp)
        verify(root, build(root))


if __name__ == "__main__":
    main()
