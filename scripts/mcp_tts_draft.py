#!/usr/bin/env python3
"""Local receive-only MCP. Accepting a draft never sends it to a provider."""
import os
from pathlib import Path
import sys

# Import these repo-local shared protocol functions also in Python -I.
sys.path.insert(0, str(Path(__file__).resolve().parent))
from mcp_speech import KEY, Session, run

MAX_TEXT_BYTES = 8 * 1024
MAX_FRAME = 100 * 1024
TOOL = {
    "name": "submit_explanation_draft",
    "description": (
        "Put an editable plain-text explanation draft in the local TTS app's inbox. "
        "Requires separate app approval. Does not replace editor text, synthesize or play."
    ),
    "inputSchema": {
        "type": "object",
        "properties": {
            "display_text": {"type": "string", "minLength": 1, "maxLength": MAX_TEXT_BYTES,
                             "description": "Screen/subtitle text, at most 8192 UTF-8 bytes."},
            "speech_text": {"type": "string", "minLength": 1, "maxLength": MAX_TEXT_BYTES,
                            "description": "Optional final voice-ready text, at most 8192 UTF-8 bytes."},
            "idempotency_key": {"type": "string", "pattern": "^[A-Za-z0-9._-]{1,128}$",
                                "description": "Reuse the same key and text only when retrying."},
        },
        "required": ["display_text", "idempotency_key"],
        "additionalProperties": False,
    },
    "annotations": {"readOnlyHint": False, "destructiveHint": False,
                    "idempotentHint": True, "openWorldHint": False},
}
STATUSES = {
    "upgrade_required": "This draft client has no delivery proof. Use the signed Agent helper or paste the draft manually.",
    "accepted": "Added to the local inbox. Nothing has been applied to the editor or played.",
    "duplicate": "That draft was previously accepted. Nothing new was added or played.",
    "conflict": "That key was already used for a different draft.",
    "busy": "The local inbox is full. Nothing was added.",
    "invalid": "Invalid draft arguments.",
    "disabled": "The app no longer allows draft receipt from this helper.",
    "offline": "The app may be closed or draft receipt not allowed for this helper.",
    "unsafe": "The pinned app peer could not be verified. No draft was sent.",
    "unconfirmed": "Receipt could not be verified. Reuse the same key and text if retrying.",
}


def valid_arguments(args):
    if not isinstance(args, dict) or set(args) not in (
        {"idempotency_key", "display_text"}, {"idempotency_key", "display_text", "speech_text"}
    ):
        return False
    key = args["idempotency_key"]
    if not isinstance(key, str) or not KEY.fullmatch(key):
        return False
    for name in ("display_text", "speech_text"):
        if name not in args:
            continue
        text = args[name]
        if not isinstance(text, str):
            return False
        try:
            if not text.strip() or "\x00" in text or len(text.encode("utf-8")) > MAX_TEXT_BYTES:
                return False
        except UnicodeError:
            return False
    return True


def submit(arguments):
    # Keep discovery/tool name for existing configurations, but never transmit
    # unproven text to the versioned production receipt socket.
    return "upgrade_required"


class DraftSession(Session):
    tool = TOOL
    server_name = "codebasic-tts-draft"

    def __init__(self, backend=submit):
        super().__init__(backend)

    def execute(self, args):
        status = self.backend(args) if valid_arguments(args) else "invalid"
        message = STATUSES.get(status, STATUSES["unconfirmed"])
        if status in ("offline", "disabled", "unconfirmed"):
            message += f" Local draft helper PID: {os.getpid()}."
        return {"content": [{"type": "text", "text": f"{status}: {message}"}],
                "isError": status not in ("accepted", "duplicate")}


if __name__ == "__main__":
    try:
        run(sys.stdin.buffer, sys.stdout.buffer, session=DraftSession(), max_frame=MAX_FRAME)
    except BrokenPipeError:
        os._exit(0)
