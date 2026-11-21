#!/usr/bin/env python3
"""A separate read-only Mac stdio MCP adapter for one explicitly approved instruction profile."""
import hashlib
import os
from pathlib import Path
import socket
import stat
import sys
import time

# The same repo-local module is needed even when the host uses Python -I.
sys.path.insert(0, str(Path(__file__).resolve().parent))
from mcp_speech import MAX_FRAME, Session, check_node, decode, encode, error, same_uid, set_remaining
from tts_mcp_app_identity import verified_app_peer

PROFILES = ("explain", "continue", "normalize")
TOOL = {"name": "get_tts_instructions",
        "description": "Read one app-approved TTS instruction profile. No model call or speech playback.",
        "inputSchema": {"type": "object", "required": ["profile"], "additionalProperties": False,
                        "properties": {"profile": {"type": "string", "enum": list(PROFILES)}}},
        "annotations": {"readOnlyHint": True, "destructiveHint": False, "idempotentHint": True,
                        "openWorldHint": False}}
MAX_REPLY = 52 * 1024


def socket_path():
    return Path("/private/tmp") / ("codebasic-tts-mcp-%d" % os.geteuid()) / "i.sock"


def get_profile(profile):
    """Read only the approved profile; no file is used to obtain instructions."""
    if profile not in PROFILES:
        return None
    path = socket_path()
    deadline = time.monotonic() + 1.5
    try:
        if not check_node(path.parent, stat.S_IFDIR, 0o700) or not check_node(path, stat.S_IFSOCK, 0o600):
            return None
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as peer:
            set_remaining(peer, deadline)
            peer.connect(str(path))
            if not same_uid(peer) or not verified_app_peer(peer):
                return None
            set_remaining(peer, deadline)
            peer.sendall(encode({"profile": profile}))
            peer.shutdown(socket.SHUT_WR)
            buffer = bytearray()
            while len(buffer) < MAX_REPLY:
                set_remaining(peer, deadline)
                fragment = peer.recv(MAX_REPLY - len(buffer))
                if not fragment:
                    return None
                buffer.extend(fragment)
                if b"\n" in buffer:
                    if buffer.count(b"\n") != 1 or not buffer.endswith(b"\n"):
                        return None
                    payload = decode(buffer)
                    if not isinstance(payload, dict) or set(payload) != {"schema_version", "profile", "revision", "instructions"}:
                        return None
                    if type(payload["schema_version"]) is not int or payload["schema_version"] != 1 or payload["profile"] != profile:
                        return None
                    instructions = payload["instructions"]
                    if not isinstance(instructions, str) or not instructions.strip() or "\0" in instructions:
                        return None
                    raw = instructions.encode("utf-8")
                    if len(raw) > 8 * 1024:
                        return None
                    actual = hashlib.sha256(b"tts-profile-v1\0" + profile.encode("ascii") + b"\0" + raw).hexdigest()
                    return payload if payload["revision"] == actual else None
    except (OSError, ValueError, RecursionError):
        pass
    return None


class InstructionSession(Session):
    def __init__(self, backend=get_profile):
        super().__init__(backend)

    def handle(self, frame):
        try:
            request = decode(frame)
        except (ValueError, RecursionError):
            return super().handle(frame)
        if not isinstance(request, dict) or request.get("method") not in ("tools/list", "tools/call"):
            result = super().handle(frame)
            if isinstance(result, dict) and "serverInfo" in result.get("result", {}):
                result["result"]["serverInfo"]["name"] = "codebasic-tts-instructions"
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
            args = params.get("arguments")
            if ("task" in params or not isinstance(args, dict) or set(args) != {"profile"}
                    or not isinstance(args["profile"], str) or args["profile"] not in PROFILES):
                return error(request_id, -32602, "Invalid profile arguments")
            value = self.backend(args["profile"])
            if value is None:
                reason = f"No approved instruction profile from a verified app is available to helper PID {os.getpid()}."
                result = {"content": [{"type": "text", "text": reason}], "isError": True}
            else:
                result = {"content": [{"type": "text", "text": value["instructions"]}],
                          "structuredContent": value, "isError": False}
        return {"jsonrpc": "2.0", "id": request_id, "result": result}


def run(stdin, stdout, session=None):
    session = session if session is not None else InstructionSession()
    while frame := stdin.readline(MAX_FRAME + 1):
        if len(frame) > MAX_FRAME or not frame.endswith(b"\n"):
            while frame and not frame.endswith(b"\n"):
                frame = stdin.readline(MAX_FRAME + 1)
            result = error(None, -32700, "Frame too long or not newline terminated")
        else:
            result = session.handle(frame)
        if result is not None:
            stdout.write(encode(result)); stdout.flush()


if __name__ == "__main__":
    try:
        run(sys.stdin.buffer, sys.stdout.buffer)
    except BrokenPipeError:
        os._exit(0)
