#!/usr/bin/env python3
"""Separate stdio MCP adapter for submitting external-agent explain drafts (`e.sock`).
Submits drafts silently to the Explain inbox; never plays audio or reads instructions."""

import errno
import os
from pathlib import Path
import re
import socket
import stat
import sys
import time

# Resolve repo-local helpers even when launched with Python -I.
sys.path.insert(0, str(Path(__file__).resolve().parent))
from mcp_speech import (
    IPC_TIMEOUT,
    KEY,
    Session,
    check_node,
    decode,
    encode,
    error,
    same_uid,
    set_remaining,
)
from tts_mcp_app_identity import verified_app_peer

MAX_TEXT_BYTES = 16 * 1024
MAX_FRAME = 64 * 1024
MAX_IPC_FRAME = 48 * 1024
MAX_REPLY = 256
MODES = ("explain", "continue")
REVISION = re.compile(r"[0-9a-f]{64}")
ALLOWED_KEYS = frozenset({
    "display_text",
    "spoken_text",
    "idempotency_key",
    "mode",
    "instruction_revision",
})
TOOL = {
    "name": "submit_explain_draft",
    "description": (
        "Submit an explain draft to the Codebasic TTS Explain inbox without starting playback "
        "or overwriting the user's active editor. Success acknowledges inbox receipt only."
    ),
    "inputSchema": {
        "type": "object",
        "properties": {
            "display_text": {
                "type": "string",
                "minLength": 1,
                "maxLength": MAX_TEXT_BYTES,
                "description": "Screen/subtitle explanation text, at most 16384 UTF-8 bytes.",
            },
            "spoken_text": {
                "type": "string",
                "minLength": 1,
                "maxLength": MAX_TEXT_BYTES,
                "description": "Optional TTS spoken script if pronunciation differs from display_text. Omit when identical.",
            },
            "mode": {
                "type": "string",
                "enum": list(MODES),
                "description": "Instruction mode used: 'explain' (full) or 'continue' (delta).",
            },
            "idempotency_key": {
                "type": "string",
                "pattern": "^[A-Za-z0-9._-]{1,128}$",
                "description": "A fresh key per draft submission; reuse the exact key on retry.",
            },
            "instruction_revision": {
                "type": "string",
                "pattern": "^[0-9a-f]{64}$",
                "description": "Optional SHA-256 revision from get_tts_instructions.",
            },
        },
        "required": ["display_text", "idempotency_key"],
        "additionalProperties": False,
    },
    "annotations": {
        "readOnlyHint": False,
        "destructiveHint": False,
        "idempotentHint": True,
        "openWorldHint": False,
    },
}
STATUSES = {
    "accepted": "Accepted into the Explain inbox. No playback or editor overwrite occurred.",
    "duplicate": "This draft was already received. No duplicate entry was created.",
    "invalid": "Invalid draft arguments. Supply nonblank text within limits and a valid idempotency key.",
    "conflict": "That idempotency key was already used for a different draft payload.",
    "disabled": "Local MCP explain draft reception is disabled. No draft was accepted.",
    "offline": "Local MCP explain draft reception is unavailable. The app may be closed or reception disabled.",
    "unsafe": "Local MCP connection or pinned app identity could not be verified. No draft was sent.",
    "unconfirmed": "Could not confirm inbox receipt. If retrying, reuse the same idempotency key.",
}
VALID_IPC_STATUSES = ("accepted", "duplicate", "invalid", "conflict", "disabled", "unconfirmed")


def socket_path():
    return Path("/private/tmp") / ("codebasic-tts-mcp-%d" % os.geteuid()) / "e.sock"


def valid_text(value):
    if not isinstance(value, str):
        return False
    try:
        return bool(value.strip()) and "\x00" not in value and len(value.encode("utf-8")) <= MAX_TEXT_BYTES
    except UnicodeError:
        return False


def valid_arguments(args):
    if not isinstance(args, dict):
        return False
    keys = set(args)
    if not ({"display_text", "idempotency_key"} <= keys <= ALLOWED_KEYS):
        return False
    if not valid_text(args["display_text"]):
        return False
    key = args["idempotency_key"]
    if not isinstance(key, str) or not KEY.fullmatch(key):
        return False
    if "spoken_text" in args and not valid_text(args["spoken_text"]):
        return False
    if "mode" in args:
        mode = args["mode"]
        if not isinstance(mode, str) or mode not in MODES:
            return False
    if "instruction_revision" in args:
        rev = args["instruction_revision"]
        if not isinstance(rev, str) or not REVISION.fullmatch(rev):
            return False
    return True


