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

- Connecting scopes **one running, locally signed bridge process** on this Mac. The owner approves
  it once in the Agent tab; the PID and start time shown there come from the kernel, and nothing is
  typed in. It is not an identity of any remote agent or model.
- The bridge finds the running app by itself and authenticates it by the kernel audit token of the
  socket peer: fixed app signing identifier plus the bridge's own signing certificate. Process
  names, environment variables, handshake JSON, same-user alone and old socket paths are not trusted.
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

The command is the only setting. There are no environment variables, PIDs, ports, socket paths,
fingerprints or identifiers to enter, and the app never edits an MCP client configuration.

```json
{
  "mcpServers": {
    "codebasic-tts-agent": {
      "command": "/ABSOLUTE/PATH/TO/<AppName>.app/Contents/MacOS/codebasic-tts-agent-bridge",
      "args": []
    }
  }
}
```

Upgrading from the earlier pairing: remove the two `CODEBASIC_TTS_*` variables (they are ignored)
and restart the MCP client so it starts the bridge bundled with this app version. An older bridge
binary only knows the fixed `ai.sock` / `ad.sock` paths, which the app no longer opens; it keeps
answering `unavailable` until it is replaced. Tool names, arguments and results are unchanged.

## Use

1. Start the MCP client. Starting the bridge and listing its tools work even while the app is
   closed; a tool call then answers `unavailable` with `reason` `app_not_running`.
2. With the app open, the first tool call answers `approval_pending` and the Agent tab lists the
   request with its PID and start time. Approve it once. Several requests are listed side by side.
3. Select an instruction, press share, review the exact text in the dialog and confirm. Nothing is
   shared by selecting alone.
4. Optionally allow draft receipt. The agent reads the instruction, then submits a draft with the
   returned `revision`, `display_text`, an `idempotency_key` and optionally `speech_text`.
5. Open the draft from the inbox, review it (a separate speech text must be confirmed) and play it.

## Wire summary

Each running app owns a private generation directory
`/private/tmp/codebasic-tts-mcp-<uid>/g<pid>.<start-seconds>.<start-microseconds>` (mode 0700,
sockets 0600). A restarted app is a new generation; entries left by a crash are never reused or
unlinked and are ignored by the bridge because their process is gone.

- `c.sock` accepts only `{"operation":"hello","protocol":3}` and returns `protocol` and a `status`
  of `pending`, `approved`, `denied` or `busy`. It carries no user data and grants nothing.

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

- `unavailable`: read `reason`. `app_not_running`, `approval_pending`, `approval_denied`,
  `approval_busy`, `multiple_apps` (quit all but one app), `nothing_shared`, `receipt_not_allowed`
  or `bridge_not_signed` (use the bridge inside a build signed with the stable identity).
- After the app or the bridge restarts, the owner approves again. Approvals are never stored.
- `stale_revision`: read the instruction again and resubmit with the new revision.
- After a crash nothing needs to be removed by hand: the next launch uses a new generation
  directory. Leftover `g*` directories are inert and are cleared with `/private/tmp`.
- The legacy `i.sock` and `d.sock` endpoints are no longer started by the app.

## Testing without credentials

`./build.sh test` needs no signing identity, app, provider or network:

- `Tests/AgentBridgeAdmissionTests.swift`: decision state (no implicit grant, exact PID + start
  time + PID version, expiry, revoke), generation names, and the real listener in a temporary root
  (existing or stale paths refused and left in place; production authenticator refuses unsigned,
  ad hoc and differently signed clients).
- `Tests/test_agent_bridge_discovery.py`: the unsigned production bridge fails closed, and a
  fixture bridge compiled with `-D AGENT_BRIDGE_TEST_SEAM` (signature check replaced by kernel peer
  identity, root taken from the test, never shipped) covers app closed, pending, the exact two-way
  round trip, wrong identity, stale socket and restart, and two live apps.

Signed end-to-end check (manual, uses only the local self-signed identity from the README and
synthetic text):

1. `TTS_BUILD_DIR=/private/tmp/cbtts-signed ./build.sh build` and start that app binary.
2. Pipe `initialize`, `tools/list` and a `get_tts_instructions` call into the bundled bridge:
   expect `approval_pending`, then approve the listed PID, share a synthetic instruction, allow
   receipt, and repeat with `submit_explanation_draft`: expect `accepted` and a queued, unplayed draft.
3. Negative checks: an ad hoc copy of the bridge (`codesign --force --sign -`) answers
   `bridge_not_signed`; a copy signed with another identity never appears as a request; after
   `kill -9` of the app and a relaunch the bridge answers `approval_pending` again.
