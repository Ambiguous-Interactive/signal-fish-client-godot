---
description: Use when adding validation scripts, hooks, CI, Godot tests, fixtures, or generated-file checks.
triggers: test, ci, github actions, hook, pre-commit, lint, generated, fixture
category: Testing
---

# Testing And Automation

## Trigger

Use this skill for repository automation, generated files, hooks, CI workflows,
and future Godot test setup.

## Current Harness Checks

The LLM harness is validated with:

```powershell
pwsh -NoProfile -File scripts/generate-llm-index.ps1 -Check
pwsh -NoProfile -File scripts/lint-llm.ps1
pwsh -NoProfile -File scripts/test-llm-harness.ps1
```

Or run all three plus the staged-generated-files check via the single hook
entry point used by `.githooks/pre-commit` and CI:

```powershell
pwsh -NoProfile -File scripts/run-llm-hooks.ps1 -Mode Full
```

These checks enforce:

- `.llm` Markdown and known pointer file line counts at or below 300 lines.
- Metadata presence for `.llm` Markdown files except generated
  `.llm/index.md`.
- Vendor pointer files referencing `.llm/context.md`.
- Generated `.llm/index.md` and context index freshness.
- Frontmatter parsing edge cases (closed vs unclosed fences, quoted values,
  case-insensitive keys, blank lines, and UTF-8 BOMs) covered by
  `scripts/test-llm-harness.ps1`.
- Generator and linter both import the shared
  `scripts/lib/LlmHarness.psm1` module instead of redefining helpers.
- Pre-commit hook detects untracked generated files (not just unstaged
  modifications) so a fresh-from-generator file cannot slip through.
- Generated-file status parsing treats Git porcelain index/worktree columns as
  separate fields. Staged-only generated changes do not need worktree staging;
  untracked or worktree-dirty generated files do.
- Local hook entry points pass `-AutoFix`; CI and `agent-check.ps1` pass
  `-NoAutoFix`. `-SkipStagedCheck` means an outer wrapper validates content
  outside the local staging flow, not that Git lacks an index.
- `PreCommit` and `AgentFast` are fast modes: no behavioral subprocess tests,
  no generator/linter child `pwsh`, and staged-aware scoping for ordinary
  commits. Tooling changes use in-process PowerShell parse/static guards;
  `Full` and `CI` keep the exhaustive sandbox coverage.
- Stray artifact detection is single-sourced through
  `Get-LlmStagingArtifacts` (tracked + non-ignored) and
  `Get-LlmStrayWorkingTreeArtifacts` (includes gitignored junk like
  `*.tmp`, `*.swp`, `.DS_Store`). Both helpers default to
  `Get-LlmDefaultStrayPatterns`; the hook runner's `-AutoFix` uses the
  broader scan.
- Tracked shebang scripts are checked at byte level and by `git check-attr`
  so PowerShell hook/reference scripts that can run directly on Unix stay LF.
- POSIX hook bootstraps must create a private temp directory with `mktemp -d`
  and run a fixed `bootstrap.ps1` inside it. Do not use predictable `/tmp`
  fallback paths or BSD/macOS `mktemp -t ...ps1` patterns that can produce a
  non-`.ps1` suffix.
- `scripts/preflight.ps1` parse-checks itself first, then every tracked
  `.ps1`/`.psm1`/`.psd1`. `-AutoFix` recovers from the index/staged copy
  first, then falls back to `git checkout HEAD -- <path>` after writing
  backups below `git rev-parse --git-path preflight-recovery`. Worktree
  behavioral tests cover both worktree and staged/index backups so `.git` is
  never assumed to be a directory and HEAD fallback cannot silently discard
  staged WIP. `run-llm-hooks.ps1 -Mode Full`, CI, and `agent-check.ps1 -Full`
  execute it before downstream tools; fast modes use the in-process
  parse/static guards above instead of spawning preflight.
