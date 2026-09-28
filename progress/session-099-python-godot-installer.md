# Session 099: move Godot installers to Python

Branch: `codex/session-099-python-godot-installer` from `origin/main` at
`d73132e`.

- Replaced the separate Bash editor and web template installers with one
  Python command used by the devcontainer build and runtime CI.
- Kept the download cache, archive size and integrity checks, installed
  editor version naming, and web-only template extraction.
- Verified a real Godot 4.3 ARM64 download and cached reinstall. Small
  archive tests cover corrupt cache replacement, web-only extraction,
  editor version naming, and keeping a working binary on install failure.
- The full runtime gate, Python quality, source checks, docs style, and
  full LLM harness pass locally.

#168 stays open for the remaining automation migration.
PR #213 is the session deliverable.
