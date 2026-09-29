# Session 141: Python documentation build checks

Branch: `codex/session-141-python-docs-build` from `origin/main` at
`24696e4`.

- Moved rendered-page checks from shell into the existing MkDocs hook for #168.
- Check every included documentation file from MkDocs, including new pages.
- Use Python to run strict MkDocs builds in validation and manual deployment.
- Keep the validated artifact handoff for main deployments.

Local checks: strict MkDocs build, output regression tests, full runtime gate,
GitHub config validation, and full LLM harness.
