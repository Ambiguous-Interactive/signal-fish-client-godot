# Session 036 — Constructor coercion hardening (#95/#96) + CI trim

Date: 2026-09-23. Scope: one focused surface — the residual #72/#89-class
constructor coercion holes on direct construction (session-033 leftover) —
plus resolving PLAN §13 items 3/9 against upstream and a coverage-neutral
CI trim. Drift check first: main green on `07491d5` (PR #94), local ==
origin/main, no open issues/PRs, baseline `run-runtime-checks.sh all`
green.

## Issue debt

- **Filed + fixed #95:** typed-object constructors coerced boolean fields
  with the engine's `bool()`. Probe-verified on 4.3.1: wrong-typed numbers
  launder (`bool(0.5)`/`bool(-1)`/`bool(1)` → `true`, reproduced
  end-to-end on `PlayerInfo.is_authority`), and wrong-typed
  strings/null/arrays **raise** `Nonexistent 'bool' constructor` and abort
  the constructor mid-way, silently defaulting every later field (the #81
  abort class — a hostile `RoomJoinedInfo` loses its roster and
  reconnection token). 12 fields across 7 classes
  (`PlayerInfo`, `PlayerNameRules`, `PeerConnectionInfo`,
  `RoomJoinedInfo`, `SessionPeerInfo`, `NewPeerInfo`,
  `PeerTransportStatusInfo`). The decode path already rejects all of
  these (`_has_bool` validators); only direct construction was open.
  Fix: a shared strict `SFTypeUtils.bool_or_false` gate — engine-type
  bool passes, everything else reads the false sentinel.
- **Filed + fixed #96:** constructor integer gates used
  `is_integral_number` then `int(value)`, so integral floats at/after
  2^63 (e.g. `1e30`) collapsed into platform-dependent garbage — the
  repo's own #73 policy comment forbids this and the decode path enforces
  it via `_is_i64_integer`, but no constructor used that gate. Worst case:
  `ConnectionInfo.client_id` (`to_dict()` re-emitted the laundered value
  as the relay slot). Fix: shared `SFTypeUtils.is_i64_integer` gate at
  every constructor integer site (12 fields); in-range values pass
  verbatim (2^32 float proven), out-of-range/non-integer takes the
  field's absent sentinel (`-1` client_id, `0` elsewhere). Sign is
  preserved, fixing the sub-item: `ProtocolInfo` negatives used to clamp
  onto the 0 "absent on v2" sentinel; they now stay visible.
- **Filed #97 (follow-up debt, not fixed):** `_coerce_strings`-style
  constructor helpers silently drop wrong-typed array entries; the webrtc
  `ConnectionInfo.to_dict()` rebuild and roster `objects_to_dicts`
  round-trips then lose them. Needs a design decision (document-only fix
  vs validation channel); deferred with rationale.
- **Sweep method:** a research sub-agent traced every constructor/coercion
  site in `sf_types.gd`/`sf_session_types.gd`/`sf_events.gd` against the
  already-covered test matrix; the decode pipeline came back clean (no
  fail-open input class), so the surface was exactly the direct-construction
  residual.

## PLAN §13 items 3/9 resolved (upstream verified)

- **Item 9 (authority default):** server `room_service.rs:585`
  `supports_authority.unwrap_or(true)` (upstream `5af5fee`); docs
  (`authority.md`) agree — the "docs imply disabled" premise was stale.
  The Godot default omits the field → server enables authority, same as
  the rust client's `Option` default; new `join_room` omit test pins it.
- **Item 3 (config/params defaults):** rust `JoinRoomParams` defaults
  every optional to `None` → omitted on the wire; `game_data_format`
  unset resolves to JSON (`resolve_effective_game_data_format`). The
  Godot zero-value/omit convention matches exactly; no code change.

## CI

- Gate wall was 53s, dominated by the llm-harness self-tests job
  (preflight 8s + suite 40s sequential). The job now runs its preflight
  gate concurrently with the suite in one step (bash background + wait;
  both exit codes gate the job). Same checks, same loud-failure
  behavior, wall = max → ~45s. Verified locally: both green
  concurrently (113/113 suite tests pass).
- Coverage otherwise unchanged; the new suite adds ~160 constructor
  assertions (milliseconds) inside the concurrent protocol runner. No
  coverage removed or weakened.

## Tests

New `tests/protocol/constructor_coercion_tests.gd` (helper-suite pattern,
registered in `run_protocol_tests.gd`):

- Wrong-typed bool matrix (`"false"`, `"true"`, `""`, `1`, `0`, `0.5`,
  `-1`, `1.5`) over all 12 bool fields → false sentinel; honest
  `true`/`false` pass through. The 9 rows whose field has successors also
  seed a trailing value and assert it survives each hostile input — that
  is what pins the constructor-abort class (a mid-way abort silently
  defaults the field too, so the sentinel assert alone passes vacuously;
  caught by the red-team mutation test).
- Collapse matrix (`1e30`, `2^63`, `-2^63`, `NaN`, `INF`, `"12"`, `1.5`)
  over all 12 int fields → absent sentinel; `4294967296.0` and plain ints
  pass through verbatim (no false positives).
- Negatives stay visible on `ProtocolInfo` (no more 0-clamp conflation).
- Laundered `client_id` never reaches `to_dict()` (the #89 relay-slot
  hazard, constructor level).
- Plus the §13 item 9 `join_room`-omit pin and three builder-side
  collapse vectors (`max_players`/`protocol_version` at `1e30`/`2^63`)
  in `protocol_hardening_tests.gd` — the same #96 class on the outbound
  builder path, where a collapse landing at 0 would have silently omitted
  `protocol_version` (red-team find).

Red-green: the full suite was run against the unfixed constructors first
(114 failures recorded, including all 27 survival pins), then green after
the fix. Helper-level mutation checks (gate → launder/collapse) each go
red on their own matrix (48 bool / 39 int failures).

## Validation

- `run-runtime-checks.sh all` green before and after; gdformat/gdlint
  clean; `validate-github-config.py` green after the workflow edit;
  parallel preflight+suite step verified locally.

## Adversarial loop

Zero-knowledge red-team review of packet + diff (see PR review thread):
no P1 findings; P2/P3 notes addressed (issue-text correction comment on
#95 for the probe-verified engine matrix, test-row comment tightened).

## Leftovers / follow-ups

- #97 (constructor array-element drops / round-trip loss) open with
  options and a leaning; candidate for the next debt sweep.
- Session 033 leftovers unchanged: `downgrade_reason` raw-string array
  latency, v3 `seq`/`epoch` stamps dropped (feature decision).
- PLAN §13 items 4-8, 10 remain open verification work; P7 (Godot 3.6,
  rkyv) deferred behind their gates.
