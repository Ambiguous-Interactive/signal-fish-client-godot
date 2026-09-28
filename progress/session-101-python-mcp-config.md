# Session 101: move MCP config seeding to Python

Branch: `codex/python-mcp-config-seeder` from `origin/main` at `1cb0fc8`.

- Replaced the MCP config Bash seeder with Python in the devcontainer hooks.
- Kept the existing Codex block marker so user configs update in place.
- Honored a redirected `HOME` on Windows as the Bash seeder did.
- Preserved user content, conflict checks, strict setup, warn-only refresh,
  and doctor output that shows variable names without values.
- Updated the hermetic seeder checks and setup docs.
- The full LLM harness, runtime gate, Python quality, and docs style pass
  locally.

#168 stays open for the remaining automation migration.
