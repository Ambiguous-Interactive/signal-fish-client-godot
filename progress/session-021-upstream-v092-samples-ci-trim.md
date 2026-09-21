# Session 021 — Upstream v0.9.2 Spec Samples, CI Trim

**Date:** 2026-09-21
**Branch:** `chore/upstream-v092-samples` → PR to `main`
**Goal:** Close issue #55 (adopt the new signalfish server spec), keep fast-gate
CI wall clock decreasing without touching coverage, and keep PLAN current.

## Drift check

Main green (Runtime CI 31s wall, all legs green), tree clean at `ddcb4a8`,
no draft PRs. One open issue: #55 ("Adopt new signalfish server spec",
published ~90 minutes before the session). Goal's "2+ open issues" could
not be met literally — only #55 was open; the remainder of the session
drove PLAN/CI debt instead.

## Upstream v0.9.2 RCA

Server `v0.9.1...v0.9.2`: dependency bumps, a server-internal bus-loopback
exclusion fix, and — the part clients care about — upstream PRs #612/#613
replacing the elided `"..."` v2 wire samples with **concrete, complete,
round-trip-guarded frames**. No protocol surface changed (`messages.rs`/
`types.rs`/`error_codes.rs` untouched), so the codec pin stays at the
v0.9.1 wire commit `24a5d10` — which is also what the rust binding's
`tests/compatibility.toml` still pins, keeping the weekly
`protocol-sync.yml` drift check meaningful instead of red.

## What landed

### Issue #55 — concrete upstream samples vendored + pinned

- `tests/fixtures/upstream/v2_{client,server}_messages.jsonl`: byte-exact
  copies of the upstream v0.9.2 sample corpus with provenance headers
  (repo, tag+SHA, upstream sha256). Upstream tokens are placeholders.
- `tests/protocol/upstream_samples_tests.gd` (data-driven): every server
  sample line must decode; all 23 text-envelope v2 server events must be
  represented (upstream states `GameDataBinary` has no `{type, data}` JSON
  form); published shapes that constrain the codec are pinned by name —
  `relay_type: "matchbox"` verbatim pass-through, `AuthorityResponse`
  `reason: null` → `""`, `GameStarting` peer without `connection_info`
  → `null`, always-serialized `ready_players`, both `Error` samples, and
  every client sample line must name a known `ClientMessage` type.
  Upstream adding/renaming a wire type now fails here by name.
- Verified with zero production-code changes: the codec already accepted
  every published v0.9.2 shape.
- `.llm/research/protocol-fixtures.md`: v0.9.2 refresh recorded (single
  codec pin preserved for the sync checker; sample digests listed);
  PLAN §3 warning about elided samples replaced with the new reality.

### CI wall-clock decrease (coverage unchanged)

Previous wall clock: ~31s, static job critical path (~26s of it).

- `ci.yml` static job: `.venv-ci` cached via `actions/cache`, keyed on the
  resolved Python version + `requirements-ci.txt` hash; the uv install
  steps only run on a miss (~8-10s saved on every hit).
- `ci.yml` test legs: apt step now skips entirely when `dpkg` confirms the
  three headless-Godot libraries are already on the runner image; falls
  back to the previous install path otherwise (no new failure mode).
- `run-runtime-checks.sh`: `gdformat --check` and `gdlint` run
  concurrently in `run_static` (independent tools); output is reported
  verbatim per tool. ~3.5s saved per static run, locally and in CI.
- Local `run_static`: 9.6s → 5.6s. Target CI wall: ~20s or lower.

## Verification

- `run-runtime-checks.sh all` green (protocol incl. the new suite,
  transport, client, binary, reconnect).
- `check-protocol-sync.py --self-test` green (single-pin structural check).
- `validate-github-config.py --self-test` + repo validation green.
- `agent-check.ps1` green after the `.llm` edit; index regenerated.

## PR outcome (#56)

- All checks green on both runs (Runtime CI legs + LLM Harness + Cursor
  Bugbot).
- CI wall clock: ~31s → ~16s, coverage unchanged (one suite added).
  Verified mechanisms on real runs: `Install GDScript tooling: skipped`
  on the venv-cache hit path; test legs dropped 18-21s → 7-13s via the
  dpkg skip (the three libraries ship on the ubuntu-24.04 runner image);
  static parallel format+lint verified red-propagating in a sandbox.
- Adversarial loop: round 1 (zero-knowledge red team) returned zero
  P1/P2 + five P3 nits; four accepted and fixed (PackedStringArray
  annotation, mktemp trap cleanup, doc wording, single-line cache key),
  one declined per "simplify aggressively" (dpkg-query Status hardening —
  the failure mode is loud one step later). Round-2 re-review of the
  delta: all four DONE, zero remaining findings.

## Leftovers / follow-ups

- Watch the first CI runs: venv-cache hit path and dpkg-skip path both
  need one green run each to confirm the savings.
- When the rust binding bumps its `compatibility.toml` past v0.9.1, the
  weekly sync check will fail by design → re-pin then (ritual in #12).
- PLAN leftovers unchanged: headless WebSocketPeer smoke (network-gated),
  browser-export manual checklist, demo P2P scene, `plugin.cfg`/`icon.png`.
