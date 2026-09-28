# Session 122: run post-create setup from Python

Branch: `codex/session-122-python-automation` from `origin/main` at
`fcc61ba`.

- Moved dev container post-create setup into Python for #168. The shell
  entry point now sets PATH and starts Python.
- Kept strict checks for git hooks, agent CLIs, MCP servers, and the
  PowerShell profile. Optional startup maintenance still skips tool updates.
- Updated the harness checks and added a portability test for setup order,
  the MCP browser setting, profile install, and offline maintenance.

Local checks: portability tests, Ruff, mypy, and LLM harness.
