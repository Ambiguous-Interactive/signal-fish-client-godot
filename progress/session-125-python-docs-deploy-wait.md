# Session 125: validate Docs Deploy runs with Python

Branch: `codex/session-125-docs-deploy-python` from `origin/main` at
`32817ce`.

- Moved Docs Deploy's run check from inline shell and jq to Python for #168.
- Kept the exact main commit and Docs Validation run checks.
- Added tests for run identity, retry, failure, timeout, and dispatch inputs.

Checks: GitHub config self-tests, runtime changed gate, full LLM harness,
Python lint and format, workflow format, and docs style.
