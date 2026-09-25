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

- `signal-fish-server`: `24a5d10b9e1700cdbef24f05dfe7fe1f0719ac3d` (tag `v0.9.1`)
- `signal-fish-client-rust`: binding `0.14.0` / protocol authority
  `e1b65b965390355e9fd15661dc95a8a4321eab17` (synced 2026-09-18 per the
  upstream `tests/compatibility.toml`)
- `signal-fish-cloud`: `ffdd5105d9e844aefd54ec4a3cd832231dd428cd`

Re-pinned 2026-09-20 (issue #12). Prior pins (read 2026-05-29): server
`4f766b7856bead1e1cc07d4e7a1057831a045749`, client-rust
`da4c0bdf0657370ec340321363f3b5850e06b0b0`. Drift against the upstream
binding is checked by `scripts/check-protocol-sync.py` (weekly scheduled
workflow `protocol-sync.yml`); the upstream surface diff at re-pin time:

- v0.9.2 spec refresh (2026-09-21, issue #55): server tag `v0.9.2` is
  `6b76d665f32f2af4acc64dee8a5239f93bd5b784`. It changed no protocol
  surface (`messages.rs`/`types.rs`/`error_codes.rs` untouched; only
  server-internal bus routing and dependency bumps), so the codec pin
  above stays at the v0.9.1 wire commit while the rust binding still
  pins it. What v0.9.2 did change is the published wire samples: the
  `.llm/code-samples/protocol` v2 files are now concrete, complete,
  round-trip-guarded frames (server PRs #612/#613) instead of elided
  shapes. They are vendored byte-identically (plus a provenance header)
  under `tests/fixtures/upstream/` and pinned to the codec by
  `tests/protocol/upstream_samples_tests.gd`; sample digests:
  - `v2-client-messages.jsonl`
    `b1e1bbfb3df2603fd8bf4630d49ddbf3fa65708200a2b1e8f081631c49f2025a`
  - `v2-server-messages.jsonl`
    `58272c29fef10f2eaa865f935a9e832bc601127890242a7c30b30bbaf8828407`
  Upstream notes the v2 corpus is complete for text envelopes:
  `GameDataBinary` has no `{type, data}` JSON form, and `StartGame`
  refusals arrive as `Error{GAME_START_NOT_READY}` frames.

- v2 wire bytes are frozen upstream: no legacy message variant, error code,
  or field was renamed or removed; all new surface is additive. `StartGame`
  and `password` on JoinRoom/JoinAsSpectator are v2-reachable (both present
  in the upstream v2 wire sample) and shipped in the Godot codec (issue
  #26). The rest is v3-route only (new `Signal`/`NewPeer`/`SessionPlan`/
  `RoomOperationResult`/`PeerTransportStatus`/`RelayStats`/`GoingAway`/
  `DeliveryReport` server events; `Signal`/`RoomOperation`/`TransportStatus`
  client messages; v3 negotiation fields on `Authenticate`). The v2-route
  codec stays wire-compatible unchanged.
- Error codes grew from 41 to 62 upstream (moderation, delivery, lifecycle,
  game-start, auth categories). The Godot table was extended to the full
  v0.9.1 surface (issue #26): string lookups derive from the enum, and
  `category()` follows the upstream `docs/reference/error-codes.md` tables
  via a per-code map whose completeness is test-pinned.
- `PlayerNameRules.allowed_symbols` widened upstream from `Vec<char>` to
  `Vec<String>` (both serialize as JSON string arrays; current servers emit
  one-character strings). The GDScript codec treats entries as plain
  strings with no width assumption, so both shapes decode; pinned by
  `_test_allowed_symbols_widen_parity`. `max_length`/`min_length` are
  measured in UTF-8 bytes upstream (advisory pass-through here, matching the
  Rust client).
- `RoomJoinedPayload`/`ReconnectedPayload` carry an optional server-issued
  `reconnection_token`, rotated on every join and every successful
  reconnect; the fixtures now model both (rotation pinned by the fixture
  decode test).
- The Rust SDK also vendors upstream wire samples with sha256 digests in
  `tests/compatibility.toml` (`[wire_samples]`); all four verified live
  2026-09-20 (this file is our provenance record for the digests):
  - `v2-client-messages.jsonl`
    `929f25d702d3e21f2cca640cd14f9ce044945a6ef9c2c258de56f3f112164227`
  - `v2-server-messages.jsonl`
    `b5aee60d2cbd410c1088da1bbd1142d88d89600bc600f00b2d1849586f1654cd`
  - `v3-client-messages.jsonl`
    `5f6e92f550e7bb0b2ea4be02dea30f5b09677ecf4e01b5451d41d824f405b4cb`
  - `v3-server-messages.jsonl`
    `a175151b8b4dffa95818b11d41651551d499f9388e00309c95e0ba12159bbfce`
  The v0.9.1-era note that the upstream v2 samples were elided
  `"..."` shapes is obsolete: since server v0.9.2 they are concrete
  frames (see the spec-refresh bullet above). The Godot fixtures remain
  hand-built supersets (all 24 server variants, full-field shapes,
  fake-placeholder tokens, byte-pinned to the Godot builders); the
  concrete upstream samples are additionally vendored and decoded
  end-to-end by `tests/protocol/upstream_samples_tests.gd`, so both the
  hand-built corpus and the published spec bytes guard the codec.

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
| Upstream illustrative fixtures | server | `.llm/code-samples/protocol/v2-client-messages.jsonl`, `.llm/code-samples/protocol/v2-server-messages.jsonl` (concrete frames since v0.9.2) |
| Vendored upstream v2 samples | server | `tests/fixtures/upstream/v2_client_messages.jsonl`, `tests/fixtures/upstream/v2_server_messages.jsonl` |
| Cloud protocol cross-check | cloud | `src/protocol/messages.rs`, `src/protocol/types.rs`, `src/protocol/error_codes.rs` |

## Fixture Files

- `tests/fixtures/v2_client_messages.jsonl` covers all 12 `ClientMessage`
  variants from `messages.rs` / `protocol.rs` (including `StartGame`, added
  at the v0.9.1 re-pin; issue #26).
- `tests/fixtures/v2_server_messages.jsonl` covers all 24 `ServerMessage`
  variants from `messages.rs` / `protocol.rs`.
- `tests/fixtures/malformed.jsonl` covers malformed JSON, missing or invalid
  envelope types, unknown events, wrong payload shapes, and invalid binary
  payload shapes.
- `tests/fixtures/v3_client_messages.jsonl` (added 2026-09-20, P3) covers the
  v3 client surface: `Authenticate` capability fields, `Signal`
  (offer + trickle-ICE), and `TransportStatus`, pinned to the same server
  v0.9.1 commit and the rust `protocol.rs` v3 variants.
- `tests/fixtures/v3_server_messages.jsonl` (added 2026-09-20, P3) covers the
  v3 server surface: `SessionPlan` in all four baseline shapes (mesh+webrtc
  with STUN/TURN, host+direct with endpoint, explicit relay-floor reset, and
  the legacy Server 0.4 shape without `generation`), `NewPeer`, `Signal`
  (answer), `PeerTransportStatus`, `RoomJoined` ICE pre-gather, and the
  extended `ProtocolInfo` (negotiated/min/max version, `transports`,
  `max_outbound_message_size`).
- `tests/fixtures/upstream/v2_client_messages.jsonl` and
  `tests/fixtures/upstream/v2_server_messages.jsonl` (added 2026-09-21,
  issue #55) are byte-identical copies of the upstream v0.9.2 concrete
  sample corpus with a provenance header; the sample digests above pin
  the upstream bytes. `tests/protocol/upstream_samples_tests.gd` decodes
  every server line and checks every client line against the client
  message type set.
- Upstream v3 signaling anchors: server `docs/concepts/protocol-versions.md`
  (v2-vs-v3 mental model, capability negotiation, selection ladder),
  rust `src/webrtc.rs` + `src/mesh.rs` (signaling choreography: obey the
  per-peer `initiate` flag verbatim; latest plan wins; reject signals from
  other generations; `TransportStatus` only at the aggregate 0<->1 boundaries).

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
- Binary game-data frames (pinned 2026-09-20; stable since server v0.4.0,
  rust `src/protocol/binary.rs` port note; re-verified against server
  `main` @ v0.9.1 `src/websocket/sending.rs`):
  - Client->server binary frames are the raw payload bytes only. The server
    tags them with the negotiated format and drops binary on `json`
    connections with `InvalidInput` (server `websocket/connection.rs`).
  - Server->client v2-route `message_pack` frames are a MessagePack named map:
    `from_player` (16-byte binary UUID; `PlayerId = uuid::Uuid` serializes as
    bytes in non-human-readable formats), `encoding` (`"message_pack"`), and
    `payload` (binary). v2-route `rkyv` frames are the raw payload bytes with
    no envelope, so the sender is unknowable for them. The v2 cohort match
    (`encoding == recipient_format`) also admits json-encoded binary frames
    to json recipients, but that path cannot originate: the server drops
    binary from json senders, and any other encoding relayed to a json
    recipient falls back to a text `GameData` frame (`BinaryFallbackV2`).
    The Godot client therefore treats binary on a json connection as
    hostile/buggy input: `protocol_error`, frame dropped, link stays up.
  - The server may downgrade an unsupported `game_data_format` preference to
    JSON at Authenticate (`Error{UnsupportedGameDataFormat}` and/or the
    requested format missing from `ProtocolInfo.game_data_formats`); the
    client tracks the effective format and gates binary send/receive on it.
    `rkyv` is reserved upstream and never negotiated (server docs/CHANGELOG),
    so the Godot client refuses it at `configure()` (issue #146); the v3
    `rkyv` envelope token below still decodes as raw bytes.
  - v3 (separate v3 WebSocket route only) adds mandatory non-zero `seq` (u64)
    and `epoch` (u32) stamps and allows `json`/`message_pack`/`rkyv` encoding
    tokens (`V3BinaryGameDataFrame`).
  - Strictness (rust `decode_v2/v3_binary_game_data` parity): map keys are
    strings, fields appear at most once, unknown fields and trailing bytes are
    rejected, and integer stamps may use any unsigned marker width. The
    Godot decoder (`sf_binary_frames.gd`) accepts v2 and v3; for well-formed
    frames a v2 envelope can never parse as v3 and vice versa (v3 requires
    both stamps, v2 forbids them).
- Relay `ConnectionInfo.transport` defaults to `auto` upstream when omitted or
  null. Outbound builders should reject typo strings, while inbound decoding
  should map unknown future transport strings to `RelayTransport.UNKNOWN`.
- Present enum-like wire strings must be non-empty. Optional fields use
  omission or JSON `null` to mean "no value"; an empty `error_code`, spectator
  reason, binary encoding, connection info type/transport, or protocol game
  data format is malformed. Identifier fields (`PlayerId`, `RoomId`,
  `SessionGeneration`) are UUIDs upstream and stricter still: a present id
  must be canonical lowercase hyphenated UUID text (issue #151) - empty is
  malformed too (issue #149), and simple/braced/urn/uppercase spellings are
  serde parse-acceptance only, never wire forms (the server re-serializes
  each id it relays through the typed `Uuid`; its `canonical_room_operation_id`
  module likewise refuses non-canonical client text). Decoders refuse with
  `protocol_error`; the outbound `Reconnect`/`Signal` builders gate the same
  shape. Free-text `String` fields accept empty verbatim.
- `ConnectionInfo.to_dict()` returns a canonical dictionary for known
  connection types, normalizing accepted inbound integral JSON numbers to Godot
  `int` values and omitting optional JSON `null` fields so decoded connection
  info can be safely re-sent through `ProvideConnectionInfo`. Unknown future
  relay transports decode as `RelayTransport.UNKNOWN` and are omitted from the
  canonical outbound form instead of re-emitting an unsupported string.
- Reconnect uses `player_id`, `room_id`, and `auth_token`; fixtures use fake
  placeholder tokens only.

## Open Verification Items

- Binary frame format (resolved 2026-09-20): the pinned v2/v3 envelope
  contract in the Wire Notes section supersedes the older docs-vs-source
  drift question for frames; implemented in
  `addons/signal_fish/protocol/sf_binary_frames.gd` with byte-pinned tests.
- Server docs still show a base64 string for `GameDataBinary.payload`, while
  current source uses binary frames for negotiated binary payloads and
  `serde_bytes` for text serialization. The text-form decoder
  (`sf_binary_codec.gd`) stays tolerant of both byte arrays and base64
  strings until an upstream fixture resolves the documentation drift.
- `supports_authority` defaults to `true` in server
  `src/server/room_service.rs`; docs imply omitted or false disables authority.
  Godot API defaults must be decided against source compatibility before P1.
- Server and Rust client expose `STORAGE_ERROR`; cloud exposes
  `DATABASE_ERROR`. Include a compatibility policy before locking the final
  error-code table.
- Reconnection token origin (resolved 2026-09-19): the server issues
  `reconnection_token: Option<String>` inside every `RoomJoinedPayload` and
  `ReconnectedPayload` (server `src/protocol/messages.rs` @ `eaae1ca3`);
  the Rust client retains it for opt-in auto-reconnect
  (`src/client_core.rs` `AutoReconnectContext` @ `fdab2e83`). See
  `.llm/skills/reconnection-replay.md`. Upstream rotates the token on every
  join and every successful reconnect; the fixtures now carry fake
  placeholder tokens modeling the rotation (issue #12).
- Upstream close-code conventions (resolved 2026-09-23, server `main` @
  `272cfa0c`): `CloseReason` in `src/coordination/mod.rs` maps `4000`-`4007`
  plus RFC `1000`/`1009`; see the table in
  `.llm/skills/reconnection-replay.md`.
