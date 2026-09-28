# Session 126: move runtime setup to Python

Branch: `codex/session-126-python-runtime-bootstrap` from `origin/main` at
`4c85987`.

- Moved the runtime gate's home, cache, and user-site setup into Python for #168.
- Kept early virtual environment selection in the shell entrypoint so its
  interpreter starts with the right environment.
- Added checks for a broken virtual environment, custom Python, cache defaults,
  and an invalid `PYTHONHOME`.

Checks: runtime all, Python self-tests, type, lint, and format checks; full LLM
harness; source quality.
