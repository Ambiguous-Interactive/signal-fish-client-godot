# Session 048 - CI shard, smoke stamp parity, green local devcontainer

Date: 2026-09-24

## Scope

- Fix #132: shard the harness self-test suite into two concurrent passes in
  CI (and locally in Mode Full) so the wall is max(halves), not the sum.
- Fix #134: port docs-validation's full system-deps stamp pattern (dpkg
  probe + skip-apt path) to web-export-smoke.yml.
- Fix #136 (filed this session): provision PyYAML + a complete `.venv-ci`
  in the devcontainer so the local gate is green out of the box.
- Cut the self-test suite's dominant cost (issue #132 follow-up data): the
  fake-npm OpenCode migration test burned wall time on repo-mount file I/O
  and real retry sleeps.

## Work log

- Measured first: CI self-tests job 56 s (the PR wall); local suite 88.3 s
  serial with one env-driven failure (sandbox PyYAML); top test 36.6 s.
- RED: confirmed the local suite fails on a fresh devcontainer (sandbox
  python3 cannot import PyYAML) and `run-runtime-checks.sh all` fails
  (gdtoolkit missing). Filed #136.
- GREEN: `post-start.sh` warn-only heals PyYAML (user site) and creates
  `.venv-ci` with both requirements files; post-start self-test contract
  extended; verified by breaking the environment and re-running.
- Added `-OnlyBehavioralTests` to `test-llm-harness.ps1` (mutually exclusive
  with `-SkipBehavioralTests`; wins over the skip env var so the behavioral
  shard can never pass vacuously).
- Sharded the suite in `llm-harness.yml` (preflight + core + behavioral
  concurrently) and in `run-llm-hooks.ps1 -Mode Full` (two concurrent
  children, buffered logs, aggregate failure).
- Made the installer's failed-install retry delay injectable
  (`AGENT_TOOLS_RETRY_SLEEP_MS`, default 2000); the fake-npm matrix sets 0.
- Moved the fake-npm migration matrix's temp tree from the repo bind mount
  to `[System.IO.Path]::GetTempPath()` (suite convention): 36.6 s -> 3.4 s.
- Ported the dpkg probe block to web-export-smoke.yml; the two step bodies
  are now byte-identical (diff-checked), validator green.
- Pinned the wiring: MIN-2 self-test now asserts both shard flags in the
  runner and the workflow, mutual exclusion, and the env-var precedence.

## Review

- Round 1 (adversarial sub-agent) found: unquoted `-File` in Start-Process
  (space-path breakage), a recursion hole in the nested-self-test contract,
  a cross-shard race (stray tests polluting the real tree), a partial-venv
  heal gap, and doc drift. Fixed: pre-quoted -File, nested-child detection
  (suite-spawned children run only the core shard), four stray tests moved
  to `New-HookBehaviorSandbox` copies, venv verify-and-heal via
  `venv_ok()` (yaml + gdformat), REPO_ROOT-pinned paths, docs aligned.
- Round 2 verified all five fixes and found one sibling defect class:
  four `.claude` hook tests passed unquoted repo-derived `-File` paths.
  Quoted the same way; a full Mode Full run in a space-containing checkout
  path is green end to end. Also named PEP 668 in the PyYAML WARN for
  diagnosability. Kept `gdformat --version` as the venv probe (it is the
  tool the runtime gate actually invokes).

## Verification matrix

| Scenario | Result |
| --- | --- |
| Local self-test suite (before) | 88.3 s serial; 114/115 (env failure #136) |
| Full gate `-Mode Full` (after) | 52.3 s; 115/115 via both shards |
| Shard split (local) | core 11.8 s; behavioral 44.3 s (was ~76 s) |
| OpenCode migration test | 36.6 s -> 3.4 s |
| `-OnlyBehavioralTests` + leaked skip env | Behavioral shard still runs 35 tests |
| Contradictory shard flags | Throws loudly |
| `agent-check.ps1` fast path | 2.6 s; OK |
| `run-runtime-checks.sh all` | Green (gdtoolkit via healed `.venv-ci`) |
| `run-runtime-checks.sh changed` | 8.8 s; green |
| `validate-github-config.py` (self-test + repo) | Green |
| Docs style check | Green (92 files) |
| Smoke vs docs stamp step bodies | Byte-identical |
| Mode Full in a space-containing checkout path | Green (quoting class swept) |
| Space-path + no `.venv-ci` + no PyYAML | Gate still green |

## PR

- PR: session branch (single squash PR). Closes #132, #134, #136. Files
  #137 (composite-action dedupe follow-up).

## Review

- Two adversarial review rounds ran before merge; all round-1 findings and
  the round-2 sibling-defect finding are fixed and re-verified above.
