# Session 053: Cut the agent-tools fork tax (issue #145, option 1)

Session branch: `session-053-agent-tools-fork-tax` (from `origin/main` @
`c8c9a9b`). One aggregate PR.

## Scope

- No open PRs, main CI green, one open issue: #145 (behavioral self-test
  wall is fork-tax bound; slim the two ~7 s tests or give subshards
  dedicated runners).
- Data first: pulled per-test durations from the latest main CI log - the
  OpenCode migration test is still the top cost (4.4 s on CI, 6.9 s local
  under 2-pass contention); the PreCommit staged-index test follows (3.7 s
  CI). Checked branch protection: no required status checks exist today,
  so the dedicated-jobs route (option 2) is unlocked but left as the
  deliberate structural decision the issue reserves for a separate round.
- Deliverable: option 1 for the top test, plus the production-side fix the
  test surfaced.

## Root cause of the migration test's cost

`install-agent-tools.sh` called `global_package_version()` up to ~11
times per run; each call forked a real `node -e` to parse the same
`npm list --json` snapshot. Measured: 13 installer runs = 3.54 s locally,
93% of the test's wall; node forks dominated each run. The test's own
per-case sandbox rebuild (8 file writes x 13 cases) was only ~0.3 s.

## Changes

- `.devcontainer/install-agent-tools.sh`: `refresh_installed_versions()`
  parses each snapshot once into a bash `installed_versions` map; node
  runs once per snapshot instead of once per query (~11 -> ~4 forks per
  run). `global_package_version()` is now a map lookup. Refresh points
  map 1:1 to the old `installed_json` assignments (initial, promote-time,
  post-removal, per-spec install), so stale-snapshot windows are
  unchanged. Also trims real post-create/attach latency.
- `scripts/test-llm-harness.ps1` (migration test): immutable template
  sandbox (fake npm, CLI stubs, package list, PATH dirs) built once;
  each case `cp -a`-copies it and applies only its variants. Copy result
  is asserted so a failed copy cannot fall through to real npm (review
  round 1).

## Data (local, 12 cores, 2-pass concurrency as in CI)

- OpenCode migration test: 6.9 s -> 3.9 s (-43%); solo 3.8 s -> ~2.6 s.
- Behavioral shard wall (max of both passes): 42.6 s -> 33.6 s (-21%).
- Installer run: 0.273 s -> 0.194 s per case (13 cases).

## Verification

- `run-llm-hooks.ps1 -Mode Full` green (81 core + 35 behavioral);
  `bash -n` and GitHub config validator green; `git diff --check` clean.
- 13-case matrix unchanged - same scenarios, assertions, and coverage;
  every refresh point traced to a case that fails without it (review
  round 2).

## Adversarial review rounds

- Round 1 (adversarial): one minor - unchecked `cp -a` could silently
  run real npm against the host prefix; fixed with an `Expect-Equal`
  guard. Byte-equivalence harness confirmed old/new lookups match on 16
  edge inputs (invalid JSON, null deps, non-string versions, glob
  metacharacters, `@`/`*` subscripts). Two accepted nits: tab/newline
  package names are impossible per npm name grammar; `declare -A` needs
  bash >= 4 (devcontainer/CI only, loud failure).
- Round 2 (final verify): guard placement/format verified, full gate
  re-run green, merge-ready with zero remaining issues.

## Left open

- #145 stays open for option 2 (dedicated runner jobs for the behavioral
  passes, ~8 vCPU total): no branch protection pins the job name today,
  but it doubles runner usage and changes check names, so it stays a
  deliberate decision. PreCommit staged-index test slimming remains
  ruled out (its inner work is what it proves).
