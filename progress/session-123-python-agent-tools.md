# Session 123: move agent CLI setup to Python

Branch: `codex/session-123-python-agent-tools` from `origin/main` at
`8020fd5`.

- Moved agent CLI install, verify, and refresh logic to Python for #168.
- Kept the shell entry point and added the Python module to the image.
- Preserved staged OpenCode v2 migration, v1 rollback, offline updates,
  credential removal, and failed install cleanup.
- Updated the fake npm harness and dev container packaging check.

Checks: dev container portability, fake npm migration matrix, runtime all,
source format and quality, full LLM harness, and docs style.
