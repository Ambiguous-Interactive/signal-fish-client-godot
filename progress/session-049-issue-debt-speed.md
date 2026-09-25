# Session 049 - Issue debt sweep, behavioral subshards, shared Playwright setup

Date: 2026-09-24

## Scope

- Fix the five open issues: #137 (shared Playwright setup), #140 (artifact
  action drift), #141 (duplicated generated-diff check), #142 (untagged
  devcontainer features), #143 (controlled-directory list in three places).
  #140-#143 were found and filed this session.
- Cut the CI PR wall and the local pre-push gate by splitting the behavioral
  self-test shard into two concurrent round-robin passes. Coverage is
  unchanged: the same 35 behavioral tests run exactly once per gate.

## Work log

- Measured first (sequential, uncontended): local `all` 4.6 s, 7 godot
  suites 1.55 s, static 3.6 s, `changed` with a dirty production file
  2.8 s, `agent-check` 2.8 s, Mode Full 52.3 s; CI PR wall = LLM harness
  self-tests job 45 s (behavioral shard ~44 s serial).
- RED: confirmed the two hand-copied Playwright blocks in docs-validation.yml
  and web-export-smoke.yml (issue #137) and the v4-vs-v7.0.1 upload-artifact
  drift (#140). Filed #140-#143 from the sweep.
- GREEN: `.github/actions/playwright-chromium/action.yml` owns the version
  pin (default input), cache, installs, and the system-deps stamp; both
  consumers call it. Stamp/cache-key shape unchanged (v3), so warm caches
  carry over.
- Deleted the validate job's hand-copied `git diff` step; Mode CI's
  `ci-generated-diff` stage is the single source of truth (#141).
- Pinned `powershell:2` / `node:2` in devcontainer.json and renamed the
  matching lock keys (#142).
- Added `Get-LlmControlledDirectories` to the shared module; the AutoFix
  delete scope and both stray-artifact scans consume it; MIN-8 pins the
  list and forbids redeclared copies (#143).
- Added `-BehavioralSubshard k -BehavioralSubshardCount n` (round-robin over
  declaration order, requires `-OnlyBehavioralTests`, loud on misuse) and
  wired three concurrent children into Mode Full and four into the CI
  self-tests job; MIN-2 pins the wiring.

## Verification matrix

| Scenario | Result |
| --- | --- |
| Subshard union check (local, concurrent) | 18 + 17 = 35 PASS, 0 overlap, both green |
| Concurrent subshards wall (local, 12 cores) | 26.1 s (behavioral was 44.3 s serial) |
| Mode Full gate | 52.3 s -> 40.8 s; 116/116 (81 core + 18 + 17) |
| CI self-tests job | 45 s -> 44 s (flat: per-test fork tax saturates a 4-vCPU runner) |
| CI validate job | 28 s -> 25 s (duplicate git-diff step removed) |
| CI static checks | 21 s -> 19 s |
| `-BehavioralSubshard` without `-OnlyBehavioralTests` | Throws (also when count stays default) |
| Out-of-range k (3/2, 0/1) | Throws |
| `BehavioralSubshardCount` 0 | Throws |
| `validate-github-config.py` (self-test + repo) | Green |
| Docs style check | Green (93 files) |
| `agent-check.ps1` fast path | Green |
| `run-runtime-checks.sh all` | Green (runtime untouched) |
| Workflow + composite-action YAML parse | Green (4 files) |
| Stale `PLAYWRIGHT_VERSION` references | None |

## Review

- Two adversarial review rounds ran before merge; findings and fixes are
  recorded in the PR description.

## PR

- PR #144: https://github.com/Ambiguous-Interactive/signal-fish-client-godot/pull/144
  (single squash PR). Closes #137, #140, #141, #142, #143.

## Notes

- web-export-smoke is schedule/dispatch only; it must be dispatched once
  after merge to exercise the composite action in that path (docs-validation
  exercises it on every PR, where it ran green with a warm cache).
- CI honesty: the self-tests job stayed flat (44 s vs 45 s). The split's
  wall win is local (12 cores); on a 4-vCPU runner the behavioral tests'
  per-test fork tax saturates the machine, so in-job concurrency cannot
  compress the total. Next-round ideas, in value order: slim the two
  heaviest behavioral tests (OpenCode migration 7.0 s and the PreCommit
  staged-index test 6.9 s on CI - each rebuilds a sandbox and re-runs the
  python validator self-test), or give the behavioral passes dedicated
  jobs so each gets a runner (needs branch-protection check-name updates,
  so it is a deliberate decision, not a drive-by).
- Left on the table (next rounds): preflight runs sequentially before the
  local Mode Full self-tests stage (~3-5 s); a 3-way behavioral split
  would gain little on 4-vCPU runners and stays unbalanced by MIN-3's
  inner core shard.
