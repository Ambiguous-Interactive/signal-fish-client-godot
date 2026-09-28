# Session 114: run CI after Dependabot merges

Branch: `fix/dependabot-main-ci` from `origin/main` at `e78a254`.

- Fixed issue #234 by dispatching Runtime CI, LLM Harness, and Docs Validation
  after a successful Dependabot squash merge.
- Pinned each dispatch to the merge commit and kept main runs from canceling
  each other. Docs Deploy now accepts a validated main dispatch.
- Added merger behavior tests and GitHub workflow config checks.

Local checks: Dependabot merger tests, GitHub config validation, Python types,
LLM harness, and runtime checks. Live auto-merge evidence: pending.
