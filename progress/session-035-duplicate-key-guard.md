# Session 035 — Duplicate-key guard for text frames (#92)

Date: 2026-09-22. Scope: one focused surface — the deferred #92 correctness
fix (text-envelope duplicate-JSON-key fail-closed strictness) — plus closing
the six issues #93 already fixed. Drift check first: main green on `46f475b`
(PR #93, the session-034 deliverable), local == origin/main, no draft PRs,
baseline `run-runtime-checks.sh all` + `smoke` green.

## Issue debt

- **Closed #86–#91** (no code change): all six were fixed by merged #93 but
  never closed; each got a comment citing the fix commit and the test that
  locks it.
- **Fixed #92 (the focused surface):** Godot's JSON parser is last-wins on
  duplicate object keys, so a hostile server could silently substitute
  envelope fields with a repeated key: `{"type":"GameData",...,
  "type":"RoomLeft"}` wiped room state while the real event vanished, a
  repeated `reconnection_token` emptied the retained auto-reconnect
  identity, and a repeated `all_ready` could force ready-gates open.
  Upstream (serde) rejects every such frame, and the binary envelope path
  already rejects duplicate fields — the text path was the last fail-open
  hole. Fix: `sf_json_guard.gd`, a strict single-pass pre-scan hooked into
  `SFEnvelope.decode_text` (the only wire text entry point; `missed_events`
  replay re-decodes already-parsed trees, so one hook covers the boundary).
  Any key repeated inside one object fails closed to `protocol_error`;
  the connection stays up, same policy as every other malformed-input class.
- Design decisions worth recording:
  - **Keys compare after escape decoding** (`"\u0061"` == `"a"`, surrogate
    pairs canonicalized). The #92 sketch suggested treating escaped
    lookalikes as distinct, but that contradicts upstream: serde compares
    unescaped strings, and the engine's own parser unescapes keys before
    its last-wins overwrite (probe-verified) — an escaped lookalike of
    `type` really does substitute the type today. Upstream parity wins per
    the canonical rule; escaped spellings of genuinely different keys
    never false-positive.
  - **Perf (the issue's decision gate), benchmarked on 4.3 headless:** the
    naive per-byte scan cost ~31 ms at the 256 KiB frame cap; skipping
    string contents with the native `PackedByteArray.find` (quote search +
    odd-backslash check) plus Dictionary-backed per-object key sets brings
    the guard's added cost to ~0.02 ms on a small control frame and
    ~0.5 ms at the cap bound. A pathological many-small-objects frame
    (~2000 objects) stays ~13 ms — bounded, and Dictionary key sets keep a
    single-object flood of distinct keys linear.
  - Unterminated strings also fail closed in the guard (cheaper and
    deterministic); every other malformed-JSON class is left to the engine
    parser, so the guard stays minimal.

## Tests

New `tests/protocol/duplicate_key_tests.gd` (helper-suite pattern, its own
runner registration) + one client-level case in `run_client_tests.gd`:

- Hostile matrix: envelope type substitution, RoomJoined reconnection-token
  wipe, LobbyStateChanged ready-gate forcing, duplicate inside a nested
  payload tree, duplicate after a 64 KiB string value, escaped-key lookalike
  of `type`, surrogate-pair key vs literal emoji — all `protocol_error`
  containing "duplicate".
- Acceptance matrix: unit envelope, escapes inside values (round-tripped
  verbatim), escaped-but-distinct keys — decode normally; sibling objects
  and repeated-across-levels keys are correctly not duplicates; invalid
  escapes and unterminated strings still fail (guard/engine respectively).
- Client level: the smuggled-RoomLeft frame on an in-room session → one
  `protocol_error`, connection CONNECTED, room/session state intact.
- Guard unit vectors for escape canonicalization and diagnostic truncation.

## CI

Structurally unchanged; the new suite adds milliseconds to the parallel
protocol suite. No coverage removed or weakened — coverage only added.

## Validation

- `run-runtime-checks.sh all` + `smoke` green; `gdformat`/`gdlint` clean
  (the new suite lives in its own file because `protocol_hardening_tests.gd`
  was already at the 1320-line `max-file-lines` cap).
- Red-green: every hostile vector decodes successfully (event substitution
  reproduced) with the guard hook disabled, and fails with it enabled.
- Benchmarks recorded above; bench script kept out of the repo (non-bloat).

## Adversarial loop

Zero-knowledge red-team sub-agent reviewed packet + diff and re-ran the
suites. Findings and resolutions recorded in the PR review thread; all
P1/P2 addressed before opening the PR.

## Leftovers / follow-ups

- Session 033 leftovers unchanged: typed-object constructor coercion on
  direct construction (residual #72-class), `downgrade_reason` raw-string
  array latency, v3 `seq`/`epoch` stamps dropped (feature decision).
- PLAN §13 items 3/9/10 remain open verification work; P7 (Godot 3.6,
  rkyv) deferred behind their gates.
- With #92 closed, no known fail-open input class remains on the text
  decode path; future sessions should hunt the encode/decode parity surface
  and the remaining PLAN §13 verification items.
