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

1. Edit the focused context, skill, sample, or research Markdown file.
2. Run `pwsh -NoProfile -File scripts/run-llm-hooks.ps1` (regenerates the
   index, runs the linter, and verifies staged generated files). Or run
   `generate-llm-index.ps1` + `lint-llm.ps1` + `test-llm-harness.ps1`
   individually.
3. Include regenerated `.llm/index.md` and `.llm/context.md` when changed.

## Shared Library

- `scripts/lib/LlmHarness.psm1` owns frontmatter parsing and path helpers.
  Both `generate-llm-index.ps1` and `lint-llm.ps1` import it; never reintroduce
  a local `Read-Frontmatter` in either script (the self-tests enforce this).
- `scripts/run-llm-hooks.ps1` is the single source of truth for the
  pre-commit / CI flow. `.githooks/pre-commit` (sh) and
  `.githooks/pre-commit.ps1` (Windows-only fallback) both delegate to it.

## Adding A Skill

- Put it under `.llm/skills`.
- Use lowercase kebab-case file names.
- Keep content action-oriented and scoped to one concern.
- Add examples only when they prevent likely implementation mistakes.
- Do not copy large upstream docs; link to them from `.llm/research`.

## Pointer Files

Keep pointer files short. If guidance is useful to every agent, place it in
`.llm/context.md` or a skill and regenerate the index.
