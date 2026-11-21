#!/usr/bin/env python3
"""Local stdio MCP adapter that hands an agent-written script to the app's inbox.

Separate from speak_text: a submission is stored for the user to review. It never
starts playback, and this adapter has no speech tool. No app launch, no network.
"""
import errno
import os
from pathlib import Path
import socket
import stat
import sys
import time

# The same repo-local modules are needed even when the host uses Python -I.
sys.path.insert(0, str(Path(__file__).resolve().parent))
from mcp_speech import KEY, Session, check_node, decode, encode, error, same_uid, set_remaining
from tts_mcp_app_identity import verified_app_peer

MAX_TEXT_BYTES = 12 * 1024
MAX_IPC_FRAME = 40 * 1024
MAX_FRAME = 48 * 1024  # stdio: two 12 KiB texts plus JSON escapes and the envelope
MAX_REPLY = 128
IPC_TIMEOUT = 2.0
TOOL = {
    "name": "submit_script",
    "description": (
        "Deliver a finished explanation script to the app's inbox for the user to review. "
        "Nothing is played: the user loads it into the editor and presses play themselves. "
        "Success acknowledges storage only. Retry with the same idempotency_key and the same texts."
    ),
    "inputSchema": {
        "type": "object",
        "properties": {
            "display_text": {"type": "string", "minLength": 1,
                             "description": "On-screen wording (e.g. as_frame, 0.5). At most 12288 UTF-8 bytes."},
            "speech_text": {"type": "string", "minLength": 1,
                            "description": "Optional read-aloud wording of the same content "
                                           "(e.g. 애즈 프레임). At most 12288 UTF-8 bytes."},
            "idempotency_key": {"type": "string", "pattern": "^[A-Za-z0-9._-]{1,128}$",
                                "description": "A fresh key per submission; reuse it on retry."},
        },
        "required": ["display_text", "idempotency_key"],
        "additionalProperties": False,
    },
    "annotations": {"readOnlyHint": False, "destructiveHint": False, "idempotentHint": True,
                    "openWorldHint": False},
}
STATUSES = {
    "received": "Stored in the app's inbox. Not played; the user reviews and plays it.",
    "duplicate": "This submission was already stored. Nothing was added.",
    "conflict": "That idempotency key was already used for different texts. Nothing was added.",
    "full": "The inbox is full. Nothing was added; retry later with the same key.",
    "invalid": "Invalid arguments. Supply nonblank display_text, optional nonblank speech_text and a valid key.",
    "disabled": "Script delivery is turned off in the app. Nothing was added.",
    "offline": "Script delivery is unavailable. The app may be closed or delivery turned off.",
    "unsafe": "Local connection or pinned app identity could not be verified. No text was sent.",
    "unconfirmed": "Could not confirm storage. If retrying, reuse the same idempotency key and texts.",
}
APP_STATUSES = ("received", "duplicate", "conflict", "full", "invalid", "disabled", "unconfirmed")


def socket_path():
    return Path("/private/tmp") / ("codebasic-tts-mcp-%d" % os.geteuid()) / "r.sock"


def valid_text(value):
    if not isinstance(value, str):
        return False
    try:
        return bool(value.strip()) and "\x00" not in value and len(value.encode("utf-8")) <= MAX_TEXT_BYTES
    except UnicodeError:
        return False


def valid_arguments(args):
    if not isinstance(args, dict) or not {"display_text", "idempotency_key"} <= set(args) \
            or not set(args) <= {"display_text", "speech_text", "idempotency_key"}:
        return False
    key = args["idempotency_key"]
    if not isinstance(key, str) or not KEY.fullmatch(key):
        return False
    return valid_text(args["display_text"]) and ("speech_text" not in args or valid_text(args["speech_text"]))


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
            if reply.count(b"\n") == 1 and reply.endswith(b"\n"):
                result = decode(reply)
                if isinstance(result, dict) and set(result) == {"status"} and result["status"] in APP_STATUSES:
                    return result["status"]
            break
    return "unconfirmed"


def submit_local(arguments, path=None, verify_peer=verified_app_peer):
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


class InboxSession(Session):
    """Reuses the handshake of the speech adapter; exposes only submit_script."""

    def __init__(self, backend=submit_local):
        super().__init__(backend)

    def handle(self, frame):
        try:
            request = decode(frame)
        except (ValueError, RecursionError):
            return super().handle(frame)
        if not isinstance(request, dict) or request.get("method") not in ("tools/list", "tools/call"):
            result = super().handle(frame)
            if isinstance(result, dict) and "serverInfo" in result.get("result", {}):
                result["result"]["serverInfo"]["name"] = "codebasic-tts-script-inbox"
            return result
        if request.get("jsonrpc") != "2.0":
            return error(None, -32600, "Invalid request")
        if "id" not in request:
            return None
        request_id = request["id"]
        if type(request_id) is str:
            try:
                if len(request_id.encode("utf-8")) > 256:
                    return error(None, -32600, "Invalid request ID")
            except UnicodeError:
                return error(None, -32600, "Invalid request ID")
        elif type(request_id) is not int:
            return error(None, -32600, "Invalid request ID")
        params = request.get("params", {})
        if not isinstance(params, dict):
            return error(request_id, -32602, "Invalid params")
        if not self.ready:
            return error(request_id, -32002, "Server not initialized")
        if request["method"] == "tools/list":
            if "cursor" in params:
                return error(request_id, -32602, "Invalid cursor")
            result = {"tools": [TOOL]}
        else:
            if params.get("name") != TOOL["name"]:
                return error(request_id, -32602, "Unknown tool")
            if "task" in params:
                return error(request_id, -32602, "Task execution is not supported")
            args = params.get("arguments")
            status = self.backend(args) if valid_arguments(args) else "invalid"
            result = {"content": [{"type": "text", "text": f"{status}: {STATUSES[status]}"}],
                      "isError": status not in ("received", "duplicate")}
        return {"jsonrpc": "2.0", "id": request_id, "result": result}


def run(stdin, stdout, session=None):
    session = session if session is not None else InboxSession()
    while frame := stdin.readline(MAX_FRAME + 1):
        if len(frame) > MAX_FRAME or not frame.endswith(b"\n"):
            while frame and not frame.endswith(b"\n"):
                frame = stdin.readline(MAX_FRAME + 1)
            result = error(None, -32700, "Frame too long or not newline terminated")
        else:
            result = session.handle(frame)
        if result is not None:
            stdout.write(encode(result))
            stdout.flush()


if __name__ == "__main__":
    try:
        run(sys.stdin.buffer, sys.stdout.buffer)
    except BrokenPipeError:
        os._exit(0)
