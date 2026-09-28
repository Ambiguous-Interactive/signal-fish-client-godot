# Session 100: move MCP installation to Python

Branch: `codex/python-mcp-installer` from `origin/main` at `487f99d`.

- Replaced the npm MCP Bash installer with Python in the image build and
  container hooks.
- Kept strict post-create checks, warn-only updates, pinned specs, offline
  version checks, credential removal, and optional Chromium setup.
- Updated the hermetic installer matrix and devcontainer documentation.
- The full LLM harness, Python quality, and docs style pass locally.

#168 stays open for the remaining automation migration.
