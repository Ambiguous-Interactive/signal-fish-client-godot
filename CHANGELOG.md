# Changelog

User-facing changes only. Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Versioning: [SemVer](https://semver.org/) - `vMAJOR.MINOR.PATCH`, pre-1.0 while the API stabilizes.
CI, tests, and internal tooling are not listed.

## [Unreleased]

### Changed

- Documentation is now ASCII-only; wording is unchanged where possible.
- A truncated replay (`missed_events` over the 256-entry decode cap) now
  keeps the newest entries and drops the oldest: `replay: truncated` means
  the wire array is the most-recent suffix, and the events closest to now
  are the ones a resync needs (#129). The overflow sentinel's dropped
  count is unchanged.
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
  (`nan`/`inf`) and values JSON cannot represent - engine-only Variants
  such as `Vector2`, `StringName`, or `Packed*Array` values - with
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

- A heartbeat beat refused under backpressure now arms the pong deadline:
  the beat keeps retrying each interval, a live-but-congested link recovers
  when its buffer drains, and a silently dead link fails (`connection_failed`)
  and engages auto-reconnect instead of sitting `CONNECTED` forever (#128).
- `SFWebRTCMesh` no longer drops refused signaling relays: a relay refused
  by backpressure or rate-limited by the server is re-queued per peer and
  redelivered in order (retries wait out one interval each). A queue that
  keeps being refused locally is dropped loudly after a retry budget
  instead of stalling P2P negotiation silently (#127).
- A `close()` that lands after the engine finished its handshake but
  before the client observed the open now deterministically ends as a
  failed open (`connection_failed`, state `FAILED`) instead of racing
  engine timing and surfacing `disconnected`/`CLOSED` (#119).
- A `close()` whose handshake never completes on a silently dead link no
  longer strands the client in `CLOSING` forever: the same pong deadline
  that guards authentication now bounds the closing window and tears the
  link down as a failure (`connection_failed`) (#126).
- A `4007` (kicked) close now ends the auto-reconnect episode: the server
  deletes a kicked player's reconnection record, so retrying could never
  rejoin. The identity clears before `disconnected`, so a handler redial
  still captures a fresh identity.
- Off-contract `RoomLeft`/`SpectatorLeft` frames can no longer wipe room
  state or erase the retained auto-reconnect identity (#106).
- An unsolicited `Reconnected` (no reconnect handshake on this dial) now
  surfaces `protocol_error` instead of being dropped silently (#108).
- MessagePack strings (opt-in payload decode) and binary-frame string fields
  now decode as real UTF-8: multi-byte strings such as `"héllo"` <!-- sf-allow:non-ascii -->
  or emoji arrived byte-mapped as mojibake, and the codec's own encode/decode
  round-trip broke for any non-ASCII character (#99).
- A `LobbyStateChanged` frame received without a room baseline is now
  informational only: it could previously forge an in-room session state,
  flipping `is_authenticated()` before `Authenticated` and letting
  `Ping`/`PlayerReady` frames onto the wire pre-authentication (#100).
- A hostile webrtc `ice_candidates` array on a directly constructed
  `ConnectionInfo` no longer silently drops wrong-typed entries on the
  documented `to_dict()` resend path - the verbatim entries let the
  outbound validation refuse the message loudly instead (#97). The same
  no-silent-loss contract now holds for roster round-trips
  (`RoomJoinedInfo`/`SpectatorJoinedInfo`): wrong-typed roster entries pass
  through `to_dict()` verbatim instead of vanishing, while valid entries
  keep their canonical form. The typed accessors intentionally keep
  only valid entries; the unfiltered view stays in `raw`.
- An explicit `close()` on a transport whose peer already reached
  `STATE_CLOSED` now drains queued data frames before emitting `closed`,
  matching the poll path - a consumer close could previously race the
  final frames out of the queue (#101).
- The WebRTC mesh now flips its transport-status boundary only when the
  report send succeeds: a report refused under backpressure stays armed
  and retries (at most once per interval, like the heartbeat's
  backpressured beats) instead of being lost for the session (#102).
- Inbound text frames containing a repeated JSON key (for example a second
  `"type"`) now fail closed with `protocol_error` instead of letting the
  engine's last-wins parser silently substitute fields - a smuggled
  duplicate could previously wipe room state or replace the retained
  reconnection identity. This matches the duplicate rejection upstream
  applies and the binary envelope path already enforced; keys compare
  after escape decoding, so `"\u0061"` and `"a"` are the same key, and a
  key spelling that decodes to a NUL-containing string is refused outright
  (the engine strips NUL and would merge it with a lookalike) (#92).
- `get_players()` and `get_spectators()` now return copies: the live internal
  rosters let one caller mutation (or a cached reference) silently corrupt
  session state (#87).
- The WebRTC mesh no longer leaks every dropped peer connection: the signaling
  lambdas are now disconnected on drop, breaking a reference cycle that grew
  with each plan rebuild (#86).
- Inbound `GameData.data` and `Signal` payloads now reject over-deep nesting
  (past the shared 16-level decode cap) and non-finite numbers (`1e400`
  decoded to `inf`; MessagePack `nan`/`inf` was accepted) with
  `protocol_error` instead of surfacing them as decoded game data. Binary
  frames keep their documented raw-bytes fallback path (#88).
- A fractional `ConnectionInfo.client_id` (e.g. `1.5`) no longer truncates to
  a different relay slot through `to_dict()`; it fails closed like a direct
  wire refusal (#89).
- Directly constructed typed payloads (`PlayerInfo`, `RoomJoinedInfo`,
  `ConnectionInfo`, session-plan types, and friends) no longer launder
  wrong-typed values: a wrong-typed number for a boolean field (for example
  `is_authority: 0.5`) read as `true`, wrong-typed strings or arrays aborted
  the constructor mid-way and dropped the remaining fields, and integer
  fields at hostile magnitudes (`1e30`) collapsed into platform-dependent
  values that could round-trip back out through `ConnectionInfo.to_dict()`.
  All now fail closed to the field's absent sentinel (#95, #96).
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

- v3 `Reconnected` frames now decode the replay status
  (`complete`/`truncated`/`unavailable`) and per-sender watermarks as typed
  fields on the room baseline, so a truncated replay is visible instead of
  silent. v2 sessions decode to the absent sentinels (#114).
- Optional dead-link heartbeat: set `heartbeat_interval_sec` to ping while
  connected and authenticated; a missing `pong` within `pong_timeout_sec`
  tears the link down as a failure, so auto-reconnect can engage on silent
  link death (NAT rebinding, radio loss). The same silence deadline covers
  the authentication window, where pings are not allowed. Off by default.
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
- `demo/main.tscn`: runnable demo scene (connect -> join -> game data -> leave)
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
