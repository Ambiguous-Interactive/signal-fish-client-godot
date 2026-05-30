---
description: Pinned upstream sources used to build Signal Fish v2 protocol fixtures for the Godot client.
triggers: protocol fixture, upstream commit, signal fish, codec, messages, error codes, reconnection, spectator
category: Protocol
---

# Signal Fish Protocol Fixtures

This file records the upstream sources used for the first Godot client protocol
fixtures. Wire details must be checked against these paths before changing the
codec or fixture files.

## Pinned Upstream Commits

- `signal-fish-server`: `4f766b7856bead1e1cc07d4e7a1057831a045749`
- `signal-fish-client-rust`: `da4c0bdf0657370ec340321363f3b5850e06b0b0`
- `signal-fish-cloud`: `ffdd5105d9e844aefd54ec4a3cd832231dd428cd`

These commits were read from the public `main` branch on 2026-05-29.

## Source Paths

| Concern | Repo | Path |
| --- | --- | --- |
| Client and server envelopes | server | `src/protocol/messages.rs`, `docs/protocol.md` |
| Core value types and enum wire names | server | `src/protocol/types.rs` |
| Lobby state names and room transitions | server | `src/protocol/room_state.rs`, `docs/concepts/rooms-and-lobbies.md` |
| Error code wire names | server | `src/protocol/error_codes.rs`, `docs/reference/error-codes.md` |
| WebSocket text vs binary frame behavior | server | `src/websocket/connection.rs`, `src/websocket/sending.rs` |
| Reconnection tokens and buffers | server | `src/reconnection.rs`, `docs/adr/reconnection-protocol.md`, `docs/concepts/reconnection.md` |
| Server room defaults and authority behavior | server | `src/server/room_service.rs` |
| Authority rules | server | `docs/concepts/authority.md` |
| Spectator rules | server | `docs/concepts/spectator-mode.md` |
| Rust client protocol mirror | client-rust | `src/protocol.rs` |
| Rust client error code mirror | client-rust | `src/error_codes.rs` |
| Rust client event set | client-rust | `src/event.rs` |
| Rust client API/config defaults | client-rust | `src/client.rs`, `src/polling_client.rs` |
| Rust client docs | client-rust | `docs/protocol.md`, `docs/events.md`, `docs/client.md`, `docs/wasm.md` |
| Upstream illustrative fixtures | server | `.llm/code-samples/protocol/v2-client-messages.jsonl`, `.llm/code-samples/protocol/v2-server-messages.jsonl` |
| Cloud protocol cross-check | cloud | `src/protocol/messages.rs`, `src/protocol/types.rs`, `src/protocol/error_codes.rs` |

## Fixture Files

- `tests/fixtures/v2_client_messages.jsonl` covers all 11 `ClientMessage`
  variants from `messages.rs` / `protocol.rs`.
- `tests/fixtures/v2_server_messages.jsonl` covers all 24 `ServerMessage`
  variants from `messages.rs` / `protocol.rs`.
- `tests/fixtures/malformed.jsonl` covers malformed JSON, missing or invalid
  envelope types, unknown events, wrong payload shapes, and invalid binary
  payload shapes.

Each fixture file starts with comment metadata. Future fixture readers must skip
blank lines and lines beginning with `#`.

## Wire Notes

- `ClientMessage` and `ServerMessage` use `#[serde(tag = "type", content =
  "data")]`.
- Unit messages omit `data` in the canonical serde JSON form.
- Enums use upstream serde rename rules: error codes are
  `SCREAMING_SNAKE_CASE`, lobby/game-data/spectator reasons are `snake_case`,
  and relay transport values are lowercase.
- Spectator state-change `reason` fields are upstream `Option` values. The
  Godot decoder accepts omitted or JSON `null` reasons as
  `SpectatorReason.UNKNOWN`; non-null strings unknown to this client also map
  to `UNKNOWN` for forward compatibility. Non-string reason values are still
  malformed at the event boundary.
- `SignalFishConfig::new()` in the Rust client sets `sdk_version` to the crate
  version, leaves `platform` unset, and leaves `game_data_format` unset.
- `JoinRoomParams::new(game_name, player_name)` only sets the two required
  fields; room code, max players, authority support, and relay transport are
  optional.
- Rust serde canonical output for `JoinRoom` includes `null` for unset
  `Option` fields because those fields are not marked `skip_serializing_if`.
  Server deserialization accepts missing fields as `None`. P0 fixtures use all
  optional fields populated until the Godot codec chooses a canonical
  null-versus-omitted policy.
- Current server code negotiates `game_data_format` after `Authenticate`.
  MessagePack and Rkyv game data use WebSocket binary frames when negotiated.
  JSON fallback from binary data becomes a `GameData` text message, not a
  `GameDataBinary` text message.
- `GameData.data` is a JSON value in upstream structs; JSON `null` is a valid
  game payload and should be surfaced as a `Variant` null instead of treated as
  a malformed message.
- `ConnectionInfo::Custom.data` is a JSON value in upstream structs. A missing
  `data` field is malformed, but a present JSON `null` is a valid custom
  payload and should be preserved as a `Variant` null.
- `PlayerNameRules.allowed_symbols` may be omitted and defaults to an empty
  list locally, but a present value must be an array; JSON `null` is not used
  as the default sentinel.
- The fixture `GameDataBinary` line is a serde-compatible text representation
  for codec coverage. Transport tests must separately verify binary frames.
- Relay `ConnectionInfo.transport` defaults to `auto` upstream when omitted or
  null. Outbound builders should reject typo strings, while inbound decoding
  should map unknown future transport strings to `RelayTransport.UNKNOWN`.
- Reconnect uses `player_id`, `room_id`, and `auth_token`; fixtures use fake
  placeholder tokens only.

## Open Verification Items

- Server docs still show a base64 string for `GameDataBinary.payload`, while
  current source uses binary frames for negotiated binary payloads and
  `serde_bytes` for text serialization. Keep the decoder tolerant of both byte
  arrays and base64 strings until a captured live frame or upstream fixture
  resolves the documentation drift.
- `supports_authority` defaults to `true` in server
  `src/server/room_service.rs`; docs imply omitted or false disables authority.
  Godot API defaults must be decided against source compatibility before P1.
- Server and Rust client expose `STORAGE_ERROR`; cloud exposes
  `DATABASE_ERROR`. Include a compatibility policy before locking the final
  error-code table.
- The exact client storage path for reconnection tokens is not exposed in
  `RoomJoinedPayload` or `ReconnectedPayload`. Auto-reconnect remains blocked
  until token issuance is pinned to source.
- Upstream close-code conventions were not found in the protocol files listed
  above. Treat close-code mapping as a later transport-phase decision gate.