def exchange(connection, frame, deadline):
    set_remaining(connection, deadline)
    connection.sendall(frame)
    connection.shutdown(socket.SHUT_WR)
    reply = bytearray()
    while len(reply) < MAX_REPLY:
        set_remaining(connection, deadline)
        chunk = connection.recv(MAX_REPLY - len(reply))
        if not chunk:
            break
        reply.extend(chunk)
        if b"\n" in reply:
            if reply.count(b"\n") != 1 or not reply.endswith(b"\n"):
                break
            result = decode(reply)
            if isinstance(result, dict) and set(result) == {"status"}:
                status = result["status"]
                if status in VALID_IPC_STATUSES:
                    return status
            break
    return "unconfirmed"


def send_local(arguments, path=None, verify_peer=verified_app_peer):
    path = socket_path() if path is None else path
    deadline = time.monotonic() + IPC_TIMEOUT
    attempted_send = False
    try:
        if not check_node(path.parent, stat.S_IFDIR, 0o700) or not check_node(path, stat.S_IFSOCK, 0o600):
            return "unsafe"
        frame = encode(arguments)
        if len(frame) > MAX_IPC_FRAME:
            return "invalid"
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
            set_remaining(connection, deadline)
            connection.connect(str(path))
            if not same_uid(connection) or not verify_peer(connection):
                return "unsafe"
            attempted_send = True
            return exchange(connection, frame, deadline)
    except OSError as exc:
        if not attempted_send and exc.errno in (errno.ENOENT, errno.ECONNREFUSED):
            return "offline"
    except (ValueError, RecursionError):
        pass
    return "unconfirmed"


def tool_result(status):
    return {
        "content": [{"type": "text", "text": f"{status}: {STATUSES[status]}"}],
        "isError": status not in ("accepted", "duplicate"),
    }


class ExplainDraftSession(Session):
    def __init__(self, backend=send_local):
        super().__init__(backend)

    def handle(self, frame):
        try:
            req = decode(frame)
        except (ValueError, RecursionError):
            return super().handle(frame)
        if not isinstance(req, dict) or req.get("method") not in ("tools/list", "tools/call"):
            result = super().handle(frame)
            if isinstance(result, dict) and "serverInfo" in result.get("result", {}):
                result["result"]["serverInfo"]["name"] = "codebasic-tts-explain-draft"
            return result
        if req.get("jsonrpc") != "2.0":
            return error(None, -32600, "Invalid request")
        if "id" not in req:
            return None
        request_id = req["id"]
        if type(request_id) is str:
            try:
                if len(request_id.encode("utf-8")) > 256:
                    return error(None, -32600, "Invalid request ID")
            except UnicodeError:
                return error(None, -32600, "Invalid request ID")
        elif type(request_id) is not int:
            return error(None, -32600, "Invalid request ID")
        params = req.get("params", {})
        if not isinstance(params, dict):
            return error(request_id, -32602, "Invalid params")
        if not self.ready:
            return error(request_id, -32002, "Server not initialized")
        if req["method"] == "tools/list":
            if "cursor" in params:
                return error(request_id, -32602, "Invalid cursor")
            result = {"tools": [TOOL]}
        else:
            if params.get("name") != TOOL["name"]:
                return error(request_id, -32602, "Unknown tool")
            if "task" in params:
                return error(request_id, -32602, "Task execution is not supported")
            args = params.get("arguments")
            result = tool_result(self.backend(args) if valid_arguments(args) else "invalid")
        return {"jsonrpc": "2.0", "id": request_id, "result": result}


def run(stdin, stdout, backend=send_local):
    session = ExplainDraftSession(backend)
    while frame := stdin.readline(MAX_FRAME + 1):
        if len(frame) > MAX_FRAME or not frame.endswith(b"\n"):
            oversized = not frame.endswith(b"\n")
            while oversized:
                tail = stdin.readline(MAX_FRAME + 1)
                oversized = bool(tail) and not tail.endswith(b"\n")
            response = error(None, -32700, "Frame too long or not newline terminated")
        else:
            response = session.handle(frame)
        if response is not None:
            stdout.write(encode(response))
            stdout.flush()


if __name__ == "__main__":
    try:
        run(sys.stdin.buffer, sys.stdout.buffer)
    except BrokenPipeError:
        os._exit(0)
