# Changelog

User-facing changes only. Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Versioning: [SemVer](https://semver.org/) — `vMAJOR.MINOR.PATCH`, pre-1.0 while the API stabilizes.
CI, tests, and internal tooling are not listed.

## [Unreleased]

### Changed

- Decoded events and typed payloads no longer deep-copy the parsed wire
  data: `raw` is a read-only view that may share structure across
  `missed_events`, and `to_dict()` remains the independent mutable copy.
- Lower steady-state and per-message allocations: idle mesh polling no longer
  allocates, and MessagePack/binary game-data decode reuses constant tables
  instead of rebuilding lookups per frame.
- Outbound JSON game/signal payloads now round-trip exactly: nested
  floats keep full precision (integral floats stay `2.0` on the wire,
  never integer text) instead of being rounded to fewer digits by the
  engine's JSON writer. Floats the engine cannot round-trip through
  JSON (some very small magnitudes) are refused with a diagnostic
  rather than silently altered.
- `send_game_data` and `send_signal` now refuse non-finite floats
  (`nan`/`inf`) and values JSON cannot represent — engine-only Variants
  such as `Vector2`, `StringName`, or `Packed*Array` values — with
  `protocol_error` + `ERR_INVALID_DATA` instead of putting corrupted or
  unparseable frames on the wire. This also applies at the encode
  boundary to payloads that skip builder validation, such as
  `ConnectionInfo.custom.data`. `send_game_data` accepts JSON `null`
  anywhere in the payload; the `send_signal` matchbox payload keeps
  refusing it.
- `send_transport_status`'s first parameter is renamed
  `transport_kind` (it shadowed the client's `transport` member);
  positional calls are unaffected.
- A game-data-format downgrade diagnostic now names the server's formats
  as wire tokens (`[json, unknown]`) instead of coerced enum integers.

### Fixed

- Wrong-typed enum values on the wire (e.g. a number where a token string
  belongs) now decode to `protocol_error` instead of silently decoding as
  the first enum member: `PeerTransportStatus.transport` no longer reports
  `relay` for hostile values, and every token-lookup helper fails closed
  to its `UNKNOWN` member (#81).
- A `ConnectionInfo` with an explicit `port: null` no longer aborts
  mid-construction and silently drops later fields (credentials,
  connection data); a null port now reads like an absent one (#81).
- Hostile `Authenticated`/`Reconnected`/`ProtocolInfo` events that follow
  a failed authentication on a reconnect dial no longer leak the
  consumer-silent dial contract: `authenticated` is never emitted on a
  dial, a `Reconnected` before the dial's handshake went out is ignored,
  and duplicate `ProtocolInfo` events stay fully silent (#82).
- `SFMsgpack.encode` now refuses non-finite floats (`nan`/`inf`) with a
  diagnostic instead of encoding them, because the server-side JSON
  decode would collapse them (#83).
- A `ProtocolInfo.player_name_rules` length beyond the platform integer
  range is rejected with `protocol_error` instead of collapsing to a
  platform-dependent value (#78).
- `SFWebRTCMesh` no longer sends signals or transport-status reports while the
  client is closing: those sends were refused with a spurious
  `protocol_error` and lost the final "disconnected" report.
- A refused `Authenticate` (e.g. the send backpressure cap) now resolves the
  dial with `connection_failed` and a clean teardown instead of stalling the
  session with nothing in flight.
- Auto-reconnect now retries with the credentials of the most recent manual
  `reconnect()` dial, so a rotated token is never shadowed by a stale one.
- A `ProtocolInfo.max_outbound_message_size` beyond the platform integer
  range is rejected with `protocol_error` instead of silently disabling the
  outbound cap.
- `ConnectionInfo.to_dict()` returns an independent copy of `custom.data`
  instead of aliasing the caller's dictionary.
- Closing during the `opened` callback no longer risks a crash when a consumer
  handler fails the session synchronously.
- Web exports no longer drop server messages that arrive shortly before a
  close: the transport now drains packets still queued when the socket closes
  before surfacing the close event (#70).
- A duplicate `Reconnected` from a hostile or buggy server no longer emits a
  second `reconnected`, so consumers replaying `missed_events` cannot
  double-apply game events (#71).
- Wrong-typed `Authenticated.organization` and `reconnection_token` values now
  decode to `protocol_error` instead of being silently coerced to strings,
  matching the strictness of every other field (#72).

### Added

- Documentation site: release runbook for the Godot Asset Library (one-time
  first submission, secrets setup, automated per-release updates).
- Documentation site: branded MkDocs Material site published to GitHub
  Pages on every push to main. Covers quick start, the full client API
  reference, events, errors, game data, reconnection, web export,
  deterministic testing, and the WebRTC mesh guide, plus a machine-readable
  `llms.txt`.
- Addon packaging: `plugin.cfg`, `plugin.gd`, `icon.png`, and an addon-level
  README + LICENSE. The addon now registers as a Godot editor plugin and is
  Asset Library-ready.
- `demo/p2p.tscn`: P2P example that negotiates a v3 session plan, attaches
  `SFWebRTCMesh`, and chats over mesh RPCs once peers connect.
- `demo/main.tscn`: runnable demo scene (connect → join → game data → leave)
  with a log of client events, set as the project main scene. A "Web" export
  preset builds the demo straight to a browser build.
- `SFWebRTCMesh` node (opt-in): turns negotiated v3 session plans into a
  `WebRTCMultiplayerPeer` mesh for high-level multiplayer RPCs. The server
  decides who offers; ICE lists are replaced on every plan; peers are rebuilt
  on generation/role changes and dropped when a plan or a player leaves.
  Peer ids derive deterministically from player UUIDs.
- `SignalFishConfig.credential` now rides `Authenticate` as the upstream
  `connect_token` field (rust SDK 0.14.0). Still set in code only: never
  exported, never logged, never persisted by the Resource pipeline.
- Protocol v3 session-plan surface: `SignalFishConfig` capability fields
  (`protocol_version`, `supported_transports`, `supported_topologies`,
  `requested_capabilities`), `SessionPlan`/`NewPeer`/`Signal`/
  `PeerTransportStatus` events, `send_signal`/`send_transport_status`,
  ICE-server pre-gather on `RoomJoined`/`Reconnected`, and the extended
  `ProtocolInfo` version fields. Unset by default: v2 wire bytes are unchanged.
- `SignalFishClient` node: connect, authenticate, join rooms, send/receive game
  data, authority, spectators, reconnection with missed-event replay, and
  opt-in auto-reconnect.
- Pure-GDScript Signal Fish v2 codec: 12 client messages, 24 server events,
  full error-code table, MessagePack decode (opt-in), binary game data.
- `SignalFishConfig` resource with frame-size caps, send backpressure, and a
  redacting logger (tokens never logged).

### Security

- Reconnection tokens, TURN credentials, and other secrets stay out of logs,
  fixtures, and error messages.
