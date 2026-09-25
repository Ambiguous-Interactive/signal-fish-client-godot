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
| Concurrent subshards wall | 26.1 s (behavioral was 44.3 s serial) |
| Mode Full gate | 52.3 s -> 39.4 s; 116/116 (81 core + 18 + 17) |
| `-BehavioralSubshard` without `-OnlyBehavioralTests` | Throws |
| Out-of-range k (3/2) | Throws |
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
  exercises it on every PR).
- Left on the table (next rounds): preflight runs sequentially before the
  local Mode Full self-tests stage (~3-5 s); CI runners are 4-vCPU, so a
  3-way behavioral split would gain little over 2-way.
