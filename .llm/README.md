---
description: Organization guide for repo-specific AI context files.
triggers: llm, organization, context, skills, research, samples
category: Core
---

# LLM Context Organization

This folder holds concise, repo-specific context for AI coding agents.

## Structure

- `context.md`: canonical entry point for every agent front end.
- `index.md`: generated Markdown inventory; do not edit by hand.
- `skills/`: task-triggered instructions with metadata.
- `code-samples/`: small examples that teach intended shapes.
- `research/`: durable links and notes from upstream projects.

## File Rules

- Keep `.llm` Markdown files and known pointer files at or below 300 lines.
- Split large topics into focused files.
- Prefer links and concise summaries over copied documentation.
- Add `description`, `triggers`, and `category` frontmatter to every
  `.llm/**/*.md` file except generated `.llm/index.md`.
- Regenerate the Markdown index after adding, removing, or renaming
  `.llm/**/*.md` files.

## Regeneration

```powershell
pwsh -NoProfile -File scripts/generate-llm-index.ps1
pwsh -NoProfile -File scripts/lint-llm.ps1
```

