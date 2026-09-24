# Session 007 - P2 Reconnection + Replay (manual reconnect, auto-reconnect backoff)

Date: 2026-09-19

## Scope

- Advance PLAN.md's next milestone (P2 full protocol depth) with one coherent
  surface: reconnection + replay - `reconnect()`, `set_auto_reconnect()` with
  injected-clock backoff, server-issued `reconnection_token` capture, and the
  `.llm/skills/reconnection-replay.md` doc (a P2 checklist item).
- Resolve PLAN section 13.1 (reconnect `auth_token` origin) against upstream source.

## Drift check

- `main` up to date with `origin/main` (tip: PR #18, P1 core client, CI green).
- No open/draft PRs. Open issues: #15 (P3 security checklist; items 1-3 done
  in session 006, 5-6 remain), #13 (P2 docs; root README landed in session
  006, fuller docs are a P4 surface), #12 (fixture re-pin + sync automation - recommended again as a next focused surface).

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

- `addons/signal_fish/protocol/sf_types.gd` - `RoomJoinedInfo.reconnection_token`
  ("" sentinel for absent/null per the data rulings); covers `RoomJoined` and
  `Reconnected` baselines through the shared decoder path.
- `addons/signal_fish/signal_fish_client.gd`:
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
- `addons/signal_fish/signal_fish_config.gd` - `reconnect_max_attempts`
  (default 5) with validation; `validation_error` refactored to a data-driven
  cap table (gdlint max-returns).
- `tests/client/run_reconnect_tests.gd` - new focused runner (client runner
  was near the 1200-line gdlint cap): token decode table (string/absent/null/
  empty across `RoomJoined`/`Reconnected`), manual-reconnect guards +
  byte-exact wire assertions, baseline completion + rotated-token context,
  auto-reconnect eligibility table (off/never-joined/tokenless/token/clean
  close), spectator-baseline clearing, plan-locked `DELAY_BOUNDS` backoff
  table (attempts 1-6 incl. the 15s cap), terminal-vs-retryable
  `ReconnectionFailed` table, exhaustion -> `connection_failed`, and token
  redaction. All timing via injected `_process(delta)`.
- `scripts/run-runtime-checks.sh` - runs the new suite in the cold-copy gate.
- `.llm/skills/reconnection-replay.md` - pinned upstream anchors, token
  lifecycle, manual/auto semantics, testing rules, open items.
- `.llm/research/protocol-fixtures.md` - token-origin open item resolved;
  vendored fixtures pre-date the field (decoder tolerates absence); re-pin
  remains issue #12.
- `PLAN.md` - P2 reconnection box checked with notes; section 13.1 resolved; status
  header + P1 note updated.
- `gdlintrc` - comment updated for the now-26 public client methods.

## Deliberately deferred (next rounds)

- Double-nested handler cascade edge (round-4 reviewer note): a close from
  the `connection_failed` handler of a redial made inside a `disconnected`
  handler can still arm one retry - pre-existing, exotic, simple flavors are
  pinned by tests; revisit only if a real consumer hits it.
- `send_game_data_binary()` + `sf_msgpack.gd` (opt-in MessagePack) + binary
  frame handling - the other P2 half; needs a binary-frame pass at the
  transport boundary and decode policy (`decode_msgpack_payloads`).
- Authority/spectator matrix depth per PLAN section 8 (send surface + event decode
  exist since P1; the full table-driven depth does not).
- Issue #12 (fixture re-pin to current upstream + sync automation) - needs an
  upstream-sync design; fixtures now demonstrably lag one wire field.
- Issue #15 items 5-6 (gdUnit4 migration decision, Godot 4.4 matrix row).
- `missed_events` ordering/dedup pin (PLAN section 13.2) before any replay
  niceties; close-code conventions (PLAN section 13.8) before code-based retry
  decisions - recorded in the new skill doc's Open items.

## Adversarial review round

A zero-knowledge red-team review returned 0 P1 / 4 P2 / 8 P3. Dispositions:

- **P2 fixed - dead-dial liveness hole:** transport `failed` now schedules
  budgeted retries like a server-initiated close (a briefly-unreachable
  endpoint no longer kills the loop on the first retry); a user close during
  CONNECTING surfaces `failed` but consumes the user-close flag, so an abort
  mid-dial never retries. PLAN section 4.7 wording updated to "abnormal termination".
- **P2 fixed - burned-attempt race:** `_schedule_auto_reconnect` refuses to
  arm unless the client is CLOSED/FAILED, and `_open_transport` cancels any
  armed timer, so a consumer dialing from a `disconnected` handler can no
  longer burn a budgeted attempt.
