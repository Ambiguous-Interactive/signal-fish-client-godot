# Session 003 - P1 Transport Seam

Date: 2026-05-31

## Scope

Completed the first P1 transport slice:

- Froze the public optional-value policy in `PLAN.md`.
- Added the `SFTransport` interface.
- Added deterministic `SFFakeTransport`.
- Added Godot 4 `SFWebSocketTransport`.
- Added headless transport tests.
- Extended runtime checks to cover all addon/test GDScript and the transport tests.

## Implementation

- `addons/signal_fish/transport/sf_transport.gd`: abstract transport contract with `opened`,
  `packet_received(payload, is_text)`, `closed(code, reason)`, and `failed(error)` signals.
- `addons/signal_fish/transport/sf_fake_transport.gd`: in-memory fake transport with synchronous
  open/text/server-message/binary/close/failure injection, outbound text/binary recording, and
  settable buffered amount.
- `addons/signal_fish/transport/sf_websocket_transport.gd`: Godot 4 `WebSocketPeer` adapter with
  `ws://`/`wss://` validation, bounded packet draining, text/binary frame distinction, close
  code/reason surfacing, buffered amount, and terminal signal guards.
- `tests/transport/run_transport_tests.gd`: deterministic transport tests covering fake transport
  lifecycle, send/receive, close reason propagation, failure behavior, token-safe invalid URL errors,
  and failed-open cleanup ordering.
- `scripts/run-runtime-checks.sh`: format/lint coverage now targets `addons/signal_fish` and `tests`;
  Godot checks run both protocol and transport suites from a cold project copy whose temp directory is
  registered for cleanup in the parent shell.

## Review Loop

- Explorer sub-agent confirmed the highest-priority next work was the P1 optional-value decision gate
  followed by the transport seam.
- Builder sub-agent implemented the initial transport seam, fake transport, WebSocket adapter, tests,
  and runtime-check integration.
- Adversarial review found three P2 issues: failed-open WebSocket paths emitted both `failed` and
  `closed`, invalid URL failures echoed full endpoints, and runtime format/lint checks were too narrow.
- Reconciliation fixed those issues and added regression tests.
- A second adversarial review found cleanup-path terminal ordering still allowed `closed` after
  `failed`; reconciliation routed closed-peer cleanup through the same failed-open classifier.
- A final adversarial review found a runtime temp cleanup leak and fake-transport terminal-ordering
  mismatch; reconciliation fixed both and added regressions.
- Final read-only re-review reported no remaining P1/P2/P3 findings for this transport slice.

## Validation

Completed validation:

- `godot --headless --path . --script tests/transport/run_transport_tests.gd`
- `bash scripts/run-runtime-checks.sh all`
- `bash -n scripts/run-runtime-checks.sh`
- `git diff --check`
- Isolated `RUNNER_TEMP` cleanup reproduction verified `remaining_cold_dirs=0`.

## Plan Maintenance

Updated `PLAN.md` to:

- Remove stale "zero runtime code" wording.
- Mark the optional-value policy, transport interface, fake/WebSocket transports, and transport
  adapter tests complete.
- Leave core client/config/state-machine work and client fake-transport tests incomplete.

## Follow-Ups

- Implement `signal_fish_config.gd` and `signal_fish_client.gd`.
- Add client fake-transport tests for auto-authenticate, decoded receive path, send methods,
  close/error, backpressure enforcement, cleanup, close code/reason surfacing, and pre-auth guard.
- Keep production URL and token logging paths redacted when the public client layer starts emitting
  connection failures.
