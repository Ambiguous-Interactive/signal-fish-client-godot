# Session 007 - P2 Reconnection + Replay (manual reconnect, auto-reconnect backoff)

Date: 2026-09-19

## Scope

- Advance PLAN.md's next milestone (P2 full protocol depth) with one coherent
  surface: reconnection + replay — `reconnect()`, `set_auto_reconnect()` with
  injected-clock backoff, server-issued `reconnection_token` capture, and the
  `.llm/skills/reconnection-replay.md` doc (a P2 checklist item).
- Resolve PLAN §13.1 (reconnect `auth_token` origin) against upstream source.

## Drift check

- `main` up to date with `origin/main` (tip: PR #18, P1 core client, CI green).
- No open/draft PRs. Open issues: #15 (P3 security checklist; items 1-3 done
  in session 006, 5-6 remain), #13 (P2 docs; root README landed in session
  006, fuller docs are a P4 surface), #12 (fixture re-pin + sync automation —
  recommended again as a next focused surface).

## Upstream verification (new pins)

- Cloned `signal-fish-server` @ `eaae1ca3` and `signal-fish-client-rust` @
  `fdab2e83`.
- Server `src/protocol/messages.rs`: `RoomJoinedPayload.reconnection_token` and
  `ReconnectedPayload.reconnection_token` (`Option<String>`).
- Rust `src/client_core.rs` `AutoReconnectContext`: retention is
  `{player_id, room_id, token}` refreshed by every player baseline; tokenless
  and spectator baselines clear it; auto-reconnect fires only when enabled,
  authenticated, and not in a room.
- This resolves the research doc's "auto-reconnect blocked until token
  issuance is pinned" open item (updated in place).

## What landed

- `addons/signal_fish/protocol/sf_types.gd` — `RoomJoinedInfo.reconnection_token`
  ("" sentinel for absent/null per the data rulings); covers `RoomJoined` and
  `Reconnected` baselines through the shared decoder path.
- `addons/signal_fish/signal_fish_client.gd` —
  - `reconnect(player_id, room_id, auth_token)`: fresh transport, `Reconnect`
    handshake on open instead of `Authenticate`; guards for unconfigured,
    active connection, empty args, missing endpoint; dial credentials are
    consumed on success.
  - `set_auto_reconnect(enabled)`: off by default. Retries only
    non-user-initiated closes; exponential backoff (base 0.5s, factor 2, cap
    15s, jitter 0.25) accumulated from `_process` delta (web-safe, no
    threads); budget `config.reconnect_max_attempts` (default 5), exhaustion
    emits `connection_failed` once; clean `close()` cancels a pending retry;
    terminal codes `RECONNECTION_TOKEN_INVALID`/`RECONNECTION_EXPIRED` clear
    the retained context and stop retrying; transport `failed` stays terminal.
  - Baseline context capture mirroring upstream: player baseline with token
    retains, tokenless/spectator baselines clear; captured tokens register
    with the redacting logger (`_secrets`).
  - Dial path factored into `_open_transport` shared by
    `connect_to_server`/`reconnect` (also clears a stale
    user-close-requested flag on fresh dials).
- `addons/signal_fish/signal_fish_config.gd` — `reconnect_max_attempts`
  (default 5) with validation; `validation_error` refactored to a data-driven
  cap table (gdlint max-returns).
- `tests/client/run_reconnect_tests.gd` — new focused runner (client runner
  was near the 1200-line gdlint cap): token decode table (string/absent/null/
  empty across `RoomJoined`/`Reconnected`), manual-reconnect guards +
  byte-exact wire assertions, baseline completion + rotated-token context,
  auto-reconnect eligibility table (off/never-joined/tokenless/token/clean
  close), spectator-baseline clearing, plan-locked `DELAY_BOUNDS` backoff
  table (attempts 1-6 incl. the 15s cap), terminal-vs-retryable
  `ReconnectionFailed` table, exhaustion → `connection_failed`, and token
  redaction. All timing via injected `_process(delta)`.
- `scripts/run-runtime-checks.sh` — runs the new suite in the cold-copy gate.
- `.llm/skills/reconnection-replay.md` — pinned upstream anchors, token
  lifecycle, manual/auto semantics, testing rules, open items.
- `.llm/research/protocol-fixtures.md` — token-origin open item resolved;
  vendored fixtures pre-date the field (decoder tolerates absence); re-pin
  remains issue #12.
- `PLAN.md` — P2 reconnection box checked with notes; §13.1 resolved; status
  header + P1 note updated.
- `gdlintrc` — comment updated for the now-26 public client methods.

## Deliberately deferred (next rounds)

- `send_game_data_binary()` + `sf_msgpack.gd` (opt-in MessagePack) + binary
  frame handling — the other P2 half; needs a binary-frame pass at the
  transport boundary and decode policy (`decode_msgpack_payloads`).
- Authority/spectator matrix depth per PLAN §8 (send surface + event decode
  exist since P1; the full table-driven depth does not).
- Issue #12 (fixture re-pin to current upstream + sync automation) — needs an
  upstream-sync design; fixtures now demonstrably lag one wire field.
- Issue #15 items 5-6 (gdUnit4 migration decision, Godot 4.4 matrix row).
- `missed_events` ordering/dedup pin (PLAN §13.2) before any replay
  niceties; close-code conventions (PLAN §13.8) before code-based retry
  decisions — recorded in the new skill doc's Open items.

## Verification

- `bash scripts/run-runtime-checks.sh all`: green (private-helpers, gdformat,
  gdlint, cold-copy protocol + transport + client + reconnect Godot tests).
- `pwsh -NoProfile -File scripts/generate-llm-index.ps1` +
  `scripts/agent-check.ps1`: green.
