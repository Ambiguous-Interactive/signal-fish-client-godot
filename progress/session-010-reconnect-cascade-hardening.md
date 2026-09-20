# Session 010 - Reconnect Cascade + Handshake Hardening (issues #20, #21)

Date: 2026-09-20

## Scope

- One focused surface: reconnect/auto-reconnect correctness - the most
  gameplay-impacting open issues. Closes #20 (double-nested handler cascade
  could arm one retry past a consumer close) and #21 (three deferred
  reconnection hardening items).

## Drift check

- `main` up to date with `origin/main` (tip: PR #22, P2 binary game data);
  main CI green (LLM Harness + Runtime CI).
- No open PRs, no in-progress work to carry forward.
- Open issues: #20/#21 (correctness), #12/#13 (P2), #15 (P3 hygiene).

## What landed

- **Sticky close intent (#20)** - `_schedule_auto_reconnect` no longer
  consumes `_user_close_requested`: once a consumer closes from any handler
  in a termination cascade, every scheduling point in that cascade observes
  the close (the flag stays set until the next dial or cascade entry clears
  it). Double-nested cascades (redial from `disconnected`, close from that
  redial's `connection_failed`) can no longer arm a retry past the close,
  and no budgeted attempt is burned.
- **Refused-dial credential drop (#21.1)** - a scheme-refused dial (and
  every torn-down dial, via `_teardown_transport`) drops the pending
  `_reconnect_*` handshake credentials instead of leaving them resident
  until the next dial overwrites them; the token stays on the redaction
  list either way.
- **Once-per-dial handshake (#21.2)** - new `_reconnect_handshake_sent`
  guard (reset per dial in `_open_transport`): duplicate `Authenticated`
  server events can never resend the directed `Reconnect` handshake, and
  duplicates after the handshake stay fully consumer-silent (no session-
  state clobber, no `authenticated` emission on reconnect dials).
- **Failed handshake resolves the attempt (#21.3)** - a failed
  `_send_reconnect` (backpressure or send error) now resolves negatively
  via `_fail_reconnect_handshake`: dial credentials consumed,
  `reconnection_failed(reason, Code.NONE)` fires, and the link tears down
  through `_terminate_reconnection_attempt` (`disconnected(-1)`) when it is
  still up. With opt-in auto-reconnect the episode re-arms from the
  retained context instead of hanging authenticated-but-roomless. When the
  send error already killed the link, the transport-failure cascade surfaces
  `connection_failed` and the reconnection failure is context only.
- **Teardown closes the socket** - `_teardown_transport` now closes the
  transport after unwiring signals, so a dropped attempt never leaks a live
  socket (previously the server would pin the session until its own
  timeout; pre-existing on the server-`ReconnectionFailed` path, routine on
  the new backpressure path).
- Docs: stale `_start_auto_reconnect` scheduling comment corrected;
  `reconnection_failed` docblock documents `Code.NONE` for local failures.

## Tests

- `tests/client/run_reconnect_tests.gd`: four new tests, all verified
  red on pre-fix code and green after (empirical stash/mutation checks):
  `_test_double_nested_close_cascade_wins_over_retry` (no arm, no burned
  attempt, intent settles until the next dial),
  `_test_scheme_refused_reconnect_drops_dial_credentials` (creds dropped,
  token stays redacted), `_test_duplicate_authenticated_sends_handshake_once`
  (pre- and post-handshake duplicate phases),
  `_test_handshake_send_failure_resolves_attempt` (terminal resolution +
  auto-reconnect re-arm + torn-down socket actually closed).
- `_make_reconnect_client` gained a `track_errors` param (mirrors
  `_make_client`) so expected-error tests opt out of the shared tracker.

## Verification

- `bash scripts/run-runtime-checks.sh all` green (gdformat, gdlint,
  private-helpers guard, all five Godot suites) on Godot 4.3-stable.
- Two-round adversarial sub-agent review: round 1 found two P2s (terminal-
  shape divergence on real-transport send errors; live socket dropped
  unclosed) - both fixed; round 2 found no P1/P2 and confirmed red-green
  via mutation copies.

## Deferred (filed as follow-ups)

- Fake transport send failures do not emit `failed` (real
  `SFWebSocketTransport.send_text` does), so the real-transport
  handshake-send-error shape is documented rather than fake-tested.
- A torn-down real transport is never polled again, so its close frame may
  not flush gracefully before the RefCounted peer is reclaimed.
- Duplicate `Authenticated` on a normal (non-reconnect) dial still re-emits
  `authenticated` (flag only gates reconnect dials; hostile-server-only).

## Next-round surfaces

- Fixture re-pin (#12) or README (#13) per drift check priority.
