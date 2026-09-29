# Session 134: Shared CI uv setup

Branch: `codex/session-134-ci-uv-bootstrap` from `origin/main` at
`273a7d5`.

- Use one Python entry point for the uv setup in Runtime CI, Docs Validation,
  Docs Deploy, LLM Harness, and Web Export Smoke (#168).
- Include the entry point in cached environment keys so a setup change builds
  a fresh environment.

Checks: isolated uv install and virtual environment creation; source format and
quality; GitHub config validation; docs style; LLM harness; runtime `all`.
