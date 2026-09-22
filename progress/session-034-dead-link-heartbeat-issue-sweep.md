# Session 034 — Dead-link heartbeat + issue-debt sweep (#86–#92)

Date: 2026-09-22. Scope: one focused surface — the last unimplemented PLAN
§4.7 reliability item (heartbeat/pong-timeout dead-link detection, #91) —
plus a six-issue debt sweep filed and fixed same-session. Drift check first:
main green on `f967ff9`, local == origin/main, zero open issues/PRs,
protocol-sync OK (server 0.9.1 @ `24a5d10b` matches 6 pins), baseline
`run-runtime-checks.sh all` + `smoke` green, no in-progress work.

## Issue debt

No open issues existed, so (as in session 033) this session hunted, filed,
and fixed six (#86–#91), plus one detailed deferred (#92). Findings came from
three parallel hunter sub-agents (client state machine; codec wire fidelity;
mesh/docs drift), every candidate re-verified against the code before filing.

- **#91 (P2, the focused surface):** PLAN §4.7 specified an optional
  heartbeat (`heartbeat_interval_sec`, `pong_timeout_sec`) but neither the
  config fields nor the logic existed. Silent link death (NAT rebinding,
  radio loss — no FIN/RST) left the client CONNECTED forever:
  auto-reconnect never fired (it requires an observed termination) and sends
  degraded to permanent `ERR_BUSY`. Fix: delta-accumulated ping while
  connected + authenticated (no timers/threads); a missing `pong` past the
  deadline ends the link through the existing transport-failure path, so
  auto-reconnect engages exactly like any other abnormal termination.
  Backpressured beats retry after a full interval (no per-frame
  protocol_error spam); the clock resets per link (`_on_transport_opened`)
  so synchronous test redials cannot inherit a stale pong deadline; user
  close wins (state gate in the tick).
- **#87 (P1):** `get_players()`/`get_spectators()` handed out the live
  internal roster arrays — one `clear()` by game code corrupted presence
  handling silently (leaves no-op, authority migration reads an empty room).
  Fix: defensive `duplicate()` copies, matching the documented (and
  test-locked) event-payload isolation one layer down.
- **#86 (P1):** `_drop_peer` never disconnected the two signal lambdas that
  capture the mesh `entry` (which holds the connection) — a RefCounted cycle
  leaking a `WebRTCPeerConnection` + closures on every plan rebuild
  (generation/role changes rebuild all retained peers). Fix: callables
  stored on the entry, disconnected and cleared in `_drop_peer`.
- **#88 (P2):** the advertised `MAX_MESSAGE_DEPTH` cap never reached the
  consumer-facing passthrough trees (`GameData.data`, `Signal.signal`), and
  non-finite numbers decoded fail-open (`1e400` → `inf` via the engine JSON
  parser; MessagePack float markers accepted NaN/±Inf) — while the encode
  side already refuses both (#83/#76), so such payloads were one-sided
  poisons game code could not even echo. Upstream serde rejects both
  classes. Fix: shared `SFTypeUtils.passthrough_payload_error` walk
  (depth-capped, finiteness-gated, JSON-null-tolerant) on both text trees,
  plus the mirrored refusal in `SFMsgpack.decode` (f32 + f64 markers,
  verified against pinned bit patterns).
- **#89 (P2):** `ConnectionInfo._init` read `client_id = int(...)` with no
  integral gate (the exact hole #81 closed for `port`): `1.5` truncated to
  `1` and reached the wire as a different relay slot through the documented
  `to_dict()` resend path. Fix: `is_integral_number` gate; integral floats
  (`7.0`) stay accepted (no false positive).
- **#90 (P1 docs usability):** the shape doc's minimal-usage sample called
  `join_room` synchronously after the dial — refused on every run
  (`ERR_UNAUTHORIZED` pre-auth); the shipped README/getting-started had the
  fix but the AI-facing canonical mirror never got it. Also fixed there:
  stale `send_transport_status(transport, ...)` parameter name, and the
  mesh-guide/mesh-header "tears down on `player_left`" overstatement (only
  the leaver is dropped; test-locked).
- **#92 (P1, filed, deferred by design):** Godot's JSON parser is
  last-wins on duplicate keys, so a hostile server can substitute events or
  smuggle fields (`{"type":"GameData",...,"type":"RoomLeft"}`) with no
  diagnostic; the binary path already rejects duplicates (rust-client
  parity) and upstream serde rejects them everywhere. Deferred because the
  fix is a strict single-scan JSON lexer (perf-sensitive on the web export);
  the issue carries the design sketch and the benchmark-first decision
  gate. Top candidate for the next round's focused surface.

## CI

- Runtime CI unchanged structurally; new suites add milliseconds.
- Docs Validation's Accessibility job (the longest PR gate, ~62s) ran
  `playwright install-deps` (apt-get update + install) on every run even on
  browser-cache hits — 29s of its wall time. It now asks Playwright for its
  own package list (`install-deps --dry-run`), checks them with `dpkg -s`,
  and skips apt entirely when satisfied; any parse surprise falls back to
  the original retry path. Verified the parse pipeline against
  representative dry-run output locally.
- `gdlintrc` `max-file-lines` 1250 → 1320 (precedent: #63 raised it 1200 →
  1250 for legitimate runner growth); the client gained the heartbeat and
  the runners gained the heartbeat suites.

## Test shifts (honesty note)

Coverage only added, none removed or weakened: heartbeat matrix
(off-by-default, interval/pong cycle, pong-timeout teardown, backpressured
retry quietness, auto-reconnect redial — all injected-delta), roster-copy
isolation (`is_same` identity + presence-after-external-clear), mesh leak
(weakref must go dead after a drop — behavioral red verified against the
old mesh), passthrough hostile/acceptance matrix + replay-path refusal +
exact depth boundary, msgpack non-finite decode vectors, client_id
laundering + integral-float positive. The passthrough suite lives in
`wrong_typed_token_tests.gd` and the heartbeat suite in
`tests/client/heartbeat_tests.gd` (helper-suite pattern) to respect the
runner line caps.

## Validation

- Red-green: mesh leak test fails against the pre-fix mesh (verified);
  heartbeat/passthrough tests cannot load against pre-fix addons (new
  config fields/helpers), which fails CI loudly; with fixes applied,
  `run-runtime-checks.sh all` green and `smoke` green.
- `gdformat`/`gdlint` clean; `agent-check.ps1` green;
  `validate-github-config.py` self-test + repo check green.

## Adversarial loop

A zero-knowledge red-team sub-agent reviewed the full session diff and
**executed** the suites on both HEAD and the base commit (grafting the new
leak test onto the old mesh to confirm the red independently). Verdict:
zero P1, one P2, five P3s — all addressed:

- **P2 (fixed + red-verified):** the #86 fix itself traded in a narrower
  regression — a mesh `free()`d while outside the tree (no `_exit_tree`)
  could not run `_drop_peer`, so the new entry-lambda cluster outlived the
  node where the base was clean. Fix: `NOTIFICATION_PREDELETE` now calls
  `_reset_mesh()`; the new `_test_out_of_tree_free_does_not_leak` fails on
  the disabled-handler variant (verified) and passes with it.
- **P3s (fixed):** the CI dpkg fast path now uses
  `dpkg-query -F='${db:Status-Status}'` (exact; `dpkg -s` succeeds for
  removed-but-configured packages); the CHANGELOG #88 bullet no longer
  implies the binary raw-bytes fallback path refuses payloads; the heartbeat
  docs (client.md + config field) now state it runs from `_process` and
  needs the node in the tree; the depth-boundary pin walks a populated
  container (`[[1]]` with the leaf exactly at the cap accepted, one deeper
  refused) instead of an empty array; `_tick_heartbeat` documents the
  sustained-backpressure tradeoff (no pong deadline arms there, but every
  consumer send already fails loudly with `ERR_BUSY`).

All suites, smoke, static checks, and the harness validators re-run green
after the fixes.

A focused re-review of the fix delta (empirical: Godot probes for the
predelete paths, a simulated dpkg run) confirmed the mesh/test/doc items
clean and caught one more P2: under GitHub's `bash -e` default,
`dpkg-query` exiting 1 for a package absent from the dpkg database (the
normal fresh-runner case) aborted the docs step instead of falling back.
Fixed with the `|| status=""` guard and verified both branches locally
(missing → install fallback, all present → apt skipped).

## Leftovers / follow-ups

- #92 duplicate-key strictness (design + decision gate in the issue).
- Session 033 leftovers unchanged: typed-object constructor coercion on
  direct construction (residual #72-class), `downgrade_reason` raw-string
  array latency, v3 `seq`/`epoch` stamps dropped (feature decision).
- PLAN §13 item 3 (config field defaults vs upstream `client.rs`) and item
  9/10 decisions remain open verification work.
