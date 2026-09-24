# Session 024 - P4 WebSocket Smoke + Architecture Docs

**Date:** 2026-09-21
**Branch:** `feat/p4-websocket-smoke` -> PR to `main`
**Goal:** Close the P4 verification gap (headless `WebSocketPeer` smoke test)
and align the `.llm` API docs with the shipped runtime (shape page +
`runtime-architecture` skill).

## Drift check

Main green (Runtime CI + LLM Harness at `1e31230`), tree clean and up to date,
no open/draft PRs, no open issues. Remaining PLAN work was the P4 close-out;
this session took the smoke test (the last unmet "first usable client" DoD
item) plus the P4 doc items.

## What landed

### Opt-in headless WebSocket smoke test (PLAN P4)

- `tests/smoke/ws_test_server.gd`: minimal RFC 6455 server bound to
  `127.0.0.1` - HTTP upgrade handshake (SHA-1 accept key), masked-frame parse,
  text/binary echo, ping->pong, close handshake in both directions. One
  connection slot with takeover, 1 MiB frame cap.
- `tests/smoke/run_websocket_smoke.gd`: `SceneTree` runner driving the real
  `SFWebSocketTransport` through open -> text/binary echo round-trip ->
  client-initiated close (3400/"smoke-done" code+reason verified on both
  sides) -> server-initiated close (4321/"server-bye") -> refused dial to a dead
  port (terminal `failed`, no `opened`/`closed`). Frame pumping lives in
  `SceneTree._process`; per-wait 5s timeouts, 30s watchdog, state diagnostics
  on timeout. Phase gating reports aborts (a broken preload can no longer
  print "passed").
- `scripts/run-runtime-checks.sh`: new `smoke` subcommand (cold-copy Godot run
  via a shared `run_godot_script` helper); opt-in, never part of `all`.

### Tooling fix surfaced by the smoke runner

- `scripts/check-gdscript-private-helpers.py`: `GODOT_PRIVATE_ROOTS` was
  missing the MainLoop virtuals `_initialize`/`_finalize`, so a
  `SceneTree --script` entry point made its whole private call chain
  "unreachable". Added both roots + two self-test cases (init chain with
  `await`, finalize chain).
- `gdlintrc`: `max-returns: 8` override with justification (the smoke
  phase's early-return guard chain skips dependent steps on timeout).

### Docs aligned with the shipped runtime (PLAN P4)

- `.llm/code-samples/gdscript-client-shape.md`: rewritten from the old
  pre-runtime sketch to a map of the shipped API (config fields, 30 methods,
  32 signals, value objects/sentinels, behavior notes) - it was still the
  stale "single source" R10 referenced.
- `.llm/skills/runtime-architecture.md`: new Core skill recording the
  layer map, polling model, state machines, decode policy, transport seam,
  mesh boundaries, and the suite map (PLAN section 7 pre-registered this file).
- `.llm/context.md` + `.llm/skills/testing-automation.md`: document the
  `smoke` subcommand; index regenerated; `agent-check.ps1` green.
- `README.md`: Development section shows the smoke command.
- PLAN.md: P4 smoke + doc items checked; status header updated.

## Verification

- `bash scripts/run-runtime-checks.sh smoke` - green, 4/4 stable repeat runs.
- Mutation check: flipping the expected close code to 3401 fails loudly with
  3 precise assertion messages (close code/reason on both sides + phase gate).
- `bash scripts/run-runtime-checks.sh all` - green (static + 5 suites).
- `pwsh -NoProfile -File scripts/agent-check.ps1` - green.
- `check-gdscript-private-helpers.py --self-test` - green (new cases pinned).

## Known limits / follow-ups

- Remaining P4: browser-export manual checklist (needs a human + browser) and
  the full API reference (README is quickstart-only). Both stay tracked in
  PLAN.md.
- The smoke test binds `127.0.0.1`; CI runners could run it later as a
  scheduled/optional step if localhost sockets are available (opt-in today by
  design - network-gated per PLAN).
- P6 store publish still waits on the one-time human bootstrap (secrets +
  first submission).
