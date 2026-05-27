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
```

These checks enforce:

- `.llm` Markdown and known pointer file line counts at or below 300 lines.
- Metadata presence for `.llm` Markdown files except generated
  `.llm/index.md`.
- Vendor pointer files referencing `.llm/context.md`.
- Generated `.llm/index.md` and context index freshness.

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