- `.claude/settings.json` runs `.claude/hooks/parse-check-powershell.ps1`
  on every PowerShell write/edit so a stale-buffer corruption surfaces
  in the agent's tool_result on the next turn (exit 2 + JSON reason),
  not at commit time. The `Stop` hook re-runs preflight as a final
  defense.
- `scripts/validate-github-config.py` validates `.github/workflows/*.yml`
  and `.github/dependabot.yml` without network calls. It self-tests duplicate
  YAML-key rejection, preserves GitHub's `on:` key, rejects
  `gh api --slurp` with `--jq`, runs `bash -n` for the Dependabot auto-merge
  script, rejects CRLF shebangs there, checks workflow-name/required-check
  drift, and rejects `groups` or `multi-ecosystem-group` under the
  `devcontainers` Dependabot updater because grouped scans have been
  unreliable for that ecosystem. In `PreCommit`, `run-llm-hooks.ps1` validates
  a staged-index snapshot so unstaged worktree fixes cannot mask bad staged
  GitHub config.

## Current Runtime Checks

Runtime protocol code is validated separately from the LLM harness:

```bash
bash scripts/run-runtime-checks.sh all
```

GitHub workflow and Dependabot policy checks are part of the LLM harness.
After editing `.github/**`, `scripts/dependabot-auto-merge.sh`, or
`scripts/validate-github-config.py`, run:

```bash
python -m pip install -r requirements-automation.txt
python scripts/validate-github-config.py --self-test
python scripts/validate-github-config.py --repo-root .
```

`.github/workflows/ci.yml` is the runtime workflow. Keep Godot/protocol steps
there rather than in `llm-harness.yml` so the LLM fast-path budget remains
isolated.

Slow workflows stay off the fast gate: `web-export-smoke.yml` (import, export
the Web preset, assert `index.html`+`index.wasm`, browser checklist) and
`protocol-sync.yml` (fails when upstream moves past the pinned fixture SHAs)
run on a weekly cron + `workflow_dispatch` only — never on push/PR. Third-party
actions are pinned to commit SHAs; `actions/*` may stay on major tags. The
release flow is dispatch-only and documented in
`.llm/skills/asset-library-release.md`.

`scripts/run-runtime-checks.sh` is the shared local/CI entry point. It sets a
writable deterministic `HOME`, activates `.venv-ci` when present, and exposes
`private-helpers`, `format`, `lint`, `godot`, `all`, `changed`, and `smoke`
subcommands so CI can keep separate step names without drifting from local
reproduction commands. The `all` subcommand runs the static checks and the
godot suites concurrently — the gate wall is the slower half, not the sum.
The `godot` subcommand accepts suite names (`protocol transport
client binary reconnect demo_boot p2p_boot`); one explicit suite runs warm
in-tree against the live `.godot` cache for fast local iteration (`SF_COLD=1`
forces the CI-identical path), while no-argument and multi-suite runs copy the
source tree into fresh temporary projects without `.godot/`, which prevents
local editor/global-class caches from masking failures that would appear in a
clean CI checkout.

