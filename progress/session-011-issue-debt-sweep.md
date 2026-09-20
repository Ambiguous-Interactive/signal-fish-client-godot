# Session 011 — Issue-Debt Sweep: Protocol Re-Pin, Transport Hardening, README, CI Cache

**Date:** 2026-09-20
**Branch:** `issue-debt-sweep` → PR to `main`
**Goal:** Address 3+ open issues (#24, #15, #13, #12), keep CI time flat-or-down, no coverage loss.

## What landed

### Issue #24 — transport follow-ups (all three items)

1. **Fake send-failure parity:** `SFFakeTransport` gained a `fail_on_send` knob that
   mirrors the real transport's synchronous send-failure cascade (`failed` emitted once,
   `ERR_CONNECTION_ERROR` returned, session dead; later sends get `ERR_UNCONFIGURED`).
   The client's reconnect-handshake "send killed the link" terminal shape
   (`connection_failed` cascade, no `disconnected(-1)`) is now fake-testable —
   `tests/client/run_reconnect_tests.gd::_test_handshake_send_failure_killing_link_cascades`.
2. **Teardown close-frame flush:** documented the deferred limitation on
   `_teardown_transport` (socket closed but never polled again; engine force-closes TCP
   on free; revisit only if a server-side half-open is observed).
3. **Duplicate `Authenticated` on normal dials:** added a once-per-dial
   `_authenticated_seen` guard (reset on every dial) covering all dials; duplicates no
   longer re-emit `authenticated` or re-set session state. Pinned by
   `run_client_tests.gd::_test_duplicate_authenticated_is_once_per_dial`; the reconnect
   handshake guard now sits inside the same gate.

Fake knob behavior pinned directly in
`tests/transport/run_transport_tests.gd::_test_fake_fail_on_send_mirrors_real_cascade`.

### Issue #12 — protocol drift (re-pin + sync automation + parity)

- **Re-pinned** fixtures and `.llm/research/protocol-fixtures.md` to the current
  upstream binding: server `v0.9.1` @ `24a5d10b9e1700cdbef24f05dfe7fe1f0719ac3d`,
  Rust SDK binding `0.14.0`, protocol authority `e1b65b96…` (synced 2026-09-18).
  Prior pins (2026-05-29) recorded as history in the fixture headers.
- **Upstream surface diff** (v2-route): wire bytes frozen upstream — all new surface
  (8 server events, 4 client messages, `password`, v3 negotiation fields, +21 error
  codes) is additive and v3-route/additive-only. No renames/removals; the v2 codec
  stays wire-compatible unchanged.
- **`allowed_symbols` parity closed:** upstream widened `Vec<char>` → `Vec<String>`;
  both serialize as JSON string arrays and the GDScript codec already treats entries
  as plain strings with no width assumption. Pinned by
  `_test_allowed_symbols_widen_parity` (one-char + multi-char shapes). UTF-8-byte
  `max/min_length` semantics documented (advisory pass-through, matching the Rust
  client).
- **Reconnection-token rotation modeled in fixtures:** `RoomJoined` carries a fake
  token and `Reconnected` a rotated one; the fixture decode test pins rotation.
