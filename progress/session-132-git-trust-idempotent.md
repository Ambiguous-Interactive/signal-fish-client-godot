# Session 132: Idempotent Git trust

Branch: `codex/session-132-git-trust-idempotent` from `origin/main` at
`60087cf`.

- Move lifecycle PATH setup from Bash to Python.
- Avoid duplicate global `safe.directory` entries on dev container rebuilds.
- Check repeated setup with a private Git config and a workspace path with spaces.

Checks: dev container portability tests, runtime gate, and LLM harness.