The `changed` subcommand is the agent fast loop (issue #117): it checks only
what the dirty tree can affect. Test `.gd` files map to the suites whose
runners transitively preload them (BFS over the runners' `res://` preload
strings — no hand-maintained map to drift), scoped static checks run over the
changed files only (the ~2 s analyzer self-test stays a CI/full-gate guard),
and production-side edits escalate to the full gate loudly. The full gate
remains the pre-push contract; `changed` only narrows the inner loop.

Deletion rule (Bugbot round on PR #116): a path collected in one phase and
consumed in another must be re-validated at the consumption boundary —
deletions and renames are the classic divergence. `changed` therefore still
maps deleted helpers to their suites (the runner's stale preload keeps the
suite honestly red) but drops them from the static file list, and an empty
static list is a no-op (never fall back to a whole-tree sweep). The same
class was checked and is already safe elsewhere: `copy_cold_project` filters
deleted files out of the tar manifest, the analyzer reports missing paths
legibly (exit 2), the sh shim and pwsh predicates match names only, and the
cold-copy tar errors stay loud by design.

A GDScript runtime error aborts only the running function — a green suite
whose test died mid-way is a vacuous pass (issue 104). Two nets close the
class: every test function ends with the owner's `_done()` and is driven
through `tests/completion_guard.gd` (`drive` flags a test that never
completed, `check_registration` flags a `_test_` method missing from the case
list, and `self_check` pins the mechanism in each SceneTree runner), and the
shell runner fails any godot output containing `SCRIPT ERROR`, which also
covers helper aborts a test could survive. Keep wrong-type assignments and
dynamic calls on possibly-wrong object types out of test middles; assert the
object type (`is`) before driving it, and never let a helper construct a real
engine transport/socket inside a fake-only gate.

Cold copies are one tar stream over a filtered `git ls-files -z` manifest, not
a per-file copy loop. Shell rules that bit here: `set -e` is suppressed inside
`var="$(...)"` command substitutions, so a helper whose pipeline fails must
propagate the status through the function return (and background workers
report it through `wait`); files deleted in the working tree must be filtered
out of `ls-files` lists before tarring, because tar warns-and-continues and
would silently shrink the copy behind a zero exit; gate on exit status, never
on captured stderr text.

The `smoke` subcommand is opt-in (never part of `all`) and runs
`tests/smoke/run_websocket_smoke.gd`: a local RFC 6455 server
(`tests/smoke/ws_test_server.gd`, text/binary echo plus close handshakes in
both directions) driven from a `SceneTree` `_process` loop, exercising the real
`SFWebSocketTransport` open/echo/close paths and a refused dial. Frame pumping
lives in `SceneTree._process` with per-wait timeouts and a watchdog, so a
broken phase fails loudly instead of hanging.

`scripts/check-gdscript-private-helpers.py` uses gdtoolkit's parser and treats
public methods, constructors, Godot callbacks, and `_on_*` handlers as
reachability roots. It catches dead private helper chains such as leftover
wrapper scaffolding while keeping public addon APIs out of repo-local
dead-code pruning. It also rejects references to a script's own `class_name`
through `ClassName.` because ignored Godot global class caches can mask those
references locally and fail in fresh CI clones. Suppress an intentional
reflection-only private helper only with a local
`# gdscript-private-helper: allow _helper_name` comment on the helper
definition line or immediately above it. The check does not treat
`call_group`/`call_group_flags` as local reachability because group membership
is runtime state; use the local allow comment for intentional group-only
private handlers.

## Performance Guardrails

- CI measures the non-mutating fast path and fails if median runtime exceeds
  5000ms.
- Keep expensive sandbox tests tagged `-Behavioral` so fast modes can skip
  them deterministically.
- Any new broad Git scan or repeated full-file read in a pre-commit path needs
  a measured budget and a static self-test that prevents accidental drift.

## Generated Files

- Do not edit `.llm/index.md` by hand.
- Do not edit the generated section in `.llm/context.md` by hand.
- Regenerate after adding, deleting, or renaming any `.llm/**/*.md` file.
  Non-Markdown `.llm` files are not included in the generated index.

## Future Godot Tests

When runtime code exists, prefer a small deterministic suite before broad
integration tests:

- Protocol encode/decode fixtures pinned to upstream Signal Fish repository
  paths and commits before runtime semantics are implemented.
- Fake transport adapter tests covering connect, receive, send, close, error,
  reconnect, and backpressure before live network tests.
- Godot 4 smoke test for the `WebSocketPeer` adapter path (landed:
  `bash scripts/run-runtime-checks.sh smoke`).
- Browser export manual check covering HTTPS hosting, `wss://`, WebSocket
  `Origin`, mixed-content rejection, and no native-only socket assumptions.
- Godot 3 smoke tests only after a separate compatibility decision, focused on
  the `WebSocketClient` adapter path.

## CI Guidance

Keep CI fast at repo bootstrap. Add heavier Godot matrix jobs once there is
runtime code to validate.
