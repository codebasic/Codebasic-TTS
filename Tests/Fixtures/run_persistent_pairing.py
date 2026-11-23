#!/usr/bin/env python3
"""Persistent agent pairing, end to end: the real signed helper and the app's real
session controller, synthetic Korean drafts only. Everything lives under build/
except the client keys, which go to the login keychain under one-off slot names
and are deleted at the end. No installed app, user instruction, voice or provider
is touched.

  run_persistent_pairing.py                 fixed scenarios, a few minutes of short waits
  run_persistent_pairing.py --real-idle plain|linked
                                            one approval, then a real idle beyond 600 s
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import selectors
import shutil
import subprocess
import sys
import tempfile
import time
import uuid

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
BUILD = Path(os.environ.get("TTS_BUILD_DIR", REPO / "build")).resolve()
SOURCES = REPO / "Sources"
APP_ID = "com.seongjoo.SelectedTextTTS"
sys.path.insert(0, str(REPO / "Helpers"))
from tts_mcp_client import Session, TEXT_LIMIT  # noqa: E402

IDENTITY = os.environ.get("CODESIGN_IDENTITY", "Codebasic TTS Local")
passed = []


def ok(name):
    passed.append(name)
    print("PASS", name, flush=True)


def digest(text):
    data = text.encode("utf-8")
    return hashlib.sha256(data).hexdigest() + ":" + str(len(data))


def korean(size):
    """Exactly `size` UTF-8 bytes of Hangul, other non-ASCII, and newlines."""
    unit = "수업 정리: 합성 음성 대본 é ü 🎧\n둘째 줄 — “따옴표” 포함\n"
    text = ""
    while len((text + unit).encode("utf-8")) <= size:
        text += unit
    return text + "가" * ((size - len(text.encode("utf-8"))) // 3) + "." * ((size - len(text.encode("utf-8"))) % 3)


class Server:
    def __init__(self, root, env, ipc, trust, waiting=90000):
        self.proc = subprocess.Popen([str(root / "server"), ipc, str(root / "helper"), str(waiting), str(trust)],
                                     cwd=root, env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                     stderr=subprocess.DEVNULL, text=True)
        assert self._line() == "ready"

    def _line(self):
        with selectors.DefaultSelector() as handles:
            handles.register(self.proc.stdout, selectors.EVENT_READ)
            if not handles.select(8):
                raise TimeoutError("app fixture did not answer")
            return self.proc.stdout.readline().strip()

    def __call__(self, command):
        self.proc.stdin.write(command + "\n")
        self.proc.stdin.flush()
        return self._line()

    def snapshot(self):
        return json.loads(self("snapshot"))

    def documents(self):
        return [item for item in self("documents").split(" ") if item]

    def kill(self):
        self.proc.kill()
        self.proc.wait(timeout=3)

    def end(self):
        if self.proc.poll() is None:
            try:
                self("end")
            except Exception:
                self.proc.kill()
            self.proc.wait(timeout=3)


def build(root):
    runtime = root / "TTSRuntime.swift"
    original = (SOURCES / "Core/TTSRuntime.swift").read_text()
    path = r'"/private/tmp/\(prefix)-\(uid)"'
    assert original.count(path) == 1
    runtime.write_text(original.replace(path, r'"\(prefix)-\(uid)"'))   # sockets stay inside the fixture
    sdk = subprocess.check_output(["/usr/bin/xcrun", "--sdk", "macosx26.5", "--show-sdk-path"], text=True).strip()
    env = {"PATH": "/usr/bin:/bin", "HOME": str(root), "TMPDIR": str(root), "SDKROOT": sdk,
           "CLANG_MODULE_CACHE_PATH": str(BUILD / "module-cache")}
    helper_src = REPO / "Helpers/AgentCatalogMCP.swift"
    other_src = root / "Other.swift"
    other_src.write_text(helper_src.read_text().replace('version":"2.0"', 'version":"2.0-other"'))
    common = [runtime, SOURCES / "App/AgentPeerSigning.swift", SOURCES / "Core/AgentCatalog.swift"]
    server = [SOURCES / "App/LocalInstructionSocket.swift", SOURCES / "App/AgentSessionController.swift",
              SOURCES / "Core/AgentTrustStore.swift", SOURCES / "Core/AgentDeliveryProofs.swift",
              SOURCES / "Core/ExplanationDraftWorkspace.swift", SOURCES / "Core/AgentInstructionEditing.swift",
              HERE / "LocalExplanationDraftSocketProbe.swift"]
    for name, identifier, files in (("helper", APP_ID + ".agent-helper", [helper_src]), ("server", APP_ID, server),
                                    ("other", APP_ID + ".agent-helper", [other_src])):
        binary = root / name
        subprocess.run(["/usr/bin/swiftc", "-suppress-warnings", "-framework", "Security", *map(str, common + files),
                        "-o", str(binary)], check=True, timeout=300, env=env)
        subprocess.run(["/usr/bin/codesign", "--force", "--options", "runtime", "--timestamp=none", "--sign", IDENTITY,
                        "--identifier", identifier, str(binary)], check=True, timeout=15, stderr=subprocess.DEVNULL)
    shutil.copy2(root / "helper", root / "unsigned")
    # Without any signature the system will not run it at all; ad-hoc is the weakest runnable form.
    subprocess.run(["/usr/bin/codesign", "--force", "--sign", "-", "--identifier", APP_ID + ".agent-helper",
                    str(root / "unsigned")], check=True, timeout=15, stderr=subprocess.DEVNULL)


def main(real_idle):
    BUILD.mkdir(parents=True, exist_ok=True)
    run = uuid.uuid4().hex[:8]
    slot_a, slot_b = f"fixture-{run}-a", f"fixture-{run}-b"
    with tempfile.TemporaryDirectory(prefix="p", dir=BUILD) as temp:
        root = Path(temp)
        build(root)
        ipc = "codebasic-tts-mcp-" + str(os.getuid())
        trust = root / "agent-clients.json"
        server_env = {"PATH": "/usr/bin:/bin", "HOME": str(root), "TMPDIR": str(root)}
        # The helper needs the real login keychain; nothing else of the user's is read.
        client_env = {"PATH": "/usr/bin:/bin", "HOME": os.environ["HOME"]}
        helper = str(root / "helper")
        opened = []

        def client(slot=slot_a, binary=helper, launcher=None):
            session = Session(binary, slot, launcher=launcher, cwd=root, env=client_env)
            opened.append(session)
            return session

        def app(first_launch=False):
            server = Server(root, server_env, ipc, trust)
            assert server("pair") == "ok" and server("configure") == "ok"   # app launch: no click
            return server

        def fresh(server):
            """A new minute and an empty editor, by the user's own hand, so later sends are not rate limited."""
            assert server("disable") == "ok" and server("reset-documents") == "ok" and server("enable") == "ok"

        server = None
        try:
            server = app()
            a = client()
            assert a.status() == "approval_required"
            shot = server.snapshot()
            assert shot["awaiting"] == slot_a and not shot["paired"] and shot["trusted"] == []
            assert a.send("before-approval", "승인 전 대본")["outcome"] == "rejected" and server.documents() == []
            clicks = 0
            assert server("enable") == "ok"; clicks += 1
            assert a.status() == "receiving_only"
            shot = server.snapshot()
            assert shot["persistent"] and shot["trusted"] == [slot_a] and shot["auto"] and shot["hosts"][0]
            assert trust.stat().st_mode & 0o777 == 0o600
            ok(f"first pairing: refused before approval, one click ({clicks}), client key remembered ({shot['hosts'][0].split(':')[0]} launcher)")

            if real_idle:
                idle = int(os.environ.get("TTS_REAL_IDLE_SECONDS", "620"))
                assert idle > 600
                instruction = None
                if real_idle == "linked":
                    assert server("select") == "ok" and a.status() == "ready"
                    instruction = a.read_instruction()
                    first = a.send("idle-before", "유휴 전 연결 대본", profile=instruction["profile"], revision=instruction["revision"])
                else:
                    first = a.send("idle-before", "유휴 전 대본")
                assert first["status"] == "accepted", first
                started = time.monotonic()
                print(f"idling {idle} s of real time with no app or client activity", flush=True)
                time.sleep(idle)
                waited = time.monotonic() - started
                if instruction:
                    # The proof from before the idle has expired; the same shared revision is read again by the helper.
                    after = a.send("idle-after", "유휴 뒤 연결 대본\n둘째 줄", profile=instruction["profile"], revision=instruction["revision"])
                else:
                    after = a.send("idle-after", "유휴 뒤 대본\n둘째 줄")
                assert after["status"] == "accepted", after
                shot = server.snapshot()
                assert shot["tabs"] and len(server.documents()) == 2 and shot["receiving"] and clicks == 1
                if instruction:
                    assert shot["shared"] and shot["associated"] == instruction["profile"]
                    assert server("change") == "ok"
                    stale = a.send("idle-stale", "바뀐 뒤 대본", profile=instruction["profile"], revision=instruction["revision"])
                    assert stale["outcome"] == "rejected" and len(server.documents()) == 2, stale
                ok(f"REAL idle {waited:.0f} s (> 600): same pairing, no new approval, {real_idle} draft received"
                   + ("; old revision refused after change" if instruction else ""))
                return

            texts = [f"합성 대본 {n}\n여러 턴 중 {n}번째" for n in range(3)]
            for n, text in enumerate(texts):
                assert a.send(f"turn-{n}", text)["status"] == "accepted"
            assert server.documents() == [digest(t) for t in texts]
            ok("several turns: three different drafts on one approval, bytes identical")

            a.close()
            time.sleep(0.3)
            shot = server.snapshot()
            assert not shot["paired"] and shot["auto"] and not shot["receiving"]
            a = client()
            assert a.status() == "receiving_only" and server.snapshot()["persistent"]
            assert a.send("after-exit", "정상 종료 뒤 대본")["status"] == "accepted"
            a.close(kill=True)
            time.sleep(0.3)
            a = client()
            assert a.status() == "receiving_only"
            assert a.send("after-kill", "비정상 종료 뒤 대본")["status"] == "accepted"
            ok("client restart: clean exit and SIGKILL both reconnect with no click and receive")

            assert a.send("turn-1", texts[1])["status"] == "duplicate"
            assert a.send("turn-1", "같은 키 다른 본문")["status"] == "conflict"
            assert len(server.documents()) == 5
            ok("delivery key across client restart: same body is a duplicate, different body conflicts, no extra document")

            server.end()
            assert a.status() == "app_unavailable"
            server = app()
            assert a.status() == "receiving_only" and server.snapshot()["persistent"]
            assert a.send("after-app-quit", "앱 재시작 뒤 대본")["status"] == "accepted"
            server.kill()
            server = app()
            assert a.status() == "receiving_only"
            assert a.send("after-app-kill", "앱 비정상 종료 뒤 대본")["status"] == "accepted"
            assert a.send("after-app-quit", "앱 재시작 뒤 대본")["status"] == "accepted"
            ok("app restart: clean quit and SIGKILL both resume the same pairing with no click")
            print("LIMIT duplicate detection does not survive an app restart: the same key and body opened a second document")

            assert server("lock") == "ok"
            assert a.status() == "locked"
            before = server.documents()
            locked = a.send("while-locked", "잠금 중 대본")
            assert locked["outcome"] == "rejected" and locked["status"] == "locked" and server.documents() == before
            assert server("unlock") == "ok"
            assert a.status() == "receiving_only" and a.send("after-unlock", "잠금 해제 뒤 대본")["status"] == "accepted"
            ok("screen lock (controller hook): refused while locked, same pairing re-proved and resumed after unlock")

            fresh(server)
            b = client(slot_b)
            assert a.status() == "receiving_only"
            assert b.status() == "other_agent" and b.send("b-1", "다른 키 대본")["outcome"] == "rejected"
            a.close()
            time.sleep(0.3)
            assert b.status() == "approval_required" and server.snapshot()["awaiting"] == slot_b
            second = b.send("b-2", "다른 키 대본")
            assert second["outcome"] == "rejected" and server.documents() == [], (second, server.documents(), server.snapshot())
            a = client()
            assert a.status() == "receiving_only"
            b.close()
            ok("different key, same user and same signed helper: refused while another is connected and when alone")

            a.close()
            shell = client(launcher=["/bin/sh", "-c", '"$0" "$@"; exit $?'])
            assert shell.status() == "approval_required"
            shell.close()
            a = client()
            assert a.status() == "receiving_only"
            ok("same key from a different launching program needs a new approval")

            other = client(binary=str(root / "other"))
            unsigned = client(binary=str(root / "unsigned"))
            assert other.status() == "app_unavailable" and unsigned.status() in ("signing_required", "app_unavailable")
            assert other.send("x", "다른 해시")["outcome"] == "rejected" and server.documents() == []
            other.close(); unsigned.close()
            ok("different helper hash and ad-hoc signed helper cannot connect even with the approved slot name")

            a.close()
            assert subprocess.run([helper, "--client", slot_a, "--forget-key"], cwd=root, env=client_env, timeout=10).returncode == 0
            a = client()
            assert a.status() == "approval_required"
            assert server("allow-new") == "ok"; clicks += 1
            assert a.status() == "receiving_only" and server.snapshot()["trusted"] == [slot_a]
            ok("lost or replaced client key: blocked until a new approval, which supersedes the old record")

            assert server("forget") == "ok"
            late = a.send("late", "잊은 뒤 늦은 요청")
            assert late["outcome"] == "rejected" and server.documents() == []
            assert a.status() == "approval_required" and server.snapshot()["trusted"] == []
            a.close()
            a = client()
            assert a.status() == "approval_required" and not server.snapshot()["paired"]
            assert server("allow-new") == "ok"; clicks += 1
            assert a.status() == "receiving_only"
            ok("forget: late request and restart are refused; only a new approval with a new key connects again")

            assert server("disconnect") == "ok"
            assert a.status() == "approval_required" and a.send("off", "끊은 뒤 대본")["outcome"] == "rejected"
            a.close()
            a = client()
            assert a.status() == "approval_required" and not server.snapshot()["auto"]
            server.end()
            server = app()
            assert a.status() == "approval_required"
            assert server("enable") == "ok"
            assert a.status() == "receiving_only" and server.snapshot()["trusted"] == [slot_a]
            ok("disconnect: stops now and stays off across client and app restarts; turning it on needs no new pairing")

            assert server("select") == "ok" and a.status() == "ready"
            assert a.send("plain-while-selected", "지시 없이")["status"] == "instruction_required"
            instruction = a.read_instruction()
            linked = a.send("linked-1", "지시 연결 대본", profile=instruction["profile"], revision=instruction["revision"])
            assert linked["status"] == "accepted" and server.snapshot()["associated"] == instruction["profile"]
            a.close()
            time.sleep(0.3)
            assert not server.snapshot()["shared"] and server.snapshot()["scope"] == instruction["profile"]
            a = client()
            assert a.status() == "ready"
            unread = a.send("linked-2", "읽지 않은 프로세스", profile=instruction["profile"], revision=instruction["revision"])
            assert unread["outcome"] == "rejected"
            again = a.read_instruction()
            assert again["revision"] == instruction["revision"]
            assert a.send("linked-2", "다시 읽은 뒤 대본", profile=again["profile"], revision=again["revision"])["status"] == "accepted"
            assert server("change") == "ok"
            assert a.status() == "instruction_required" and a.read_instruction() is None
            stale = a.send("linked-3", "구버전 대본", profile=again["profile"], revision=again["revision"])
            assert stale["outcome"] == "rejected"
            a.close()
            a = client()
            assert a.status() == "instruction_required" and a.read_instruction() is None
            assert server("revoke") == "ok" and a.status() == "receiving_only"
            ok("selected instruction: exact revision resumes for the same client; changed revision is never shared or accepted again")

            fresh(server)
            sent = []
            for label, size in (("1KiB", 1024), ("4KiB", 4096), ("limit-1", TEXT_LIMIT - 1), ("limit", TEXT_LIMIT)):
                text = korean(size)
                assert len(text.encode("utf-8")) == size
                report = a.send("size-" + label, text)
                assert report["status"] == "accepted" and report["display_bytes"] == size and report["frame_bytes"] > size, report
                sent.append(digest(text))
            assert server.documents() == sent
            over = korean(TEXT_LIMIT + 1)
            local = a.send("size-over", over)
            remote = a.send("size-over", over, local_checks=False)
            assert local["outcome"] == "rejected" and local["by"] == "client" and local["status"] == "too_large"
            assert remote["outcome"] == "rejected" and remote["status"] == "too_large" and remote["bytes"] == TEXT_LIMIT + 1
            huge = a.send("size-frame", "가" * 40000, local_checks=False)
            assert huge["outcome"] == "rejected" and huge["status"] == "frame_too_large"
            assert server.documents() == sent and a.status() == "receiving_only"
            ok(f"long drafts over pipes: 1 KiB, 4 KiB, {TEXT_LIMIT - 1} and {TEXT_LIMIT} bytes arrive byte-identical; "
               f"{TEXT_LIMIT + 1} bytes and an oversized frame are refused whole")

            assert server("edit-document") == "ok"
            edited = server.snapshot()
            lost = a.send("lost-reply", "응답이 유실된 대본\n한 번만 열려야 함", discard_reply=True)
            assert lost["outcome"] == "unconfirmed"
            retried = a.retry()
            assert retried["status"] == "duplicate" and retried["request_id"] == lost["request_id"] + 1
            assert len(server.documents()) == len(sent) + 1
            shot = server.snapshot()
            assert shot["dirty"][:len(sent)] == edited["dirty"] and any(shot["dirty"])
            assert a.send("sixth", "여섯 번째")["status"] == "accepted"
            blocked = a.send("overflow", "넘치는 대본")
            assert blocked["status"] == "busy" and len(server.documents()) == 6 and any(server.snapshot()["dirty"])
            ok("lost reply: one retry on the same connection with a new request id is a duplicate; edits kept, a full editor refuses instead of discarding")
            print(f"approvals clicked in total: {clicks} (first pairing, after key loss, after forget)")
        finally:
            for session in opened:
                try:
                    session.close(kill=True)
                except Exception:
                    pass
            if server:
                server.end()
            for slot in (slot_a, slot_b):
                subprocess.run([helper, "--client", slot, "--forget-key"], cwd=root, env=client_env, timeout=10)
    print(f"{len(passed)} scenario groups passed")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--real-idle", choices=["plain", "linked"])
    main(parser.parse_args().real_idle)
