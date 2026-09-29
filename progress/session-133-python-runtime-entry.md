# Session 133: Python runtime entry

Branch: `codex/session-133-python-runtime-entry` from `origin/main` at
`4a6080d`.

- Run the runtime gate through Python in CI and in the documented commands for
  #168. Use `-E` so a stale `PYTHONHOME` cannot stop Python before setup runs.
- Keep the shell launcher for existing callers. The Python runner already sets
  up the local virtual environment and tool cache.

Checks: runtime `all` and `smoke`, stale `PYTHONHOME` self-test, GitHub config
validation, docs style, and LLM harness.
