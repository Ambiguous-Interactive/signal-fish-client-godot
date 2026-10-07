# Changelog

User-facing changes only. Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Versioning: [SemVer](https://semver.org/) - `vMAJOR.MINOR.PATCH`, pre-1.0 while the API stabilizes.
CI, tests, and internal tooling are not listed.
List new features under Added. Use Changed and Fixed for differences from a
released version.

## [Unreleased]

### Added

- Optional `SFSteamIdentityBootstrap`: puts Steam P2P relay traffic on a
  Signal Fish room. The room is the membership fence; the bootstrap exchanges
  role-scoped SteamId64s on the game-data lane, fences the host's Steam
  accepts behind that exchange, and hands established sessions to the game.
  Requires the GodotSteam GDExtension; the relay-only client stays unchanged.
- Three new v3 signals: `going_away` (graceful server-drain advisory),
  `delivery_report` (per-class delivery counters plus omission gaps), and
  `room_operation_result` (surfaced verbatim). All are informational; the
  client never acts on them.

## [v0.1.1] - 2026-10-01

### Changed

- Sharper Asset Library description with a link to
  [signalfish.network](https://signalfish.network).
- README and docs mention the hosted service next to the self-hosted server
  and link the live Asset Library listing.

## [v0.1.0] - 2026-09-27

### Added

- Pure-GDScript Signal Fish client for Godot 4, including connection,
  authentication, rooms, game data, authority, spectators, and reconnection
  with missed-event replay.
- Typed client methods, signals, and payloads for protocol v2 and v3. Game
  data supports JSON and MessagePack; binary frames are available as bytes.
- Optional auto-reconnect, dead-link heartbeat, and WebRTC peer mesh.
- Configurable frame-size and send-backpressure limits, with logging that
  redacts credentials and other secrets.
- Runnable demos for room messaging and WebRTC peer chat, plus a Web export
  preset.
- Godot editor plugin and Asset Library package.
- Documentation site with a quick start, API reference, guides, and release
  instructions.
