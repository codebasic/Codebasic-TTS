#!/usr/bin/env python3
"""Local SelectedTextTTS MCP stdio adapter. No app launch or network transport."""

import ctypes
import errno
import json
import os
from pathlib import Path
import re
import socket
import stat
import sys
import time

# Resolve the repo-local verifier also when a host launches Python with -I.
sys.path.insert(0, str(Path(__file__).resolve().parent))
from tts_mcp_app_identity import verified_app_peer

PROTOCOL = "2025-11-25"
MAX_TEXT_BYTES = 4096
MAX_FRAME = 32 * 1024
MAX_IPC_FRAME = 25 * 1024
MAX_REPLY = 128
KEY = re.compile(r"[A-Za-z0-9._-]{1,128}")
IPC_TIMEOUT = 2.0
TOOL = {
    "name": "speak_text",
    "description": (
        "Read final plain text aloud with the app's currently configured voice. "
        "Only call when the user has requested speech. Success acknowledges acceptance, "
        "not playback or completion."
    ),
    "inputSchema": {
        "type": "object",
        "properties": {
            "text": {"type": "string", "minLength": 1, "maxLength": MAX_TEXT_BYTES,
                     "description": "Final literal text, at most 4096 UTF-8 bytes."},
            "idempotency_key": {"type": "string", "pattern": "^[A-Za-z0-9._-]{1,128}$",
                                "description": "A fresh key per speech request; reuse it on retry."},
        },
        "required": ["text", "idempotency_key"],
        "additionalProperties": False,
    },
}
STATUSES = {
    "accepted": "Accepted by the app. Playback and completion are not confirmed.",
    "duplicate": "This request was already accepted. No new playback was requested.",
    "busy": "The app is busy. No speech was accepted.",
    "invalid": "Invalid speech arguments. Supply nonblank literal text and a valid idempotency key.",
    "conflict": "That idempotency key was already used for different text.",
    "disabled": "Local MCP speech input is disabled. No speech was accepted.",
    "offline": "Local MCP speech input is unavailable. The app may be closed or input disabled.",
    "unsafe": "Local MCP connection or pinned app identity could not be verified. No text was sent.",
    "unconfirmed": "Could not confirm acceptance. If retrying, reuse the same idempotency key.",
}


def socket_path():
    return Path("/private/tmp") / ("codebasic-tts-mcp-%d" % os.geteuid()) / "s.sock"


def same_uid(connection):
    # Darwin exposes getpeereid(3), but Python's socket API does not consistently expose it.
    if sys.platform != "darwin":
        return False
    getpeereid = ctypes.CDLL("/usr/lib/libSystem.B.dylib").getpeereid
    getpeereid.argtypes = (ctypes.c_int, ctypes.POINTER(ctypes.c_uint), ctypes.POINTER(ctypes.c_uint))
    getpeereid.restype = ctypes.c_int
    uid, gid = ctypes.c_uint(), ctypes.c_uint()
    return getpeereid(connection.fileno(), ctypes.byref(uid), ctypes.byref(gid)) == 0 and uid.value == os.geteuid()


def check_node(path, kind, permissions):
    node = path.lstat()  # No final-component symlinks.
    return (stat.S_IFMT(node.st_mode) == kind and stat.S_IMODE(node.st_mode) == permissions
            and node.st_uid == os.geteuid())


def encode(message):
    return json.dumps(message, ensure_ascii=False, separators=(",", ":")).encode("utf-8") + b"\n"


def distinct_object(items):
    result = dict(items)
    if len(items) != len(result):
        raise ValueError("duplicate property")
    return result


def invalid_constant(_):
    raise ValueError("non-JSON constant")


def decode(frame):
    return json.loads(frame.decode("utf-8"), object_pairs_hook=distinct_object,
                      parse_constant=invalid_constant)


def set_remaining(connection, deadline):
    seconds = deadline - time.monotonic()
    if seconds <= 0:
        raise TimeoutError
    connection.settimeout(seconds)


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
                if status in ("accepted", "duplicate", "busy", "invalid", "conflict",
                              "disabled", "unconfirmed"):
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


def error(request_id, code, message):
    return {"jsonrpc": "2.0", "id": request_id, "error": {"code": code, "message": message}}


def tool_result(status):
    return {
        "content": [{"type": "text", "text": f"{status}: {STATUSES[status]}"}],
        "isError": status not in ("accepted", "duplicate"),
    }


def valid_arguments(args):
    if not isinstance(args, dict) or set(args) != {"text", "idempotency_key"}:
        return False
    text, key = args["text"], args["idempotency_key"]
    if not isinstance(text, str) or not isinstance(key, str) or not KEY.fullmatch(key):
        return False
    try:
        return bool(text.strip()) and "\x00" not in text and len(text.encode("utf-8")) <= MAX_TEXT_BYTES
    except UnicodeError:
        return False


class Session:
    def __init__(self, backend):
        self.backend = backend
        self.initialized = False
        self.ready = False

    def handle(self, frame):
        try:
            req = decode(frame)
        except (ValueError, RecursionError):
            return error(None, -32700, "Parse error")
        if not isinstance(req, dict) or req.get("jsonrpc") != "2.0" or not isinstance(req.get("method"), str):
            return error(None, -32600, "Invalid request")
        method, params = req["method"], req.get("params", {})
        if "id" not in req:
            if method == "notifications/initialized" and self.initialized and isinstance(params, dict):
                self.ready = True
            return None
        request_id = req["id"]
        if type(request_id) not in (str, int):
            return error(None, -32600, "Invalid request ID")
        if isinstance(request_id, str):
            try:
                if len(request_id.encode("utf-8")) > 256:
                    return error(None, -32600, "Invalid request ID")
            except UnicodeError:
                return error(None, -32600, "Invalid request ID")
        if not isinstance(params, dict):
            return error(request_id, -32602, "Invalid params")
        if method == "initialize":
            client = params.get("clientInfo")
            if self.initialized or not isinstance(params.get("protocolVersion"), str) or not isinstance(
                params.get("capabilities"), dict
            ) or not isinstance(client, dict) or not isinstance(client.get("name"), str) or not isinstance(
                client.get("version"), str
            ):
                return error(request_id, -32602, "Invalid initialization")
            self.initialized = True
            result = {"protocolVersion": PROTOCOL, "capabilities": {"tools": {"listChanged": False}},
                      "serverInfo": {"name": "codebasic-tts", "version": "0.1.0"}}
        elif method == "ping":
            result = {}
        elif not self.ready:
            return error(request_id, -32002, "Server not initialized")
        elif method == "tools/list":
            if "cursor" in params:
                return error(request_id, -32602, "Invalid cursor")
            result = {"tools": [TOOL]}
        elif method == "tools/call":
            if params.get("name") != TOOL["name"]:
                return error(request_id, -32602, "Unknown tool")
            if "task" in params:
                return error(request_id, -32602, "Task execution is not supported")
            args = params.get("arguments")
            result = tool_result(self.backend(args) if valid_arguments(args) else "invalid")
        else:
            return error(request_id, -32601, "Method not found")
        return {"jsonrpc": "2.0", "id": request_id, "result": result}


def run(stdin, stdout, backend=send_local):
    session = Session(backend)
    while frame := stdin.readline(MAX_FRAME + 1):
        if len(frame) > MAX_FRAME or not frame.endswith(b"\n"):
            oversized = not frame.endswith(b"\n")
            # Discard remaining fragments in bounded chunks, never interpreting them as requests.
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
