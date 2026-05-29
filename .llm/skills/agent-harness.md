---
description: Use when changing AI context, vendor pointer files, indexes, hooks, or LLM automation.
triggers: agent harness, llm, context, skills, index, hooks, ci, automation
category: Core
---

# Agent Harness

## Trigger

Use this skill when a task changes `.llm`, root agent files, CI, hooks, or
scripts that maintain AI context.

## Principles

- `.llm/context.md` is canonical.
- Vendor files are thin pointers to `.llm/context.md`.
- `.llm` Markdown files except generated `.llm/index.md` carry metadata in
  YAML frontmatter:
  - `description`
  - `triggers`
  - `category`
- Generated files must be reproducible and checked in.
- `.llm` Markdown files and known pointer files must stay at or below 300
  lines.

## Required Flow

0. Install PowerShell 7+ (`pwsh`). The harness, all hook scripts, and CI
   all require `pwsh` on PATH (Windows users: install from
   <https://aka.ms/powershell>). Legacy `powershell.exe` is detected by
   the pre-commit shim only to emit a clear "install pwsh" error; it is
   not a supported runtime.
1. Edit the focused context, skill, sample, or research Markdown file.
2. Run `pwsh -NoProfile -File scripts/agent-check.ps1` after any edit to
   `.ps1`, `.psm1`, `.psd1`, or `.llm/**` files. This is the fast,
   non-mutating validator; pass `-Full` before merging automation changes
   that need behavioral sandbox coverage.
3. Run `pwsh -NoProfile -File scripts/run-llm-hooks.ps1 -Mode Full`
   for exhaustive validation, or run
   `generate-llm-index.ps1` + `lint-llm.ps1` + `test-llm-harness.ps1`
   individually.
4. Include regenerated `.llm/index.md` and `.llm/context.md` when changed.
    Local hook entry points (the installed hook from `git rev-parse --git-path
    hooks` and `.pre-commit-config.yaml`) run with `-AutoFix` and will
    auto-stage these and delete scoped stray artifacts matching the shared
    harness junk list; CI and `agent-check.ps1` run with `-NoAutoFix` and will
    fail loudly on any drift, so do not rely on auto-fix as the only safety net.

## Shared Library

- `scripts/lib/LlmHarness.psm1` owns frontmatter parsing, path helpers, and
  staging-artifact discovery (`Get-LlmStagingArtifacts` for tracked / non-
  ignored; `Get-LlmStrayWorkingTreeArtifacts` for the gitignored blind
  spot). `Resolve-LlmGitPath` resolves git-dir-relative paths via
  `git rev-parse --git-path` so worktrees/submodules never assume `.git` is a
  directory. The module also owns generated-index and lint implementations so
  fast hook modes do not spawn child `pwsh` for generator or linter work.
- `scripts/run-llm-hooks.ps1` is the single source of truth for the
  pre-commit / CI flow. Use `-Mode PreCommit` for the installed hook,
  `-Mode AgentFast` for non-mutating local checks, `-Mode Full` for all
  structural and behavioral tests, and `-Mode CI` for loud generated diff
  verification.
- `scripts/preflight.ps1` parse-checks itself first, then every tracked
  `.ps1`/`.psm1`/`.psd1`. `-AutoFix` recovers a corrupt source from the
  index/staged copy first, then falls back to `git checkout HEAD -- <path>`.
  It is the first line of defense against stale-editor-buffer corruption.
- `scripts/install-git-hooks.ps1` materializes a portable POSIX-sh shim
  (`#!/usr/bin/env sh`) into the hooks directory resolved by `git rev-parse
  --git-path hooks` (usually `.git/hooks/pre-commit`).
  Sh is shipped on every platform git supports (Linux, macOS, Git for
  Windows); a pwsh shebang would break on Windows because `pwsh -File`
  refuses files without a `.ps1` extension. The committed
  `.githooks/pre-commit` (sh) and `.githooks/pre-commit.ps1` files are
  reference templates only; they are not the live hook and editing them
  alone has no effect until the installer is re-run. The installer clears
  legacy `core.hooksPath` values only after normalizing trailing separators
  and relative path variants; foreign hook paths require `-Force`. The
  emitted sh shim starts one `pwsh` bootstrap that parse-checks and invokes
  `run-llm-hooks.ps1` in the same process.

## Hook Performance Contract

- `PreCommit` and `AgentFast` must stay under a 5s median on ordinary no-op
  or non-harness commits.
- Do not add child `pwsh` processes to fast-mode generator, linter, or test
  stages; put shared logic in `scripts/lib/LlmHarness.psm1`.
- Do not repeatedly reread all Markdown files in fast paths; reuse the shared
  inventory helpers.
- Do not add broad ignored-file or whole-repo Git scans to pre-commit without
  a measured budget and a CI performance guard update.

## Automated Guardrails

The linter, preflight, and self-tests enforce repo-wide invariants beyond
`.llm`:

- All committed `*.ps1` / `*.psm1` / `*.psd1` files must parse cleanly.
  `preflight.ps1` enforces this; in `-AutoFix` mode the self-heal chain tries
  the index/staged copy first and falls back to `git HEAD`.
- No tracked or untracked staging artifacts (`*.new`, `*.bak`, `*.orig`,
  `*.old`, `*.rej`, plus editor junk from `Get-LlmDefaultStrayPatterns`) may
  exist. `Get-LlmStagingArtifacts` covers the tracked / non-ignored set;
  `Get-LlmStrayWorkingTreeArtifacts` covers gitignored blind spots like
  `*.tmp`. The hook runner's `-AutoFix` deletes scoped matches. `.gitignore`
  blocks common backups as a second layer.
- PowerShell hook/reference scripts with shebangs must stay LF-normalized.
  `.gitattributes` overrides `.claude/hooks/*.ps1` and `.githooks/*.ps1`,
  and the self-tests check both git attributes and first-newline bytes.
- `install-git-hooks.ps1` must have no undefined variable references and
  exposes `Get-InstallPathComparison`, `ConvertTo-NormalizedHooksPath`,
  `Test-LegacyHooksPath` so trailing-separator and relative-path
  variants of `.githooks` are recognized.

When adding a script, edit it in place — do not commit a `.new` copy.

## Agentic Hooks (Claude Code)

`.claude/settings.json` wires Claude Code hooks that catch corruption
DURING the edit, not at commit time:

- `PostToolUse` (matcher `^(Write|Edit|MultiEdit)$`) runs
  `.claude/hooks/parse-check-powershell.ps1` after every PowerShell
  write/edit. The matcher is anchored so a tool name like `NotebookEdit`
  cannot silently match a substring filter. A parse error exits 2 with a
  JSON-shaped reason; the agent sees the failure as `tool_result` on the
  next turn and self-corrects.
- `PostToolUse` also runs `.claude/hooks/validate-llm-context.ps1` after
  any `.llm/**/*.md` edit. This hook is a FAST per-file structural
  check (required frontmatter keys present, line count under 300, file
  is parseable as UTF-8 text) and intentionally does NOT delegate to
  `agent-check.ps1`; running the full harness on every edit would blow
  the cold-start budget. The slower full check runs via `Stop` and at
  commit time.
- `Stop` runs `.claude/hooks/preflight-stop.ps1` as a final safety net.
- `SessionStart` emits a one-shot reminder so the agent knows its writes
  are being auto-validated.
- All hook commands use `$CLAUDE_PROJECT_DIR` (set by Claude Code to the
  absolute project root) so they work regardless of cwd. Hooks that key
  on file paths (like `validate-llm-context.ps1`) also gate on this
  value so a `.llm/**` edit OUTSIDE this repo is silently ignored
  instead of false-blocking.
- `.claude/settings.local.json` is intentionally gitignored. Local Claude Code
  permission allowlists are user/machine-specific and must not grant shared
  destructive repo-wide commands.

Recovery path when the auto-validator complains:

```powershell
pwsh -NoProfile -File scripts/preflight.ps1 -AutoFix
```

This restores corrupted sources from the index/staged copy when possible, then
falls back to `HEAD` (the gitignored `*.tmp` blind-spot recovery also runs
through the hook runner's `-AutoFix`).

## Recovery From AutoFix

When `preflight.ps1 -AutoFix` restores a file from the index or `HEAD`, the
corrupt working-tree copy is backed up first so no WIP is silently destroyed.

- Backups live under the path from `git rev-parse --git-path
  preflight-recovery`, with layout `<resolved-parent>/<token>/<encoded-path>`.
- `<token>` is `<unixMs>-<pid>-<rand>` so concurrent preflights cannot
  collide on the same directory; `New-Item -ErrorAction Stop` makes any
  collision LOUD rather than overwriting a sibling's backup.
- `<encoded-path>` is the repo-relative path with `/` and `\` replaced
  by `__` (`scripts/lib/LlmHarness.psm1` becomes
  `scripts__lib__LlmHarness.psm1`) so two files with the same basename
  cannot overwrite each other within a single invocation.
- `<encoded-path>.index` is also written when an index entry exists. This
  preserves staged WIP before any fallback that has to reset the index to
  `HEAD`.
- The 20 most recent backup directories are retained; older ones are
  pruned at preflight startup. Cleanup failures NEVER block recovery.
- Recovery is also gated: if the backup directory cannot be created
  (read-only fs, EACCES, etc.) preflight REFUSES to run `git checkout`
  and exits non-zero, because losing WIP to a silent restore is worse
  than the corruption it was trying to fix.

To restore WIP from a backup:

```powershell
# Resolve the correct backup parent for normal clones, worktrees, and submodules.
$recoveryParent = git rev-parse --git-path preflight-recovery
# Find the most recent backup directory.
$recent = Get-ChildItem $recoveryParent -Directory |
    Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
# List backups inside it.
Get-ChildItem $recent
# Copy a specific file back (replace __ with /):
Copy-Item "$($recent.FullName)/scripts__lib__LlmHarness.psm1" `
          scripts/lib/LlmHarness.psm1
```

## N-Level Self-Heal Chain

The harness layers parse-checks so a corruption in any single layer is
caught and recovered by the layer above. Each row parse-checks the row
below it before invoking:

| Layer                            | Recovers                          |
|----------------------------------|-----------------------------------|
| Installed pre-commit sh shim      | `scripts/run-llm-hooks.ps1`       |
| `scripts/run-llm-hooks.ps1`       | `scripts/preflight.ps1`           |
| `scripts/preflight.ps1`           | all other tracked `.ps1`/`.psm1`/`.psd1` |

Recovery is via the index/staged copy first and `git checkout HEAD -- <path>`
as fallback after backing up the working-tree copy (see "Recovery From
AutoFix"). Each layer makes a single recovery attempt, then continues; if
`HEAD` is also corrupt the layer fails loudly and the user must escalate
manually.

## Adding A Skill

- Put it under `.llm/skills`.
- Use lowercase kebab-case file names.
- Keep content action-oriented and scoped to one concern.
- Add examples only when they prevent likely implementation mistakes.
- Do not copy large upstream docs; link to them from `.llm/research`.

## Pointer Files

Keep pointer files short. If guidance is useful to every agent, place it in
`.llm/context.md` or a skill and regenerate the index.
