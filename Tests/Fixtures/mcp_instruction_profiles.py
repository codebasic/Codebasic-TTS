#!/usr/bin/env python3
"""Synthetic app-owned MCP profile fixture. Not an installed app or usable sharing server.

No filesystem settings, speech bridge, subprocesses, model calls, or network.
The standalone stdio mode is deliberately unable to grant access. Tests model an
app owner publishing a reviewed revision through direct fixtures only.
"""
import hashlib
import hmac
import os
from pathlib import Path
import secrets
import sys
import time

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "scripts"))
from mcp_speech import MAX_FRAME, Session as SpeechSession, decode, encode, error

PROFILE_NAMES = ("explain", "continue", "normalize")
MAX_BYTES = 16 * 1024
MAX_SESSION_SECONDS = 60 * 60
TOOL = {
    "name": "get_tts_instructions",
    "description": "Read one app-approved TTS instruction profile; never generate speech or call a model.",
    "inputSchema": {"type": "object", "required": ["profile"], "additionalProperties": False,
                    "properties": {"profile": {"type": "string", "enum": list(PROFILE_NAMES)}}},
    "annotations": {"readOnlyHint": True, "destructiveHint": False, "idempotentHint": True,
                    "openWorldHint": False},
}


class SyntheticPublisher:
    """In-memory stand-in for the UI's explicit owner-approval boundary."""

    def __init__(self, owner_uid, clock=time.monotonic):
        self.owner_uid = owner_uid
        self.clock = clock
        self.drafts = {}
        self.sessions = {}

    def stage(self, profile, instructions):
        if not isinstance(profile, str) or profile not in PROFILE_NAMES or not isinstance(instructions, str):
            raise ValueError("invalid synthetic profile")
        raw = instructions.encode("utf-8")
        if not instructions.strip() or b"\0" in raw or len(raw) > MAX_BYTES:
            raise ValueError("invalid synthetic profile size")
        revision = hashlib.sha256(b"tts-profile-v1\0" + profile.encode("ascii") + b"\0" + raw).hexdigest()
        if self.drafts.get(profile, (None,))[0] != revision:
            # Changed content is not implicitly approved, even if an edit is reverted.
            self.sessions = {token: item for token, item in self.sessions.items() if item[0] != profile}
        self.drafts[profile] = (revision, instructions)
        return revision

    def approve(self, profile, previewed_revision, peer_uid, ttl_seconds=600):
        draft = self.drafts.get(profile)
        if (peer_uid != self.owner_uid or draft is None or draft[0] != previewed_revision
                or not 0 < ttl_seconds <= MAX_SESSION_SECONDS):
            raise ValueError("no matching owner-approved synthetic revision")
        token = secrets.token_hex(32)
        self.sessions[token] = (profile, previewed_revision, self.clock() + ttl_seconds)
        return token  # out of band; never returned to MCP

    def revoke(self, token):
        self.sessions.pop(token, None)

    def read(self, profile, peer_uid, capability):
        if (peer_uid != self.owner_uid or not isinstance(capability, str)
                or len(capability) != 64 or not capability.isascii()):
            return None
        for token, (allowed_profile, approved_revision, deadline) in self.sessions.items():
            if not hmac.compare_digest(token, capability):
                continue
            if self.clock() >= deadline or profile != allowed_profile:
                return None
            revision, body = self.drafts[profile]
            if revision == approved_revision:
                return {"schema_version": 1, "profile": profile, "revision": revision, "instructions": body}
        return None


class FixtureSession(SpeechSession):
    """Exercise the production JSON-RPC lifecycle without any speech backend."""

    def __init__(self, publisher, peer_uid, capability=None):
        # Non-tool methods use the current adapter's frame validation and handshake.
        super().__init__(None)
        self.publisher = publisher
        self.peer_uid = peer_uid
        self.capability = capability

    def handle(self, frame):
        try:
            req = decode(frame)
        except (ValueError, RecursionError):
            return super().handle(frame)
        if not isinstance(req, dict) or req.get("method") not in ("tools/list", "tools/call"):
            response = super().handle(frame)
            if isinstance(response, dict) and "serverInfo" in response.get("result", {}):
                response["result"]["serverInfo"]["name"] = "codebasic-tts-synthetic-profile-fixture"
            return response
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
            args = params.get("arguments")
            if ("task" in params or not isinstance(args, dict) or set(args) != {"profile"}
                    or not isinstance(args["profile"], str) or args["profile"] not in PROFILE_NAMES):
                return error(request_id, -32602, "Invalid profile arguments")
            value = self.publisher.read(args["profile"], self.peer_uid, self.capability)
            if value is None:
                result = {"content": [{"type": "text", "text": "Profile sharing is disabled or not approved."}],
                          "isError": True}
            else:
                result = {"content": [{"type": "text", "text": value["instructions"]}],
                          "structuredContent": value, "isError": False}
        return {"jsonrpc": "2.0", "id": request_id, "result": result}


def run_default(stdin, stdout):
    publisher = SyntheticPublisher(os.getuid())
    publisher.stage("explain", "SYNTHETIC ONLY: 값을 보이는 그대로 설명합니다.")
    session = FixtureSession(publisher, publisher.owner_uid)
    while frame := stdin.readline(MAX_FRAME + 1):
        if len(frame) > MAX_FRAME or not frame.endswith(b"\n"):
            while frame and not frame.endswith(b"\n"):
                frame = stdin.readline(MAX_FRAME + 1)
            response = error(None, -32700, "Frame too long or not newline terminated")
        else:
            response = session.handle(frame)
        if response is not None:
            stdout.write(encode(response)); stdout.flush()


if __name__ == "__main__":
    run_default(sys.stdin.buffer, sys.stdout.buffer)
