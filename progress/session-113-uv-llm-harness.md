# Session 113: use uv for LLM Harness CI

Branch: `codex/session-113-uv-llm-harness` from `origin/main` at `02920b9`.

- Moved the LLM Harness CI dependency install to uv for issue #168.
- Kept the PowerShell harness and its existing `.venv-ci` Python lookup.
- Changed the venv cache key so old pip environments cannot mask the new install path.
- Verified the uv install sequence with PyYAML 6.0.3, GitHub config checks,
  and the LLM harness fast check.

#168 remains open for other automation work.
