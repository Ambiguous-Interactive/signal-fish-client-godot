# Session 018 — Perf Allocations, SSOT Residuals, Pin Drift Guard

**Date:** 2026-09-21
**Branch:** `quality/perf-allocs-ssot-residuals` → PR to `main`
**Goal:** Close the two open issues (#45 per-message allocations, #46
SSOT/TOCTOU residuals). CI time does not increase; aggregate CI usage
decreases (superseded PR runs are now canceled). Test coverage unchanged
(same suites, same `_test_` counts).

## Drift check

Main green (Runtime CI + LLM Harness), no open PRs, tree clean, branch cut
from `origin/main` at `505d7bc`.

## What landed

### #45 perf — hot-path allocations (items 1, 3, 4)

- `sf_msgpack.gd`: recursive decode no longer builds a result dict per
  decoded node (a large payload previously allocated ~M `{ok, value,
  error}` dicts). `_decode_value` and its helpers return plain `Variant`s
  and thread a per-call one-element failure slot down the recursion (one
  array per `decode()` call, zero per node; decode stays reentrant). Public
  `decode()`/`encode()` contracts unchanged.
- `sf_binary_frames.gd`: canonical UUID strings are cached (bounded at 256,
  cleared when full so a hostile peer cannot grow it without limit) —
  repeat senders stop paying the hex/substr/format per frame.
- `sf_events.gd`: `_decode_reconnected` hoists `data["missed_events"]` out
  of the per-element loop and the repeated size checks;
  `_decode_lobby_state_changed` hoists `data["ready_players"]` out of its
  validate/convert passes.

Deferred: `DecodedEvent.raw`/`RoomJoinedInfo` deep-copy removal (item 2) —
needs a public-API compat decision (aliasing across `missed_events`
sub-events is observable); split into a follow-up issue.

### #46 SSOT — drift-prone duplication collapsed

- `sf_types.gd`: the `LobbyState` `match` copies inside `RoomJoinedInfo`
  and `SpectatorJoinedInfo`, and the `GameDataEncoding` `match` copy inside
  `ProtocolInfo`, now read the outer token tables (via `TypeUtils.enum_value`
  / `GAME_DATA_ENCODING_FROM_STRING`) — a new token can no longer decode as
  `UNKNOWN` in a forgotten copy. Godot 4.3 lesson: inner classes can reach
  outer **consts** (incl. preloaded-script consts) but **not** outer static
  functions (parse error: "not found in base self"), so the tables are the
  SSOT seam.
- `_is_integral_number` re-implementations deleted from `sf_types.gd` and
  `sf_messages.gd`; `sf_session_types.gd`'s inlined typeof+floor logic now
  calls `SFTypeUtils.is_integral_number`.

### #46 TOCTOU — preflight vanished-file tolerance

- `scripts/preflight.ps1`: a toolkit file deleted between the existence
  gate and the parse, or between the parse and the recovery-backup read, is
  skipped (like tracked-but-deleted) instead of reported as fatal
  corruption.

### #46 SSOT — Godot version pin drift guard

- `scripts/validate-github-config.py`: `project.godot`
  `config/features` is now the single source for the Godot version; the
  guard fails CI when `ci.yml`, `devcontainer.json`, or the `Dockerfile`
  ARGs drift from it (e.g. a bump that leaves one site behind). Self-test
  covers consistent, drifted, and unreadable pins. Runs inside the existing
  LLM Harness step — zero new CI steps.

### CI usage decrease (coverage unchanged)

- `.github/workflows/ci.yml`: concurrency group cancels superseded
  `pull_request` runs; `push` runs on main are never canceled (merge
  checks depend on them). Per-run wall time and coverage unchanged.
- `llm-harness.yml` untouched (PLAN §5 hard constraint).

## Intentionally not done (tracked, do not re-file)

- `DecodedEvent.raw` deep-copy removal: needs a compat decision — follow-up
  issue opened.
- Session-reset peer flush (`_close_peer_for_session_reset`): documented at
  the reconnect dial path, tracked under #24.
- `release.yml` duplicate-release TOCTOU: failure direction is loud refusal;
  cosmetic only.

## Verification

- `bash scripts/run-runtime-checks.sh all` green (private-helpers + format +
  lint + all 5 suites, cold-copy Godot 4.3).
- `pwsh scripts/run-llm-hooks.ps1 -Mode Full` green (preflight, github-config
  incl. the new pin guard, generated index, 113 harness self-tests);
  `agent-check.ps1` green.
- `python3 scripts/validate-github-config.py --self-test` and `--repo-root .`
  green.
- Fixtures untouched; `_test_` counts unchanged; no new workflow steps.

## Left for later

- `DecodedEvent.raw` aliasing compat decision (follow-up issue).
- PLAN P4 demo, P5 matrix + web-export smoke, P6 remainder.
