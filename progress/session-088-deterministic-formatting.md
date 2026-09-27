# Session 088: deterministic formatting

Branch: `codex/session-088-deterministic-formatting` from `origin/main` at
`70d536d`.

- Added pinned Prettier, shfmt, and PSScriptAnalyzer checks for tracked shell,
  PowerShell, JavaScript, JSON, YAML, TOML, CSS, and Markdown files.
- Formatted existing files. Kept generated LLM files, MkDocs cards, and Jinja
  templates under their own tools because Prettier changes their structure.
- The runtime gate, full LLM harness, docs style, Markdownlint, strict MkDocs
  build, devcontainer portability tests, and source formatting pass locally.

PR #202 is the session deliverable.
