# GitHub Copilot Instructions

Use [`.llm/context.md`](../.llm/context.md) as the canonical repository context.
Open focused skill files from `.llm/skills` only when their trigger metadata
matches the task.

## Mandatory post-edit validation

After editing any `.ps1`, `.psm1`, `.psd1`, or file under `.llm/`, run:

```pwsh
pwsh -NoProfile -File scripts/agent-check.ps1
```

Fix every reported issue before proposing a commit. This is the same
validation the pre-commit hook and CI run; running it locally prevents
the pre-commit hook from failing on what should have been caught in the
edit loop.
