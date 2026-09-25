---
description: Use when implementing protocol messages, transports, sessions, auth, or compatibility with upstream Signal Fish projects.
triggers: signal fish, protocol, websocket, session, auth, message, rust client, server
category: Protocol
---

# Signal Fish Protocol

## Trigger

Use this skill when changing protocol semantics, message schemas, connection
state, authentication, reconnection, or upstream compatibility.

## Ground Truth

Check upstream before guessing:

- Server: <https://github.com/Ambiguous-Interactive/signal-fish-server>
- Rust client: <https://github.com/Ambiguous-Interactive/signal-fish-client-rust>
- Cloud: <https://github.com/Ambiguous-Interactive/signal-fish-cloud>
- Curated notes: `.llm/research/protocol-links.md`

## Confirmed Wire Facts (pinned to upstream)

Source-of-truth paths and commit SHAs live in `.llm/research/protocol-fixtures.md`.
Never invent protocol details; re-verify against the pinned commits before use.

- Transport: WebSocket (`ws://` local dev only, `wss://` production). Control
  messages are JSON **text** frames; negotiated binary game data uses binary
  frames.
- Envelope: externally tagged `{"type":"<Name>","data":{...}}` (serde
  `tag="type", content="data"`). Unit messages serialize as `{"type":"X"}`
  with **no `data` key**; the decoder also tolerates `data: null` and a
  missing `data`.
- 12 client->server messages: `Authenticate`, `JoinRoom`, `LeaveRoom`,
  `GameData`, `AuthorityRequest`, `PlayerReady`, `StartGame`,
  `ProvideConnectionInfo`, `Ping`, `Reconnect`, `JoinAsSpectator`,
  `LeaveSpectator` (plus v3 `Signal`/`TransportStatus`, exposed as
  `peer_signal`/`send_transport_status` - `signal` is a GDScript keyword).
- 26 client events = 24 server messages + synthetic `Connected`/
  `Disconnected`. v3 adds the session-plan surface (`SessionPlan`, `NewPeer`,
  `Signal`, `PeerTransportStatus`).
- Game data encodings: `json` (default/fallback), `message_pack` (opt-in
  decode; with decode off the payload passes through raw and the frame
  still carries `from_player`). `rkyv` is server-reserved and never
  negotiated: `configure()` refuses it (issue #146), while a v3 envelope
  `encoding: rkyv` token still decodes as raw bytes. An unsupported
  preference is downgraded to JSON by the server (logged at WARN); binary
  send/receive gates on the **effective** format.
- Room state machine: `Waiting -> Lobby -> Finalized`; `PlayerReady` toggles;
  single-player rooms skip Lobby; authority is requested, not auto-assigned;
  leaving drops `Lobby -> Waiting`.
- Reconnection: `Reconnect{player_id, room_id, auth_token}` ->
  `Reconnected{...baseline..., missed_events}` or `ReconnectionFailed`. See
  `.llm/skills/reconnection-replay.md` for pinned anchors and client rules.
- Config defaults (pinned): `game_data_format` unset resolves to JSON (rust
  `client_core.rs` `resolve_effective_game_data_format`); `JoinRoomParams`
  optionals default `None` -> omitted on the wire (`protocol.rs` @ `da8f2d1`);
  an omitted `supports_authority` means **enabled** (server `room_service.rs:
  585` `unwrap_or(true)` @ `5af5fee`).
- Field naming (verified 2026-09-23, server `main` @ `272cfa0c`): payload
  structs have **no `rename_all`** - fields serialize snake_case inside
  PascalCase-tagged envelopes (`RoomJoined`/`Reconnected`/
  `SpectatorJoined` field lists match our codec exactly; `missed_events` is
  mandatory even when empty).
- `error_code` (verified same commit): mandatory on `AuthenticationError` and
  `ReconnectionFailed`; `Option` + skip-when-None (key absent, decodes to
  `Code.NONE`) on `RoomJoinFailed`, `AuthorityResponse`, `SpectatorJoinFailed`,
  and `Error`. Absent - never `null` - is the only wire shape for "no code".
- Identifiers are UUIDs upstream (`PlayerId`, `RoomId`, `SessionGeneration`):
  a present empty-string id cannot deserialize upstream and collides with the
  retired negotiated-rkyv "" sender-unknowable sentinel, so text-path decodes
  reject it with `protocol_error` (frame dropped, link stays up; issue #149).
  The binary path already enforces the 16-byte UUID. Free-text `String`
  fields (`error`, `reason`, `message`, `app_name`, names, `room_code`) pass
  empty strings through verbatim.
- `ConnectionInfo` (verified same commit): internally tagged `type` with
  explicit renames `direct|unity_relay|relay|webrtc|custom`; field sets match
  `SFTypes.ConnectionInfo` (`webrtc.sdp` serializes `null` rather than being
  skipped; serde accepts our omission on decode).

## Implementation Rules

- Treat the Rust client as the reference for client-side behavior.
- Treat the server as the reference for accepted message shapes and lifecycle.
- Before runtime implementation, anchor concrete wire formats,
  authentication flow, reconnect behavior, and error semantics to upstream
  file paths and commits.
- Preserve wire compatibility over local convenience.
- Keep transport, message encoding, and Godot-facing API separate.
- Never silently swallow protocol errors; surface them through explicit results,
  errors, or Godot signals.
- Do not rely on WebSocket handshake headers for browser exports. If upstream
  requires auth metadata, verify whether it can be sent after open as a
  protocol message or through an explicitly reviewed browser-compatible flow.
- Treat close codes, reconnect timing, duplicate messages, and backpressure as
  protocol-visible design questions before shipping automatic retries.

## Questions To Answer Before Coding

- Which upstream commit or release defines the behavior?
- Is the message direction client-to-server, server-to-client, or both?
- Does behavior differ for reconnects, duplicate messages, or partial failures?
- Is ordering, idempotency, or retry behavior required?
- Does the feature require secure storage or user secrets?
- Does the chosen transport work in Godot web exports without native-only socket
  features?

## Test Expectations

- Add fixtures for message encoding and decoding.
- Include failure cases for malformed input.
- Include transport-free tests where possible.
- Add integration tests only after deterministic unit coverage exists.
- Use fake transport adapters for reconnect, close, and backpressure tests
  before adding live WebSocket tests.
