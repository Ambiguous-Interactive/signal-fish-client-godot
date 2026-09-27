# Session 095: move tool installers to Python

Branch: `codex/session-095-python-tool-installers` from `origin/main` at
`b3db1e9`.

- Replaced the shfmt and ShellCheck Bash installers with one Python command.
- Kept release versions, URLs, and SHA-256 pins for Linux x86_64 and ARM64.
- Verified both ARM64 downloads match the previous installed binaries.
- Source checks, Python quality, runtime checks, and the LLM harness pass
  locally.

#168 stays open for the remaining automation migration.
PR #209 is the session deliverable.
