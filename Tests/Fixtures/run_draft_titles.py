#!/usr/bin/env python3
"""Draft titles, the submission guide and the stored draft list, end to end: the real
signed helper, the app's real session controller and its SQLite draft store, synthetic
Korean drafts only. Built and run under build/; client keys use one-off keychain slots
that are deleted at the end. Nothing is synthesized or played and no provider is called.
"""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import uuid

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
from run_persistent_pairing import BUILD, Server, Session, build, digest, ok, passed  # noqa: E402

FAMILY = "👨‍👩‍👧‍👦"


def main():
    BUILD.mkdir(parents=True, exist_ok=True)
    slot = f"fixture-{uuid.uuid4().hex[:8]}-t"
    with tempfile.TemporaryDirectory(prefix="t", dir=BUILD) as temp:
        root = Path(temp)
        build(root)
        ipc = "codebasic-tts-mcp-" + str(os.getuid())
        server_env = {"PATH": "/usr/bin:/bin", "HOME": str(root), "TMPDIR": str(root)}
        client_env = {"PATH": "/usr/bin:/bin", "HOME": os.environ["HOME"]}
        helper = str(root / "helper")

        def app():
            server = Server(root, server_env, ipc, root / "agent-clients.json", database=root / "drafts.sqlite")
            assert server("pair") == "ok" and server("configure") == "ok"
            return server

        def fresh(server):
            assert server("disable") == "ok" and server("enable") == "ok"

        server = a = None
        try:
            # Before any app is running or anything is approved: the format is still readable.
            a = Session(helper, slot, cwd=root, env=client_env)
            listed = {tool["name"]: tool for tool in a._request("tools/list", {})[1]["result"]["tools"]}
            guide = a.guide()
            assert a.status() == "app_unavailable"
            for name in ("submit_tts_draft", "submit_explanation_draft"):
                schema = listed[name]["inputSchema"]
                assert sorted(schema["required"]) == sorted(guide["tools"][name]["required"])
                assert set(schema["properties"]) == set(guide["tools"][name]["required"]) | set(guide["tools"][name]["optional"])
                assert schema["additionalProperties"] is False
                assert all(schema["properties"][field]["description"] == guide["fields"][field] for field in schema["properties"])
                assert set(guide["examples"][name]) <= set(schema["properties"]) and set(schema["required"]) <= set(guide["examples"][name])
            assert "title" in guide["tools"]["submit_tts_draft"]["optional"] and "profile" not in listed["submit_tts_draft"]["inputSchema"]["properties"]
            assert listed["get_tts_submission_guide"]["annotations"]["readOnlyHint"] is True
            blob = json.dumps(guide, ensure_ascii=False)
            assert "합성 지시" not in blob and slot not in blob and {"accepted", "duplicate", "conflict", "unconfirmed", "instruction_required", "unproven"} <= set(guide["results"])
            ok("guide: readable with no app and no approval; fields, required sets and descriptions equal tools/list; examples fit the schema; nothing of the user's in it")

            server = app()
            assert server("enable") == "ok" and a.status() == "receiving_only"
            assert a.guide() == guide and server.snapshot()["tabs"] == [] and a.status() == "receiving_only"

            # The guide's own plain example, sent as written.
            example = guide["examples"]["submit_tts_draft"]
            reply = a.send(example["idempotency_key"], example["display_text"], title=example["title"])
            shot = server.snapshot()
            assert reply["status"] == "accepted" and shot["tabs"] == [example["title"]] and shot["editor"] == example["display_text"]
            assert shot["activeTitle"] == example["title"] and example["title"] not in shot["editor"] + shot["speech"]
            assert json.loads(server("play")) == [[example["display_text"]] * 2] * 2
            ok("plain example from the guide: title is the list name only; editor, caption text and both playback inputs are the body alone")

            body, spoken = "본문은 이 줄부터입니다.\n둘째 줄", "읽을 때는 이 문장입니다."
            assert a.send("t-speech", body, spoken, title="제목과 본문이 다른 글")["status"] == "accepted"
            assert json.loads(server("play")) == [[body, spoken], [body, body]]
            assert server.snapshot()["tabs"][-1] == "제목과 본문이 다른 글"
            ok("title with separate speech text: 'play' reads the speech text, 'read screen text' reads the body, neither contains the title")

            assert a.send("t-speech", body, spoken, title="제목과 본문이 다른 글")["status"] == "duplicate"
            assert a.send("t-speech", body, spoken, title="다른 제목")["status"] == "conflict"
            assert a.send("t-speech", body, spoken)["status"] == "conflict"
            assert a.send("t-speech", body + "!", spoken, title="제목과 본문이 다른 글")["status"] == "conflict"
            assert a.send("t-same-title", "제목만 같은 다른 글", title="제목과 본문이 다른 글")["status"] == "accepted"
            shot = server.snapshot()
            assert shot["tabs"] == [example["title"], "제목과 본문이 다른 글", "제목과 본문이 다른 글"]
            ok("same key: identical title+body+speech is one draft, a changed title or body conflicts and edits nothing; same title under another key stays separate")

            assert a.send("t-none", "\n   \n  제목 없는 글의 첫 줄  \n본문")["status"] == "accepted"
            assert a.send("t-blank", "공백 제목 글", title="   ")["status"] == "accepted"
            assert a.send("t-blank", "공백 제목 글")["status"] == "duplicate"     # blank title is no title
            assert server.snapshot()["tabs"][-2:] == ["제목 없는 글의 첫 줄", "공백 제목 글"]
            fresh(server)
            long_title = "가" * 120
            emoji_title = FAMILY * 20 + " é"
            assert a.send("t-long", "긴 제목 글", title=long_title)["status"] == "accepted"
            assert a.send("t-emoji", "이모지 제목 글", title=emoji_title)["status"] == "accepted"
            assert server.snapshot()["tabs"][-2:] == [long_title, emoji_title]
            count = len(server.snapshot()["tabs"])
            for bad, why in (("가" * 121, "too_large"), (FAMILY * 21, "too_large"), ("두 줄\n제목", "invalid")):
                refused = a.send("t-bad", "잘못된 제목 글", title=bad)
                assert refused["outcome"] == "rejected" and refused["status"] == why, refused
            assert len(server.snapshot()["tabs"]) == count
            ok("no title or blank title falls back to the first non-blank line; 120 Hangul and joined-emoji titles are kept whole; over-limit or multi-line titles are refused, never shortened")

            # Instruction-linked submission, with and without a title, old-style and new.
            assert server("select") == "ok" and a.status() == "ready"
            assert a.send("t-plain-selected", "지시 없이", title="x")["status"] == "instruction_required"
            read = a.read_instruction()
            linked = dict(profile=read["profile"], revision=read["revision"])
            assert a.send("t-linked", "지시 연계 본문", title="연계 제목", **linked)["status"] == "accepted"
            shot = server.snapshot()
            assert shot["tabs"][-1] == "연계 제목" and shot["editor"] == "지시 연계 본문" and shot["associated"] == read["profile"]
            assert a.send("t-linked", "지시 연계 본문", title="연계 제목", **linked)["status"] == "duplicate"
            assert a.send("t-linked", "지시 연계 본문", **linked)["status"] == "conflict"
            assert a.send("t-linked-old", "제목 없는 연계 본문", **linked)["status"] == "accepted"
            assert server.snapshot()["tabs"][-1] == "제목 없는 연계 본문"
            assert server("change") == "ok"
            assert a.send("t-linked-stale", "구버전", title="x", **linked)["outcome"] == "rejected"
            assert server("revoke") == "ok" and a.status() == "receiving_only"
            ok("instruction-linked: title works the same; clients that send no title keep working; a changed revision is still refused")

            # Unknown or misplaced fields are refused by name, not ignored.
            wrong = a.call("submit_tts_draft", {"idempotency_key": "t-wrong", "display_text": "x", "heading": "y"})[1]["result"]
            mixed = a.call("submit_tts_draft", {"idempotency_key": "t-wrong", "display_text": "x", "profile": read["profile"]})[1]["result"]
            assert wrong["isError"] and wrong["structuredContent"]["status"] == "invalid" and mixed["isError"]
            assert a.call("get_tts_submission_guide", {"x": 1})[1].get("error") is not None
            ok("wrong fields: an unknown field and an instruction field on a plain submission are refused")

            # A long list: 110 more arrive in a row while the user keeps editing one in the middle.
            assert server("switch-tab 1") == "ok" and server("edit-document") == "ok"
            edited = server.snapshot()["editor"]
            assert server("browse on") == "ok"
            base = len(server.snapshot()["tabs"])
            sent = []
            for number in range(110):
                if number % 6 == 0:
                    fresh(server)
                text = f"연속 수신 {number}\n본문 {number}"
                assert a.send(f"bulk-{number}", text, title=f"묶음 {number:03d}" if number % 2 else None)["status"] == "accepted"
                sent.append(digest(text))
            shot = server.snapshot()
            assert len(shot["tabs"]) == base + 110 and shot["editor"] == edited and all(shot["unseen"][base:])
            assert shot["tabs"][base] == "연속 수신 0" and shot["tabs"][base + 1] == "묶음 001" and shot["dirty"][1]
            assert server("browse off") == "ok"
            lost = a.send("bulk-lost", "응답 유실 대본", title="유실", discard_reply=True)
            assert lost["outcome"] == "unconfirmed" and a.retry()["status"] == "duplicate"
            assert len(server.snapshot()["tabs"]) == base + 111
            ok(f"{base + 111} drafts: 110 arrive in a row while one is being edited and the list is being searched; the edit and selection stay, "
               "new ones are only listed; a lost reply retried once is a duplicate")

            # Restart: the whole list, order, titles, the edit and its original, and key answers.
            before = server.snapshot()
            server.end()
            server = app()
            after = server.snapshot()
            assert after["tabs"] == before["tabs"] and after["dirty"] == before["dirty"] and after["editor"] == before["editor"]
            assert server("switch-tab 1") == "ok"
            shot = server.snapshot()
            assert shot["editor"] == edited and shot["canRevert"] and shot["original"] == body and shot["activeTitle"] == "제목과 본문이 다른 글"
            documents = server.documents()
            assert documents[base:base + 110] == sent and len(documents) == base + 111
            assert a.status() == "receiving_only"
            assert a.send("t-speech", body, spoken, title="제목과 본문이 다른 글")["status"] == "duplicate"
            assert a.send("t-speech", body, spoken, title="다른 제목")["status"] == "conflict"
            assert len(server.snapshot()["tabs"]) == base + 111
            server.kill()
            server = app()
            assert server.snapshot()["tabs"] == before["tabs"]
            ok("restart (clean and SIGKILL): every draft is back in order with its title, edits and original; stored keys still answer duplicate/conflict")
        finally:
            if a:
                a.close(kill=True)
            if server:
                server.end()
            subprocess.run([helper, "--client", slot, "--forget-key"], cwd=root, env=client_env, timeout=10)
    print(f"{len(passed)} scenario groups passed")


if __name__ == "__main__":
    main()
