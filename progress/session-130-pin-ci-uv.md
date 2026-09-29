# Session 130: pin uv in CI

Branch: `chore/pin-ci-uv-bootstrap` from `origin/main` at `1ff8d71`.

- Pinned all six CI uv installs to `0.12.19`, the version already used by the
  dev container. This keeps Python tool setup consistent across jobs.
- Kept #168 open for further suitable automation work.

Checks: GitHub config validation and self-tests, docs style, full runtime gate,
and full LLM harness.
