# Changelog

User-facing changes only. Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Versioning: [SemVer](https://semver.org/) - `vMAJOR.MINOR.PATCH`, pre-1.0 while the API stabilizes.
CI, tests, and internal tooling are not listed.
List new features under Added. Use Changed and Fixed for differences from a
released version.

## [Unreleased]

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