- **P2 fixed - stranded after ReconnectionFailed:** the client now tears the
  link down itself after a rejected rejoin (`disconnected(-1, "reconnection
  failed")`), giving consumers a terminal disconnect and retryable
  auto-reconnects a clean scheduling point; terminal codes clear the context
  first so their schedule is a no-op.
- **P2 fixed - test gaps:** new tests for failed-dial retry, user abort
  mid-dial, `close()` cancelling a pending timer, budget reset after a
  successful baseline, plus a no-spurious-`protocol_error` sweep across the
  suite.
- **P3 fixed:** skill-doc PLAN checkbox ticked; "would   drop" typo; false
  `auto_poll` comment (config now sets `auto_poll = false`); reconnect doc
  documents `connected` firing for reconnect dials + scene-tree requirement;
  `set_auto_reconnect` doc documents exhaustion ordering; skill doc notes
  tokens ride in consumer-visible `raw`/`to_dict()` payloads.
- **Accepted/deferred:** white-box private-member access in tests (repo test
  style; the suite asserts behavior elsewhere); `_secrets` grows across token
  rotations (bounded by token issuance frequency; memory cost trivial).

## Adversarial re-review round (fix delta)

Re-review of the fix diff verified all four round-1 fixes and returned
0 P1 / 1 P2 / 3 P3. Dispositions:

- **P2 fixed - close-from-handler overridden:** a consumer `close()` from a
  `disconnected`/`connection_failed` handler ran after the user-close flag
  was snapshotted, so the scheduler armed a retry moments later. The
  scheduler now consults and consumes the flag first; pinned by
  `_test_close_from_disconnected_handler_wins_over_retry`.
- **P3 fixed - exhaustion docstring overclaim:** failure-driven exhaustion
  emits per-dial `connection_failed`s plus one final "exhausted" notice;
  docstrings/skill doc reworded and the failure-driven path is now pinned by
  `_test_failure_driven_exhaustion_and_budget_recovery` (3 emissions,
  final says "exhausted").
- **P3 fixed - budget poisoning across episodes:** the retry budget now
  resets on an authoritative baseline (`RoomJoined`/`Reconnected`), not on
  dial. The first attempt (reset in `_open_transport`) would have defeated
  exhaustion entirely - caught by the new test, root-caused, and fixed to
  reset only on baselines; recovery-from-exhaustion is pinned.
- **P3 fixed - protocol_error sweep scope:** trackers now accumulate per
  client (`_error_trackers`) so multi-client tests check every client.

## Adversarial re-review round 3 (fix delta)

Re-review of round 2's diff returned 0 P1 / 1 P2 / 2 P3. Dispositions:

- **P2 fixed - nested redial double-burn:** a consumer redial from a
  disconnect handler that fails synchronously scheduled inside the handler;
  the deferred outer schedule then armed a second attempt and overwrote the
  backoff delay. `_schedule_auto_reconnect` is now idempotent per cascade
  (early-out while the timer is armed); pinned by
  `_test_handler_redial_failure_burns_one_attempt`.
- **P3 fixed - exhaustion double-emit at the budget boundary:** the
  exhaustion branch now also drops the retained context, so no later event
  can re-enter scheduling; exhaustion terminates the episode cleanly and the
  budget restarts on the next fresh baseline (docstrings/skill doc updated).
- **P3 fixed - doc/behavior mismatch:** `set_auto_reconnect` docstring now
  states that failed dials - including consumer-initiated ones - are
  retryable while armed, and that exhaustion drops the token.
- **P3 fixed - test twins:** `_test_close_from_connection_failed_handler_
  wins_over_retry` pins the FAILED-handler close flavor.

## Adversarial re-review round 4 (fix delta)

Final verification pass of round 3's diff: **0 P1 / 0 P2 / 0 P3 - clean.**
All four fixes verified correct (idempotent scheduling invariant, exhaustion
termination with context cleared, doc accuracy, deterministic tests that
genuinely pin the fixes). One pre-existing double-nested-cascade edge (a
close from the `connection_failed` handler of a redial made inside a
`disconnected` handler can still arm; inner schedule consumes the flag) is
unchanged from before this session and deferred as out of scope.

## Verification

- `bash scripts/run-runtime-checks.sh all`: green (private-helpers, gdformat,
  gdlint, cold-copy protocol + transport + client + reconnect Godot tests).
- `pwsh -NoProfile -File scripts/generate-llm-index.ps1` +
  `scripts/agent-check.ps1`: green.
- PR #19: Protocol checks + Validate LLM context green; 4 adversarial review
  rounds, final round 0 findings.

## Follow-ups filed

- Issue #20: double-nested handler cascade edge (deferred from round 4;
  pre-existing, exotic, one extra budgeted attempt at worst).
