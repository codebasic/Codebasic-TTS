#!/usr/bin/env python3
"""Send drafts to Codebasic TTS through its signed MCP helper, over pipes.

A pseudo-terminal must not sit between an agent and the helper: its line
discipline cuts long lines and swallows bytes, so a long Korean script never
arrives whole and no reply comes back. This client talks to the helper over
plain pipes, one complete UTF-8 JSON-RPC frame per request, and reports every
send as exactly one of:

  confirmed    the app answered this request: accepted, or duplicate
  rejected     the app, the helper or this client refused it; nothing was opened
  unconfirmed  no matching answer arrived; whether it was received is unknown

An unconfirmed send is never repeated automatically. `retry()` repeats it once
on the same connection, with the same key and bytes and a new request id.
Diagnostics hold states and byte counts only, never the draft text.

  tts_mcp_client.py --helper PATH status
  tts_mcp_client.py --helper PATH guide
  tts_mcp_client.py --helper PATH send --key K --display-file F [--speech-file F] [--title T]
"""
import argparse
import json
import os
import select
import subprocess
import sys
import time

TEXT_LIMIT = 8192          # UTF-8 bytes per text field, agreed with the app
FRAME_LIMIT = 100 * 1024   # UTF-8 bytes of one whole request frame, newline included
CONFIRMED = {"accepted", "duplicate"}


