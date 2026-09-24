# Session 017 - Issue-Debt Sweep: Perf, TOCTOU, SSOT

**Date:** 2026-09-20
**Branch:** `quality/issue-debt-perf-toctou-ssot` -> PR to `main`
**Goal:** Close the three open issues (#36 perf, #39 TOCTOU, #40 SSOT) with a
single low-risk sweep. CI time unchanged (no new steps; no workflow edits);
test coverage unchanged (same suites, same `_test_` counts, fixture shapes
proven byte-identical).

## Drift check

Main green (Runtime CI ~34s, LLM Harness green), no open PRs, tree clean,
branch cut from `origin/main` at `f9a171f`.

## What landed

### #36 perf - zero steady-state allocations on addon paths

- `sf_webrtc_mesh.gd`: `poll()` early-exits when no peers exist (was: two
  `.keys()` Array allocations per frame at idle - the only steady-state
  allocator in the addon, >=120 allocs/sec at 60 fps). Peer count reporting
  iterates the dictionary directly (no copy; no mutation inside).
- `sf_msgpack.gd`: signed-int width table hoisted from a per-value dict
  literal to a `const` (negative ints are common in game-state payloads).
- `sf_binary_frames.gd`: known-field and required-field array literals per
  envelope became `const` tables (<=6 array allocs per frame removed).
- `signal_fish_client.gd` `_handle_binary_frame`: repeated Variant lookups
  (`encoding`/`from_player`/`payload`) hoisted into typed locals on the
  hottest receive path.
- Audit confirmed the WS idle poll path, event dispatch (`match` on
  StringName), send path, and log guards were already clean; untouched.

### #39 TOCTOU - check/use gaps closed

- `sf_websocket_transport.gd` `close()`: re-checks `_peer`/`_is_terminal()`
  after the synchronous `opened` emit (a consumer handler can fail the
  session re-entrantly and null the peer before the close frame is queued).
  Same discipline `_drain_packets` already applies; strictly a crash fix.
- `scripts/run-runtime-checks.sh`: venv activation checks the
  `.venv-ci/bin/activate` file, not the directory (a partial venv no longer
  hard-dies under `set -e`); broken venv emits a warning and falls back.
- `scripts/dependabot-auto-merge.sh`: check-run snapshot selects by
  `run_started_at` (re-run attempts keep the original `created_at`, so the
  old sort could bless a stale success while a failing re-run was in
  progress). Merge-failure path tolerates a racing workflow_run that already
  merged the same head SHA (`state == MERGED && headRefOid == HEAD_SHA`),
  instead of turning the duplicate trigger red.

### #40 SSOT - drift-prone duplication collapsed

- Depth cap `16` now defined once (`SFTypeUtils.MAX_MESSAGE_DEPTH`);
  `SFEvents.MAX_MESSAGE_DEPTH`, `SFMsgpack.MAX_DEPTH`, and the anonymous cap
  in `SFMessages._is_json_value_depth` all reference it. Public const names
  and the 16 value are preserved (tests keep passing unchanged).
- `signal_fish_client.gd`: `_clear_reconnect_credentials()` replaces six
  copy-pasted credential-clear triplets (a missed site would replay a stale
  token on the next dial).
- `run_binary_tests.gd` / `run_reconnect_tests.gd`: inline fixture builders
  (`authenticated_data`/`room_joined_data`/`protocol_info`/`player`) and
  UUID consts replaced with `ClientFixtures` delegation + override merging.
  Adversarially verified byte-identical output (values and key order) for
  default, overridden, and adversarial calls.

## Issue debt

- **#36, #39, #40 closed** with evidence comments; residuals that are real
  but deferred opened as targeted follow-ups (#45 per-message allocations,
  #46 SSOT/TOCTOU residuals) so the debt is tracked, not lost.

## Verification

- `bash scripts/run-runtime-checks.sh all` green (private-helpers + format +
  lint + all 5 suites, cold-copy Godot 4.3).
- `python3 scripts/validate-github-config.py --repo-root .` green (auto-merge
  script still satisfies every required safety token).
- `pwsh scripts/agent-check.ps1` green; `bash -n` on both edited scripts.
- Adversarial sub-agent review: no P1/P2. P3 nits fixed (jq indentation,
  merge-identity pinned to `headRefOid` - `mergeCommit.oid` would be wrong
  under squash, broken-venv warning). One false-positive jq syntax construct
  caught by `bash -n` and fixed.
- Fixtures untouched; `_test_` counts unchanged; no workflow edits (CI time
  flat).

## Left for later

- #45 (perf): msgpack per-node result dicts, `DecodedEvent.raw`/roster deep
  copies, per-frame UUID string cache, `missed_events` lookup hoists.
- #46 (SSOT/TOCTOU): SFTypes token->enum match copies, scattered
  `_is_integral_number` re-implementations, Godot version pin drift guard
  (ci.yml vs devcontainer vs project.godot), preflight vanished-file
  tolerance, session-reset peer flush (documented, issue #24).
- PLAN P4 demo, P5 matrix + web-export smoke, P6 remainder.
