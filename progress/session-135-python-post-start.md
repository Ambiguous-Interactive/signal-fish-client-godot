# Session 135: Python dev container startup

Branch: `codex/session-135-python-post-start` from `origin/main` at
`49d6dfb`.

- Run post-start git trust and optional maintenance through one Python entry
  point for #168.
- Remove the shell wrapper and keep repeated offline starts idempotent.
- Update the dev container command, CI check, guidance, and lifecycle tests.

Checks: dev container portability tests, source quality, GitHub config
validation, runtime changed gate, docs style, and full LLM harness.