class Session:
    """One live helper process. Keep it open across turns; closing it is harmless."""

    def __init__(self, helper, client=None, name="tts-mcp-client", launcher=None, **popen):
        command = list(launcher or []) + [helper] + (["--client", client] if client else [])
        # Binary pipes: no terminal, no echo, no line-length limit, no translation.
        self.proc = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                     stderr=subprocess.DEVNULL, bufsize=0, **popen)
        self.next_id = 0
        self.buffer = b""
        self.limits = {"text_bytes": TEXT_LIMIT, "frame_bytes": FRAME_LIMIT}
        self.last = None
        reply = self._request("initialize", {"protocolVersion": "2025-11-25", "capabilities": {},
                                             "clientInfo": {"name": name, "version": "1"}})[1]
        if reply is None or "result" not in reply:
            raise RuntimeError("helper did not initialize")
        self.server = reply["result"]["serverInfo"]["name"]
        self._write(self._frame({"jsonrpc": "2.0", "method": "notifications/initialized"}))

    @staticmethod
    def _frame(message):
        # json.dumps escapes every newline inside strings; the only raw LF ends the frame.
        return json.dumps(message, ensure_ascii=False, separators=(",", ":")).encode("utf-8") + b"\n"

    def _write(self, frame):
        view = memoryview(frame)
        while view:                       # a short write is continued on this connection only
            view = view[os.write(self.proc.stdin.fileno(), view):]

    def _read(self, request_id, timeout):
        deadline = time.monotonic() + timeout
        while True:
            while b"\n" in self.buffer:
                line, self.buffer = self.buffer.split(b"\n", 1)
                try:
                    message = json.loads(line)
                except ValueError:
                    continue
                if message.get("id") == request_id:
                    return message
            remaining = deadline - time.monotonic()
            if remaining <= 0 or not select.select([self.proc.stdout], [], [], remaining)[0]:
                return None
            chunk = os.read(self.proc.stdout.fileno(), 65536)
            if not chunk:
                return None
            self.buffer += chunk

    def _request(self, method, params, timeout=8.0, discard_reply=False):
        self.next_id += 1
        frame = self._frame({"jsonrpc": "2.0", "id": self.next_id, "method": method, "params": params})
        if len(frame) > self.limits["frame_bytes"]:
            return len(frame), {"local": "frame_too_large"}
        try:
            self._write(frame)
        except OSError:
            return len(frame), None
        reply = self._read(self.next_id, timeout)
        return len(frame), (None if discard_reply else reply)

    def call(self, tool, arguments=None, **options):
        size, reply = self._request("tools/call", {"name": tool, "arguments": arguments or {}}, **options)
        return size, reply

    def status(self):
        reply = self.call("tts_agent_status")[1]
        content = (reply or {}).get("result", {}).get("structuredContent", {})
        self.limits.update(content.get("limits", {}))
        return content.get("status", "unconfirmed")

    def read_instruction(self):
        """Returns the selected saved instruction (profile, revision, instructions) or None."""
        reply = self.call("get_tts_instructions")[1]
        result = (reply or {}).get("result", {})
        return None if result.get("isError", True) else result.get("structuredContent")

    def guide(self):
        """The submission format as the helper describes it: fields, limits, examples, results."""
        reply = self.call("get_tts_submission_guide")[1]
        return (reply or {}).get("result", {}).get("structuredContent")

    def send(self, key, display, speech=None, profile=None, revision=None,
             local_checks=True, discard_reply=False, timeout=8.0, title=None):
        """One draft, one frame. `discard_reply` drops the answer, as a lost reply would.
        `title` names the draft in the app's list only; it is never part of the text."""
        arguments = {"idempotency_key": key, "display_text": display}
        if title is not None:
            arguments["title"] = title
        if speech is not None:
            arguments["speech_text"] = speech
        tool = "submit_tts_draft"
        if profile is not None:
            arguments.update(profile=profile, revision=revision)
            tool = "submit_explanation_draft"
        sizes = {name: len(arguments[name].encode("utf-8")) for name in ("display_text", "speech_text") if name in arguments}
        report = {"key": key, "display_bytes": sizes["display_text"], "speech_bytes": sizes.get("speech_text", 0)}
        self.last = (tool, arguments, report)
        if local_checks:
            for name, size in sizes.items():
                if size > self.limits["text_bytes"]:
                    return {**report, "outcome": "rejected", "status": "too_large", "by": "client",
                            "field": name, "limit_bytes": self.limits["text_bytes"]}
        return self._finish(tool, arguments, dict(report), discard_reply, timeout)

    def retry(self, timeout=8.0):
        """Repeat the last send once: same connection, same key and bytes, new request id."""
        tool, arguments, report = self.last
        return self._finish(tool, arguments, dict(report), False, timeout)

    def _finish(self, tool, arguments, report, discard_reply, timeout):
        size, reply = self.call(tool, arguments, timeout=timeout, discard_reply=discard_reply)
        report.update(frame_bytes=size, request_id=self.next_id)
        if reply is not None and reply.get("local"):
            return {**report, "outcome": "rejected", "status": "frame_too_large", "by": "client",
                    "limit_bytes": self.limits["frame_bytes"]}
        if reply is None or "result" not in reply:
            return {**report, "outcome": "unconfirmed", "status": "unconfirmed"}
        result = reply["result"]
        status = (result.get("structuredContent") or {}).get("status", "invalid" if result.get("isError") else "unconfirmed")
        report["status"] = status
        for extra in ("field", "bytes", "limit_bytes"):
            if extra in (result.get("structuredContent") or {}):
                report[extra] = result["structuredContent"][extra]
        if status in CONFIRMED and not result.get("isError"):
            report["outcome"] = "confirmed"
        elif status == "unconfirmed":
            report["outcome"] = "unconfirmed"
        else:
            report["outcome"] = "rejected"
        return report

    def close(self, kill=False):
        if self.proc.poll() is None:
            if kill:
                self.proc.kill()
            else:
                self.proc.stdin.close()
            try:
                self.proc.wait(timeout=3)
            except subprocess.TimeoutExpired:
                self.proc.kill()
                self.proc.wait(timeout=3)
        for stream in (self.proc.stdin, self.proc.stdout):
            if stream and not stream.closed:
                stream.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--helper", required=True, help="path to the app's bundled CodebasicAgentMCP")
    parser.add_argument("--client", help="name of this client's key slot (default: this program's MCP name)")
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("status")
    commands.add_parser("guide")
    send = commands.add_parser("send")
    send.add_argument("--key", required=True)
    send.add_argument("--display-file", required=True)
    send.add_argument("--speech-file")
    send.add_argument("--title", help="name shown in the app's draft list only")
    options = parser.parse_args()
    session = Session(options.helper, options.client)
    try:
        if options.command == "guide":
            print(json.dumps(session.guide(), ensure_ascii=False, indent=2))
            return 0
        state = session.status()
        if options.command == "status":
            print(json.dumps({"status": state, "limits": session.limits}))
            return 0
        with open(options.display_file, "rb") as handle:
            display = handle.read().decode("utf-8")
        speech = None
        if options.speech_file:
            with open(options.speech_file, "rb") as handle:
                speech = handle.read().decode("utf-8")
        instruction = session.read_instruction() if state == "ready" else None
        report = session.send(options.key, display, speech, title=options.title,
                              profile=instruction and instruction["profile"],
                              revision=instruction and instruction["revision"])
        print(json.dumps({**report, "connection": state}))
        return 0 if report["outcome"] == "confirmed" else 2 if report["outcome"] == "rejected" else 3
    finally:
        session.close()


if __name__ == "__main__":
    sys.exit(main())
