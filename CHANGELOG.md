# Changelog

User-facing changes only. Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Versioning: [SemVer](https://semver.org/) — `vMAJOR.MINOR.PATCH`, pre-1.0 while the API stabilizes.
CI, tests, and internal tooling are not listed.

## [Unreleased]

### Added

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
