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
pwsh -NoProfile -File scripts/run-llm-hooks.ps1
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
- Local hook entry points pass `-AutoFix`; CI and `agent-check.ps1` pass
  `-NoAutoFix`. `-SkipStagedCheck` means an outer wrapper validates content
  outside the local staging flow, not that Git lacks an index.
- Stray artifact detection is single-sourced through
  `Get-LlmStagingArtifacts` (tracked + non-ignored) and
  `Get-LlmStrayWorkingTreeArtifacts` (includes gitignored junk like
  `*.tmp`, `*.swp`, `.DS_Store`). Both helpers default to
  `Get-LlmDefaultStrayPatterns`; the hook runner's `-AutoFix` uses the
  broader scan.
- Tracked shebang scripts are checked at byte level and by `git check-attr`
  so PowerShell hook/reference scripts that can run directly on Unix stay LF.
- `scripts/preflight.ps1` parse-checks itself first, then every tracked
  `.ps1`/`.psm1`/`.psd1`. `-AutoFix` recovers via `git checkout HEAD --
  <path>`. `run-llm-hooks.ps1`, `agent-check.ps1`, and CI all run it
  first.
- `.claude/settings.json` runs `.claude/hooks/parse-check-powershell.ps1`
  on every PowerShell write/edit so a stale-buffer corruption surfaces
  in the agent's tool_result on the next turn (exit 2 + JSON reason),
  not at commit time. The `Stop` hook re-runs preflight as a final
  defense.

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
- Godot 4 smoke test for the `WebSocketPeer` adapter path.
- Browser export manual check covering HTTPS hosting, `wss://`, WebSocket
  `Origin`, mixed-content rejection, and no native-only socket assumptions.
- Godot 3 smoke tests only after a separate compatibility decision, focused on
  the `WebSocketClient` adapter path.

## CI Guidance

Keep CI fast at repo bootstrap. Add heavier Godot matrix jobs once there is
runtime code to validate.
