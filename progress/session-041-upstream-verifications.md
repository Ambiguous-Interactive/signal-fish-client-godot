# Session 041 — Upstream verification sweep + kicked-close policy

Date: 2026-09-23 · Branch: `session-041-upstream-verifications` · Base:
`origin/main` @ `a4c12de`

## What and why

PLAN's "Open upstream verifications" list gated correctness work. We pulled
the upstream server source (`main` @ `272cfa0c`, 2026-09-23) and diffed its
wire truth against our codec.

## Verified clean (no code change needed)

- `RoomJoinedPayload` / `ReconnectedPayload` / `SpectatorJoinedPayload`:
  snake_case fields (no `rename_all`), PascalCase tags; our required/optional
  key sets match exactly; `missed_events` is mandatory even when empty.
- `missed_events` semantics: oldest→newest, no wire sequence numbers (server
  counter is internal), control events only, `GameData` never replayed,
  server filters the reconnector's own deltas. Our verbatim order-preserving
  replay is correct; wire dedup is impossible.
- `error_code` matrix: mandatory only on `AuthenticationError` and
  `ReconnectionFailed`; `Option`+skip (key absent) on `RoomJoinFailed`,
  `AuthorityResponse`, `SpectatorJoinFailed`, `Error`. Our `Code.NONE`
  sentinel matches.
- `ConnectionInfo`: tags `direct|unity_relay|relay|webrtc|custom` and field
  sets match; `webrtc.sdp` serializes `null` upstream, omission decodes the
  same (serde `Option` default).
- `Ping`: upstream canonical form is bare `{"type":"Ping"}` — byte-pinned in
  our fixtures already.
- Error-code enum: full upstream list present in `SFErrorCodes.Code`.

Facts pinned in `.llm/skills/signal-fish-protocol.md` and
`.llm/skills/reconnection-replay.md`.

## Fix: close code 4007 (kicked) now ends the episode

Upstream `CloseReason::Kicked` → WS close `4007` removes the reconnection
record ("kick implies no reconnection"), but our client retried every close
code: kicked players burned the full retry budget on a doomed loop.

- `SignalFishClient` now treats `4007` as terminal: no retry armed, retained
  identity cleared (also supersedes an armed timer). All other codes keep the
  retry rule. Docs: `docs/reconnection.md`.
- Data-driven test `_test_kicked_close_code_ends_the_episode` covers
  `4007` (no retry) vs `4000`/`1009`/`4999` (retry). Red-green verified.

## Left open

- Cloud error-code drift: `signal-fish-cloud` is private (404); the
  `DATABASE_ERROR` alias ships; completeness re-check blocked on access.
- v3 gap recovery: `Reconnected.replay` (`ReplayStatus`) and
  `sender_watermarks` are raw-only today; issue #114 opened before any
  `DeliveryReport` work.

## Adversarial review outcome

Review confirmed the 4007 policy but caught a real ordering bug: cancelling
after `disconnected.emit` wiped the identity a consumer handler had just
re-captured via a redial (issue #73 contract). Fix: cancel before the emit,
mirroring the terminal-`ReconnectionFailed` path. Also: `1009` row added to
the close-code data table, a regression test pins the fresh-identity rule,
the stale research bullet on close codes was resolved inline, and the close
pins gained their source path.

## Checks

- `tests/client/run_reconnect_tests.gd` green (local Godot 4.3).
- Full gates run before PR: `run-runtime-checks.sh all`, agent-check,
  validate-github-config.
