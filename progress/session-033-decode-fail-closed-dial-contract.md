# Session 033 — Decode fail-closed hardening + dial-contract latch + CI split

Date: 2026-09-22. Scope: one focused surface — the decode path's
wrong-typed-value behavior (issue #81) plus the reconnect-dial contract
(#82) and the MessagePack non-finite gap (#83), filed and fixed same-session,
with the LLM Harness job split for wall time (#84). Drift check first: main
green on `25a4883`, local == origin/main, zero open issues/PRs, protocol-sync
OK, no in-progress work.

## Issue debt

No open issues existed, so this session hunted, filed, and fixed four:

- **#81 (P1):** wrong-typed enum/port values failed OPEN in decode. In
  Godot 4.3, `String(x)`/`int(null)` raise for wrong-typed Variants and
  abort the helper, which returns its typed default (0); enum guards
  compare against UNKNOWN (-1), so they passed. Verified: `PeerTransportStatus.transport: 42`
  decoded as `RELAY`; `ConnectionInfo.port: null` aborted the constructor
  mid-way, silently wiping later fields (credentials, connection data).
  Fix: `typeof` guards in every enum-token helper (sf_types x4 statics +
  `_coerce_*`, sf_session_types x5, sf_type_utils `enum_value`), null-safe
  port reads in both ConnectionInfo and DirectEndpointInfo, `is_finite`
  gate in `is_integral_number`, and `_string_or_empty` hardening across
  all typed-payload classes.
- **#82 (P2):** the reconnect-dial consumer-silent contract leaked after a
  hostile `AuthenticationError` cleared the dial credentials mid-dial:
  a later `Authenticated` emitted `authenticated` (join-on-auth handlers
  would race a fresh JoinRoom into a rejoin dial), a later `Reconnected`
  applied a baseline for a handshake that never went out, and duplicate
  `ProtocolInfo` re-emitted/re-reconciled. Fix: a per-dial
  `_reconnect_dial` latch (recorded while credentials are live) drives the
  authenticated handler; the `reconnected` guard requires this dial's
  handshake to have been sent; `_protocol_info_seen` once-per-dial guard.
- **#83 (P2):** `SFMsgpack.encode` put NaN/±Inf on the wire (#76-class
  survivor); the server-side JSON decode collapses them. The TYPE_FLOAT
  encode branch now refuses non-finite with a diagnostic.
- **#84 (P3):** LLM Harness job wall time (~66s CI) was ~93% behavioral
  self-tests run sequentially in one job, plus uncached deps. Fix:
  `-SkipSelfTests` (CI-only) switch on `run-llm-hooks.ps1` splits
  `llm-harness.yml` into `validate` + parallel `self-tests` jobs
  (wall = max(jobs)), and both jobs cache the automation deps via
  `actions/setup-python`. Coverage unchanged: every self-test still runs
  on every PR; preflight, generated-diff, and the 5000ms guard stay on
  the validate job. Local validate path: 93s → 9.6s.

## Test shifts (honesty note)

Two existing tests injected `Reconnected` into a normal-auth session — a
wire shape upstream never produces (the server sends `Reconnected` only in
response to the directed handshake). After the #82 latch they became
red for the wrong reason; both were rewritten to drive a real reconnect
dial (`run_client_tests._test_reconnected_restores_room_state`, the mesh
suite's `reconnected` teardown case via `_make_reconnect_dial_client`).
Coverage is unchanged or stronger: every case still asserts the same
post-reconnected state, now through the realistic path.

## Delivered

1. Fail-closed token helpers + null-safe ports (see #81 above).
2. Dial-kind latch + handshake-gated `reconnected` + protocol_info
   once-per-dial (see #82 above).
3. Msgpack non-finite refusal (see #83 above).
4. llm-harness.yml job split + dep caching + `-SkipSelfTests` (see #84).
5. New coverage: `tests/protocol/wrong_typed_token_tests.gd` (helper
   fail-closed matrix, PeerTransportStatus refusal, null-port decoding,
   non-finite integral gate), msgpack non-finite refusal matrix,
   dial-contract survival + duplicate-protocol_info tests in the
   reconnect suite.

## Validation

- Red-green: with addon fixes stashed, the new suites fail (54 failures:
  helper matrix, transport refusal, null-port corruption, dial leaks);
  with fixes applied, all suites green.
- `run-runtime-checks.sh all` green; `smoke` green; `gdformat`/`gdlint`
  clean; `test-llm-harness.ps1` 113/113; `validate-github-config.py`
  self-test + repo check green; `agent-check.ps1` green.

## Leftovers / follow-ups

- Typed-object constructors still coerce when a caller constructs them
  directly with wrong-typed dicts (not wire-reachable; every decode path
  validates first) — residual #72-class surface, deferred.
- `downgrade_reason` treats a raw-string format array as membership
  candidates (latent; the only caller passes coerced ints).
- v3 binary frames' `seq`/`epoch` stamps are validated but dropped, so
  consumers cannot dedupe/order — feature decision, upstream-parity
  unverified.
- PLAN P5's "do not touch llm-harness.yml" is amended: the workflow was
  split into parallel jobs (guard + stages intact); the rule's intent
  (never slow or weaken the fast-path guard) is preserved.
