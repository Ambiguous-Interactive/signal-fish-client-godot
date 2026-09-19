# Session 006 - P1 Core Client (config + client + fake-transport tests)

Date: 2026-09-19

## Scope

- Advance PLAN.md's next milestone: finish P1 by landing `signal_fish_config.gd`,
  `signal_fish_client.gd` (both state machines, guarded send surface, auto-auth,
  poll driver, backpressure, cleanup), and a full fake-transport client test
  suite wired into `scripts/run-runtime-checks.sh`.
- Bake in the gameplay-impacting open issues along the way: #14 (credential
  slot) and #15 items 1-3 (frame cap, redacting logger, ws:// hard error).
- Minimal root README (issue #13) so a public repo headed to the Asset Library
  has install + auth-primer docs before P4.

## Drift check

- `main` was up to date with `origin/main` (tip: PR #6, merged this morning).
- No open/draft PRs; issue #11 was already fixed in session 005.
- Stale local branches (`dev/wallstop/*`, `feat/devcontainer-agent-clis`) are
  all content-merged into `main` via squash merges (`plan-2` has an empty diff
  vs `main`); nothing to carry forward.

## What landed

- `addons/signal_fish/signal_fish_config.gd` — `SignalFishConfig` Resource:
  `app_id` + optional `sdk_version`/`platform`/`game_data_format`,
  `endpoint_url`, `auto_poll`, frame/buffer/packet caps, and the `credential`
  slot (#14) stored via `@export_storage`, excluded from `_to_string()`, and
  fed to the redacting logger.
- `addons/signal_fish/signal_fish_client.gd` — `SignalFishClient` Node:
  - 28 signals (1:1 with decoded events + lifecycle), ConnectionState and
    server-driven SessionState machines.
  - Auto-Authenticate on transport open; `JoinRoomParams`; guarded send
    surface (pre-auth -> `protocol_error` + `ERR_UNAUTHORIZED`, sends
    nothing); backpressure -> `ERR_BUSY` + `protocol_error`; cleanup on
    close/failure resets session and releases the transport.
  - Frame-size cap before decode (#15.1): oversized frames are dropped with
    `protocol_error`, the connection stays up.
  - `ws://` from a secure web page -> loud `ERR_INVALID_PARAMETER` (#15.3,
    R2); pure static helper `insecure_scheme_error` is data-driven tested.
  - API deviation: `is_connected()` -> `is_connected_to_server()`; Godot 4
    `Object.is_connected(signal, callable)` cannot be shadowed. Noted in
    PLAN.md P1.
- `addons/signal_fish/protocol/sf_log.gd` (#15.2) — leveled logger with
  secret redaction; default level WARN keeps test output clean.
- `tests/client/run_client_tests.gd` — 16 test functions covering configure
  validation, connect guards, authenticate wire bytes (optionals omitted),
  pre-auth guard data-driven across all 9 send methods, authenticated send
  surface (byte-exact vs builders), room lifecycle (waiting -> lobby ->
  finalized, GameStarting no-op on state), presence/data/spectator events,
  Reconnected state restore, backpressure, close/failure cleanup, frame cap,
  mixed-content guard table, log redaction, config `_to_string` hygiene.
- `scripts/run-runtime-checks.sh` — runs the new client suite in the cold-copy
  Godot gate.
- `README.md` (#13) — what/install/auth primer/status, aligned with PLAN.
- `gdlintrc` — `max-public-methods: 30` with a comment: the PLAN §4.2 client
  API (15 accessors + 10 sends) intentionally exceeds the default 20.
- `PLAN.md` — P1 boxes checked with notes; status header updated.

## Deliberately deferred (next round)

- P2 protocol depth: authority/spectator test depth is event-surface level
  here (full P2 matrix), manual `reconnect()` + auto-reconnect with backoff,
  MessagePack `sf_msgpack.gd`, `.llm/skills/reconnection-replay.md`.
- Issue #12 (fixture re-pin to server v0.8.0 + sync automation) — needs
  upstream fetching; recommend as the next focused surface.
- Issue #15 items 5-6 (gdUnit4 migration decision, Godot 4.4 matrix row).

## Adversarial review round

A zero-knowledge red-team sub-agent reviewed the diff (all claimed items
DONE/CHANGED-with-note, none NOT-DONE). Findings and dispositions:

- **Fixed:** `game_data_format` no longer accepts `message_pack`/`rkyv` until
  P2 — the P1 client drops binary frames, so negotiating them would silently
  lose game data; `validation_error()` now rejects them loudly.
- **Fixed:** `credential` is a plain (non-`@export`) var — the reviewer proved
  `@export_storage` still serializes to `.tres` on save; a plain var makes
  "never serialized" literally true.
- **Fixed:** added `_test_process_and_exit_tree_paths` (auto-poll drives the
  transport via a poll-counting fake; `_exit_tree` tears down to CLOSED with
  the transport released).
- **Fixed:** close surfacing is data-driven across `(1000, "bye")` and the
  abnormal `(-1, "")` case (PLAN §8 matrix row).
- **Fixed:** `_apply_spectator_info` now records the validated
  `SpectatorJoinedInfo.lobby_state` (was left stale/UNKNOWN while SPECTATING).
- **Fixed (docs):** `reconnected` signal documents the `protocol_error`
  sentinels inside `missed_events`; `SFTransport.connect_to_url` documents the
  "non-OK return must emit `failed` synchronously" contract; PLAN P1 notes
  name the P2-deferred methods (`reconnect`, `set_auto_reconnect`,
  `send_game_data_binary`); `gdlintrc` comment corrected to 9 send methods.
- **Accepted as-is:** log-gate test asserts only no-crash (static logger;
  `redact()` itself is table-tested).

## Bugbot round (PR #18)

Bugbot's 3 findings were all confirmed real and fixed with regression tests:

1. High: `_on_transport_opened` now guards on non-CONNECTING states both
   before and after `connected.emit()` — a `connected` handler that closes
   the client synchronously no longer attempts authenticate against a
   torn-down transport (`_send_envelope` also gained a null-transport guard).
2. Medium: room/spectator rosters are duplicated in `_apply_room_info`/
   `_apply_spectator_info`, so emitted `room_joined`/`reconnected`/
   `spectator_joined` payloads never mutate from later presence updates.
3. Medium: `lobby_state_changed` keeps `SPECTATING` sessions spectating
   (spectators receive lobby updates; only players map lobby state onto
   in-room session states).

While verifying, a GDScript lambda-capture bug surfaced in the new
payload-stability test (lambdas capture locals by value; a reassigned capture
variable aborted the test mid-way and leaked its client) — fixed with a
mutable holder array; the suite now exits with zero leaked instances and zero
script errors.

CI green on the fix commit (Protocol checks, LLM context, Bugbot).

## Verification

- `bash scripts/run-runtime-checks.sh all`: green (private-helpers, gdformat,
  gdlint, cold-copy protocol + transport + client Godot tests).
- `pwsh -NoProfile -File scripts/agent-check.ps1`: green.
