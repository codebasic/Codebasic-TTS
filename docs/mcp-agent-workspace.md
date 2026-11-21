# Agent workspace bridge (MCP)

## Purpose

The Agent tab keeps a local catalog of instruction texts and an inbox for drafts written by an
external agent. The agent bridge is a small signed helper inside the app bundle that an MCP
client starts over stdio. It lets one agent session

1. read exactly one instruction that the owner explicitly shared, and
2. submit display text (and optional speech text) written for that exact instruction version.

The app never calls a model for this path, never plays a received draft by itself and never
overwrites the editor. Without the bridge everything still works by copy and paste.

## What is and is not trusted

- Pairing scopes **one running, locally signed bridge process (PID)** on this Mac. The name typed
  when pairing is only a local label. It is not an identity of any remote agent or model.
- Both sockets accept a connection only when the peer has the same real and effective user, is
  the paired PID with the same start time, and its live code signature has the identifier
  `com.codebasic.tts.agent-bridge` and the same signing certificate as the app.
- Ad hoc or unsigned builds cannot pair. Build with the stable signing identity described in the
  README. Manual copy and paste remains available.
- Pairing, read permission and receipt permission live in memory only. Quitting the app, pressing
  disconnect, or the bridge exiting ends all of them. Permissions expire after at most 10 minutes.
- Reading and receiving are separate permissions with separate revoke buttons. Editing or deleting
  a shared instruction ends its read permission immediately. After a delete, drafts for that
  instruction are refused; drafts that were already accepted stay in the inbox.
- A remote model used by the agent may receive whatever instruction you share. Do not share
  secrets.

## Build

`./build.sh build` compiles the bridge to
`/ABSOLUTE/PATH/TO/<AppName>.app/Contents/MacOS/codebasic-tts-agent-bridge`, signs it with the
configured identity (identifier `com.codebasic.tts.agent-bridge`, hardened runtime) and then signs
the app. `./build.sh test` compiles the core tests and a fresh copy of the bridge in the build
directory; it does not start the app or any service.

## MCP client configuration

The bridge requires both environment variables. The Agent tab shows the two values for the
running app under "MCP 설정값".

| Variable | Value |
| --- | --- |
| `CODEBASIC_TTS_APP_BUNDLE_ID` | Code signing identifier (bundle identifier) of the app |
| `CODEBASIC_TTS_SIGNER_SHA1` | 40 hex digit SHA-1 of the app's signing certificate |

Example (replace every placeholder with an absolute value):

```json
{
  "mcpServers": {
    "codebasic-tts-agent": {
      "command": "/ABSOLUTE/PATH/TO/<AppName>.app/Contents/MacOS/codebasic-tts-agent-bridge",
      "args": [],
      "env": {
        "CODEBASIC_TTS_APP_BUNDLE_ID": "<APP_BUNDLE_ID>",
        "CODEBASIC_TTS_SIGNER_SHA1": "<40_HEX_SIGNER_SHA1>"
      }
    }
  }
}
```

## Use

1. Start the MCP client so the bridge is running. Ask the agent to call `get_tts_instructions`;
   while nothing is shared the reply is `unavailable` and includes `helper_pid`.
2. In the Agent tab enter that PID and a label of your choice, then connect.
3. Select an instruction, press share, review the exact text in the dialog and confirm. Nothing is
   shared by selecting alone.
4. Optionally allow draft receipt. The agent reads the instruction, then submits a draft with the
   returned `revision`, `display_text`, an `idempotency_key` and optionally `speech_text`.
5. Open the draft from the inbox, review it (a separate speech text must be confirmed) and play it.

## Wire summary

Sockets live in the per-user directory `/private/tmp/codebasic-tts-mcp-<uid>` (mode 0700).

- `ai.sock` accepts only `{"operation":"get"}` and returns `schema_version` 2, `profile_id`,
  an opaque `revision` and `instructions`. There is no listing or discovery and no local label.
- `ad.sock` accepts `revision`, `display_text`, `idempotency_key` and optional `speech_text`
  (each text at most 8 KiB, frame below 100 KiB) and returns only a status: `accepted`,
  `duplicate` (same content already queued; success, no new draft), `conflict` (key reused with
  different content), `stale_revision`, `rate_limited`, `too_large`, `busy`, `not_paired` or
  `denied`.

A draft is accepted only for an instruction version that was fully delivered to this same bridge
during the current receipt permission. Text is treated as data only.

## Troubleshooting

- `unavailable`: the app is not running, nothing is shared, the permission expired, or the bridge
  was restarted (a new PID must be paired again).
- `stale_revision`: read the instruction again and resubmit with the new revision.
- The socket cannot be opened after a crash: quit the app and remove the stale `ai.sock` or
  `ad.sock` entry from the per-user socket directory.
- The legacy `i.sock` and `d.sock` endpoints are no longer started by the app.
