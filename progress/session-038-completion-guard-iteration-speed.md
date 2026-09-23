# Session 038 — Vacuous-pass guard (#104) + faster local gate + branch hygiene

Date: 2026-09-23. Scope: one focused surface — issue #104 (a runtime error
inside a test function silently skips its remaining assertions) — plus the
local-iteration-speed pass and the branch-hygiene rule that ends the
recurring local-main divergence. Drift check first: origin/main `0f2a703`
(PR #103), local main carried eight stale pre-squash commits and a half-done
merge with four conflicts; the stale commits were a strict subset of the
squashed PR, so local main was hard-reset onto origin/main (zero content
lost — verified by tree diff before resetting). One open issue (#104), no
open PRs, CI green.

## Main surface: issue #104 (vacuous pass)

- **Failure class:** a GDScript runtime error unwinds only the running
  function. A test dying mid-way left its prefix asserted, its suffix
  skipped, the failures list clean, and the suite green — the exact hole the
  redial-from-exhaustion test fell into during session 037's review round.
- **Net 1, in-engine (`tests/completion_guard.gd`):** every suite (five
  SceneTree runners + eleven helper suites) is now driven through the shared
  guard. Each test ends with its owner's `_done()`; `drive` flags any case
  that never reaches it, `check_registration` flags a `_test_` method
  missing from the case list (registration drift was a second silent-skip
  class), and `self_check` pins the mechanism itself in every SceneTree
  runner. Mechanical sweep across 16 files (~150 tests) done by a one-off
  script; the two `_test_*`-prefixed parameterized helpers in
  `upstream_samples_tests.gd` were renamed `_check_*` to keep the
  `_test_` prefix meaning "a registered, self-contained case".
- **Net 2, shell gate:** `run-runtime-checks.sh` fails any godot output
  containing `SCRIPT ERROR` (warm path, cold workers, and smoke). Godot
  prints the abort's file/line/function there, and this also covers helper
  aborts a test could survive (the error unwinds the helper, not the test).
  Intentional failure-path `push_error`s print `ERROR:`, not
  `SCRIPT ERROR:` — verified no false positives across all seven suites.
- **Checker generalization:** the private-helper reachability analyzer only
  counted calls, so 324 callable-driven tests/helpers went "unreachable"
  under the new table-driven shape. `call_references` now also counts bare
  method-name references (Callable values) and explicit `self._method`,
  while receivers (`other._dead`), binding names (`var _dead = 1`), and
  definition headers stay excluded; pinned by a new self-test case.
- **Red-green:** green baseline on all seven suites; removing `_done()`
  flags every test as aborted; dropping a case from the list flags the
  orphan ("not in the case list"); a real mid-test `probe["a"]["b"]` abort
  produces both the named test failure and the `SCRIPT ERROR` line.
- **gdlint:** `max-file-lines` raised 1320 → 1400 with rationale (same
  documented escalation path as 1200 → 1250 → 1320); the sentinel adds one
  line per test plus fixed boilerplate per runner.

## Iteration speed + hygiene

- `run-runtime-checks.sh all` now runs the static checks and the godot
  suites concurrently: wall ~14.6 s → ~7.5–10.8 s locally. CI already
  parallelizes via separate jobs, so CI time is unchanged; the shell gate
  adds a grep over already-captured output. Test coverage unchanged.
- Branch-hygiene rule recorded in GOAL.md and `.llm/context.md`: local
  `main` is a pure mirror of `origin/main`; work happens on branches, and
  after each squash merge `git fetch origin && git reset --hard
  origin/main`. This session's merge-conflict untangling was the direct
  product of commits parked on local `main` while GitHub rewrote history.

## Verification

All seven suites + static green through `run-runtime-checks.sh all`;
guard red-green probes as above; analyzer self-test green; gdformat/gdlint
clean; agent-check green after `.llm` edits. Issue #104 closes with the PR.

## Leftovers / notes

- `godot` suite wall is now dominated by engine boot + the slowest suite
  (~4.5 s cold-parallel); further gains would need in-process re-runs, not
  worth the isolation risk.
- Only one open issue existed (#104); the "3+ issues" GOAL line was
  unsatisfiable this round. Next round: pick a PLAN §13/upstream-verification
  surface or a fresh adversarial sweep.
