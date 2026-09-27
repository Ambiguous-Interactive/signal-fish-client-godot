# Session 096: move Dependabot auto-merge to Python

Branch: `codex/session-096-python-dependabot-automerge` from `origin/main` at
`bb0b065`.

- Replaced the Dependabot auto-merge Bash and jq helper with Python.
- Kept the PR identity, head SHA, required workflow, check, and merge race gates.
- Extended fake GitHub CLI coverage for a stale head and a failed rerun.
- Updated the workflow, config validator, and LLM harness paths.
- Local runtime, source, Python, GitHub config, and full LLM harness checks pass.

#168 stays open for the remaining automation migration.
PR for this session: pending.
