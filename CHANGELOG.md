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

### Fixed

- Closing during the `opened` callback no longer risks a crash when a consumer
  handler fails the session synchronously.

### Added

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