- **Provenance recorded:** the four upstream wire-sample sha256 digests (verified
  live against the Rust repo's `tests/compatibility.toml`) are now written into
  `.llm/research/protocol-fixtures.md`, together with the rationale for keeping the
  Godot fixtures hand-built supersets of the elided upstream samples.
- **Sync automation:** `scripts/check-protocol-sync.py` (stdlib-only, `--self-test`
  which also structurally validates all local pin sites offline) compares the
  fixture-header + doc pins (all four fixture/doc files) against the Rust repo's
  `tests/compatibility.toml`; wired as `.github/workflows/protocol-sync.yml` —
  weekly cron + manual dispatch only, never on push/PR, so fast-gate CI time is
  untouched. The CI job runs `--self-test` before the networked check.

### Issue #13 — README

Root `README.md`: what this is, status + roadmap link, install, **authentication
primer** (`app_id` = public identifier; reconnection tokens = rotated server-issued
secrets; redacting-logger pointer), quick-start example for the client plus a
codec-only snippet, dev checks. Snippets verified to run against the shipped API.

### Issue #15 — decision hygiene (items 1–5 resolved; item 6 tracked in P5)

- Items 1–3 (frame cap, redacting logger, `ws://` mixed-content hard error) verified
  already implemented (`_on_transport_packet` cap before decode; `sf_log.gd`;
  `insecure_scheme_error` → `ERR_INVALID_PARAMETER`).
- Item 5: PLAN locked decision #4 rewritten — the test framework is the deterministic
  custom `SceneTree` runners, with rationale; gdUnit4 references reconciled in §4.1,
  §8, §9, P5.
- Item 6 (Godot 4.4.x matrix row) deferred **by design**: this session's constraint is
  no CI-time increase; the matrix is now the explicit remaining P5 item in PLAN (§9 +
  P5 checklist) to land before the API freeze.

### CI time (goal: flat or down)

- `ci.yml`: `actions/setup-python@v5` with pip cache keyed on `requirements-ci.txt`,
  and `actions/cache` for the Godot binary keyed by version (skips the ~50 MB
  download on cache hits). No coverage change; same single-job structure.

## Verification

- `bash scripts/run-runtime-checks.sh all` — green (private-helpers, format, lint,
  all 5 Godot suites).
- `pwsh scripts/agent-check.ps1` — green (incl. GitHub config validation for the new
  workflow).
- `python3 scripts/check-protocol-sync.py --self-test` + live check — green
  (4 pinned sources).
- README quick-start flow exercised headless against a fake transport — green
  (authenticate → join from `authenticated` handler → `room_joined` → game data).

## Adversarial review round

Red-team sub-agent review returned 2 P2 + 10 P3 findings; all P2s and the
meaningful P3s fixed:

- P2: README quick-start joined the room before `authenticated` (would fail with
  `ERR_UNAUTHORIZED` on copy-paste) → snippet restructured to join from the
  `authenticated` handler; verified end-to-end headless.
- P2: #12 provenance narrated but digests not recorded → the four wire-sample
  sha256 digests recorded in `protocol-fixtures.md`.
- P3 batch: sync checker now covers `malformed.jsonl` (4 pinned sources), catches
  non-UTF-8 responses, self-test structurally validates the real pin sites;
  fake-transport `_fail_send` docstring no longer overstates return-code parity;
  duplicate-auth test extended to the in-room state-clobber case; transport test
  pins `get_buffered_amount() == 0` post-failure; ci.yml sanity-checks the restored
  Godot binary; workflow notes the schedule-inactivity caveat and runs the
  self-test in CI; README "~40 error codes"/P5-status wording aligned with PLAN.

Deliberately not fixed (noted by review): the defensive
`elif _connection_state == ConnectionState.CONNECTED` in the authenticated
handshake path is provably dead but harmless and pre-existing; PLAN P4/P5
web-export-smoke wording ambiguity is pre-existing and both readings are true
(manual checklist vs CI job).

## Follow-ups / new issues

- v0.9.1 surface gaps surfaced by the re-pin diff (filed as follow-up issue):
  error-code table extension to the 62-code upstream surface incl. `category()`
  re-derivation; `StartGame` + `password` builders (v2-relevant); v3-route surface
  (new messages/decoders) stays gated until v3 dials are a product decision.
- Godot 4.4.x matrix row (issue #15 item 6) — PLAN P5, before API freeze.

## Issue outcomes

- #24: fixed (1,3) + documented (2) → close via PR.
- #15: items 1–5 resolved, item 6 tracked in PLAN P5 → close via PR with mapping.
- #13: README shipped → close via PR.
- #12: re-pin + sync automation + parity closed → close via PR.
